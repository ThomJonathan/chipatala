-- ============================================================================
-- SALES MIGRATION — run once in the Supabase SQL editor, after schema.sql
-- (and the dashboard/admin-management blocks at its bottom).
--
-- What this adds:
--   1. branch_receipt_counters — one running counter per branch, so receipt
--      numbers look like MZU-000123. A failed sale can leave a gap; that is
--      expected and documented on the receipt screen.
--   2. create_sale(...) — the ONLY way a sale is recorded from now on. One
--      call: role check, FEFO stock allocation (expired never sold), lines
--      with per-batch cost, batch deduction, movement log, receipt number,
--      payment + part-payments, and the receipt JSON back in the same call.
--      Batch rows are locked (FOR UPDATE), so two cashiers can't sell the
--      same units and a short sale is cancelled whole, never half-saved.
--   3. get_receipt(...) — receipt JSON for any sale the caller may see
--      (admin, or staff of that branch). Used for reprints.
--   4. Trigger fix — the credit-sale trigger now reacts ONLY to the sale
--      total. Part-payments always travel through the payments ledger
--      (fn_apply_payment drops the customer balance AND advances the sale's
--      amount_paid). Previously a payment linked to a credit sale reduced
--      the balance twice: once via (total - amount_paid) and once via the
--      payment row. fn_apply_payment also only touches sales that are
--      actually credit sales now.
--   5. Lockdown — direct INSERTs into sales / sale_items are revoked (staff
--      INSERT policies dropped; writes go through create_sale, which runs
--      as owner and bypasses RLS). Inventory direct writes are limited to
--      admin + managers + stock controllers of their own branch; cashiers
--      keep read-only access.
--
-- Test after running (replace the UUIDs):
--   select create_sale(
--     'BRANCH-UUID', '[{"item_id":"ITEM-UUID","quantity":2}]',
--     'retail', 'cash', null, null, null);
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 0. Helper: current user's role (SECURITY DEFINER so it can read users
--    without re-entering RLS, same pattern as is_admin()).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_user_role() RETURNS user_role
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
  SELECT role FROM users WHERE id = auth.uid();
$$;

-- ----------------------------------------------------------------------------
-- 1. Receipt counters (one row per branch, created on demand).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS branch_receipt_counters (
  branch_id   UUID PRIMARY KEY REFERENCES branches(id) ON DELETE CASCADE,
  prefix      TEXT NOT NULL,
  last_number INTEGER NOT NULL DEFAULT 0
);

-- Backfill existing branches: first 3 letters of the name, upper-cased.
INSERT INTO branch_receipt_counters (branch_id, prefix)
SELECT id, COALESCE(NULLIF(UPPER(SUBSTRING(REGEXP_REPLACE(name, '[^A-Za-z]', '', 'g') FROM 1 FOR 3)), ''), 'BRN')
FROM branches
ON CONFLICT (branch_id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 2. create_sale — the single transactional sale writer.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_sale(
  p_branch_id      UUID,
  p_items          JSONB,            -- [{"item_id": uuid, "quantity": numeric}]
  p_sale_type      sale_type,
  p_payment_method payment_method,
  p_customer_id    UUID DEFAULT NULL,
  p_amount_paid    NUMERIC DEFAULT NULL,   -- credit part-payment (0/NULL = none)
  p_paid_method    payment_method DEFAULT NULL  -- how the part-payment was made
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_seller_id   UUID := auth.uid();
  v_seller      RECORD;
  v_line        RECORD;
  v_batch       RECORD;
  v_item_name   TEXT;
  v_remaining   NUMERIC;
  v_available   NUMERIC;
  v_take        NUMERIC;
  v_price       NUMERIC;
  v_total       NUMERIC := 0;
  v_part        NUMERIC := COALESCE(p_amount_paid, 0);
  v_sale_id     UUID;
  v_receipt_no  TEXT;
  v_prefix      TEXT;
  v_next        INTEGER;
  v_line_rows   JSONB := '[]'::JSONB;
  v_branch      RECORD;
  v_cashier     TEXT;
  v_customer    TEXT;
  v_avail_text  TEXT;
BEGIN
  -- ---- Who is selling? -----------------------------------------------------
  SELECT id, role, branch_id INTO v_seller FROM users WHERE id = v_seller_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_SIGNED_IN: no staff profile for this account.';
  END IF;
  IF v_seller.role = 'stock_controller' THEN
    RAISE EXCEPTION 'NOT_ALLOWED: stock controllers cannot record sales.';
  END IF;
  IF v_seller.role <> 'admin' AND v_seller.branch_id IS DISTINCT FROM p_branch_id THEN
    RAISE EXCEPTION 'NOT_ALLOWED: you can only sell from your own branch.';
  END IF;

  -- ---- Customer rules -------------------------------------------------------
  IF p_payment_method = 'credit' THEN
    IF p_customer_id IS NULL THEN
      RAISE EXCEPTION 'NO_CUSTOMER: credit sales need a customer.';
    END IF;
    SELECT full_name INTO v_customer FROM customers WHERE id = p_customer_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'NO_CUSTOMER: customer not found.';
    END IF;
  ELSIF p_customer_id IS NOT NULL THEN
    SELECT full_name INTO v_customer FROM customers WHERE id = p_customer_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'NO_CUSTOMER: customer not found.';
    END IF;
  END IF;
  IF v_part < 0 THEN
    RAISE EXCEPTION 'BAD_PAYMENT: part-payment cannot be negative.';
  END IF;

  -- ---- Allocate stock, earliest expiry first (locks the batch rows) ---------
  FOR v_line IN
    SELECT (x.item_id)::UUID AS item_id, (x.quantity)::NUMERIC AS quantity
    FROM jsonb_to_recordset(p_items) AS x(item_id UUID, quantity NUMERIC)
    ORDER BY 1
  LOOP
    IF v_line.quantity IS NULL OR v_line.quantity <= 0 THEN
      RAISE EXCEPTION 'BAD_QTY: quantity must be above zero.';
    END IF;
    SELECT name INTO v_item_name FROM items WHERE id = v_line.item_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'NO_ITEM: item not found.';
    END IF;

    v_remaining := v_line.quantity;
    v_available := 0;
    FOR v_batch IN
      SELECT id, quantity_available, buying_price, retail_price, wholesale_price
      FROM inventory
      WHERE item_id = v_line.item_id
        AND branch_id = p_branch_id
        AND quantity_available > 0
        AND (expiry_date IS NULL OR expiry_date >= CURRENT_DATE)
      ORDER BY expiry_date NULLS LAST, received_date, id
      FOR UPDATE
    LOOP
      EXIT WHEN v_remaining <= 0;
      v_take := LEAST(v_batch.quantity_available, v_remaining);
      v_available := v_available + v_batch.quantity_available;
      IF p_sale_type = 'wholesale' AND v_batch.wholesale_price IS NOT NULL THEN
        v_price := v_batch.wholesale_price;
      ELSE
        v_price := v_batch.retail_price;
      END IF;
      v_line_rows := v_line_rows || jsonb_build_object(
        'inventory_id', v_batch.id,
        'item_id', v_line.item_id,
        'item_name', v_item_name,
        'quantity', v_take,
        'unit_price', v_price,
        'unit_cost', v_batch.buying_price,
        'subtotal', v_take * v_price
      );
      v_total := v_total + v_take * v_price;
      v_remaining := v_remaining - v_take;
    END LOOP;

    IF v_remaining > 0 THEN
      -- Plain number without trailing decimal zeros ('10', not '10.00'/'1').
      IF v_available = FLOOR(v_available) THEN
        v_avail_text := FLOOR(v_available)::TEXT;
      ELSE
        v_avail_text := RTRIM(RTRIM(v_available::TEXT, '0'), '.');
      END IF;
      RAISE EXCEPTION 'NOT_ENOUGH:%: only % available', v_item_name, v_avail_text;
    END IF;
  END LOOP;

  IF v_total <= 0 THEN
    RAISE EXCEPTION 'EMPTY_SALE: nothing to sell.';
  END IF;
  IF p_payment_method = 'credit' AND v_part > v_total THEN
    RAISE EXCEPTION 'BAD_PAYMENT: part-payment cannot exceed the total.';
  END IF;

  -- ---- Receipt number (counter row locked; gaps on failure are fine) --------
  -- Prefix lives on the counter row; created on demand for new branches.
  SELECT prefix, last_number + 1 INTO v_prefix, v_next
  FROM branch_receipt_counters WHERE branch_id = p_branch_id FOR UPDATE;
  IF NOT FOUND THEN
    SELECT COALESCE(NULLIF(UPPER(SUBSTRING(REGEXP_REPLACE(name, '[^A-Za-z]', '', 'g') FROM 1 FOR 3)), ''), 'BRN')
      INTO v_prefix FROM branches WHERE id = p_branch_id;
    v_next := 1;
    INSERT INTO branch_receipt_counters (branch_id, prefix, last_number)
    VALUES (p_branch_id, v_prefix, 1);
  ELSE
    UPDATE branch_receipt_counters SET last_number = v_next WHERE branch_id = p_branch_id;
  END IF;
  v_receipt_no := v_prefix || '-' || LPAD(v_next::TEXT, 6, '0');

  -- ---- Sale header -----------------------------------------------------------
  INSERT INTO sales (branch_id, customer_id, cashier_id, sale_type, payment_method,
                     payment_status, total_amount, amount_paid, receipt_number)
  VALUES (p_branch_id, p_customer_id, v_seller_id, p_sale_type, p_payment_method,
          CASE WHEN p_payment_method = 'credit' THEN 'pending' ELSE 'paid' END,
          v_total,
          CASE WHEN p_payment_method = 'credit' THEN 0 ELSE v_total END,
          v_receipt_no)
  RETURNING id INTO v_sale_id;
  -- NOTE: credit sales are inserted with amount_paid = 0 on purpose. A
  -- part-payment below travels through the payments ledger, whose trigger
  -- advances amount_paid — setting it here too would count it twice.

  -- ---- Lines + deductions + movement log --------------------------------------
  FOR v_line IN SELECT * FROM jsonb_array_elements(v_line_rows) LOOP
    DECLARE
      r JSONB := v_line.value;
    BEGIN
      INSERT INTO sale_items (sale_id, item_id, inventory_id, quantity, unit_price, unit_cost, subtotal)
      VALUES (v_sale_id, (r->>'item_id')::UUID, (r->>'inventory_id')::UUID,
              (r->>'quantity')::NUMERIC, (r->>'unit_price')::NUMERIC,
              (r->>'unit_cost')::NUMERIC, (r->>'subtotal')::NUMERIC);
      UPDATE inventory
      SET quantity_available = quantity_available - (r->>'quantity')::NUMERIC
      WHERE id = (r->>'inventory_id')::UUID;
      INSERT INTO stock_movements (branch_id, item_id, inventory_id, movement_type,
                                   quantity, reference_table, reference_id, performed_by)
      VALUES (p_branch_id, (r->>'item_id')::UUID, (r->>'inventory_id')::UUID, 'sale_out',
              (r->>'quantity')::NUMERIC, 'sales', v_sale_id, v_seller_id);
    END;
  END LOOP;

  -- ---- Credit part-payment through the ledger ----------------------------------
  IF p_payment_method = 'credit' AND v_part > 0 THEN
    INSERT INTO payments (branch_id, customer_id, sale_id, amount, payment_method, recorded_by)
    VALUES (p_branch_id, p_customer_id, v_sale_id, v_part,
            COALESCE(p_paid_method, 'cash'), v_seller_id);
  END IF;

  -- ---- Receipt payload ----------------------------------------------------------
  SELECT name, location, phone INTO v_branch FROM branches WHERE id = p_branch_id;
  SELECT full_name INTO v_cashier FROM users WHERE id = v_seller_id;

  RETURN jsonb_build_object(
    'sale_id', v_sale_id,
    'receipt_number', v_receipt_no,
    'sale_date', NOW(),
    'branch_name', v_branch.name,
    'branch_location', v_branch.location,
    'branch_phone', v_branch.phone,
    'cashier_name', v_cashier,
    'customer_name', v_customer,
    'sale_type', p_sale_type,
    'payment_method', p_payment_method,
    'total_amount', v_total,
    'amount_paid', CASE WHEN p_payment_method = 'credit' THEN v_part ELSE v_total END,
    'balance_due', CASE WHEN p_payment_method = 'credit' THEN v_total - v_part ELSE 0 END,
    'items', (SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                  'name', value->>'item_name',
                  'quantity', (value->>'quantity')::NUMERIC,
                  'unit_price', (value->>'unit_price')::NUMERIC,
                  'subtotal', (value->>'subtotal')::NUMERIC)
                ORDER BY value->>'item_name'),
              '[]'::JSONB)
             FROM jsonb_array_elements(v_line_rows) AS t(value))
  );
END;
$$;

-- ----------------------------------------------------------------------------
-- 3. get_receipt — same payload for reprints (no cash/change: never stored).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_receipt(p_sale_id UUID) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
DECLARE
  v_sale     RECORD;
  v_branch   RECORD;
  v_cashier  TEXT;
  v_customer TEXT;
BEGIN
  SELECT * INTO v_sale FROM sales WHERE id = p_sale_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NO_SALE: sale not found.';
  END IF;
  IF NOT is_admin() AND v_sale.branch_id IS DISTINCT FROM user_branch_id() THEN
    RAISE EXCEPTION 'NOT_ALLOWED: you can only see your own branch.';
  END IF;

  SELECT name, location, phone INTO v_branch FROM branches WHERE id = v_sale.branch_id;
  SELECT full_name INTO v_cashier FROM users WHERE id = v_sale.cashier_id;
  IF v_sale.customer_id IS NOT NULL THEN
    SELECT full_name INTO v_customer FROM customers WHERE id = v_sale.customer_id;
  END IF;

  RETURN jsonb_build_object(
    'sale_id', v_sale.id,
    'receipt_number', v_sale.receipt_number,
    'sale_date', v_sale.sale_date,
    'branch_name', v_branch.name,
    'branch_location', v_branch.location,
    'branch_phone', v_branch.phone,
    'cashier_name', v_cashier,
    'customer_name', v_customer,
    'sale_type', v_sale.sale_type,
    'payment_method', v_sale.payment_method,
    'total_amount', v_sale.total_amount,
    'amount_paid', v_sale.amount_paid,
    'balance_due', GREATEST(v_sale.total_amount - v_sale.amount_paid, 0),
    'items', (SELECT COALESCE(jsonb_agg(
                jsonb_build_object(
                  'name', i.name,
                  'quantity', si.quantity,
                  'unit_price', si.unit_price,
                  'subtotal', si.subtotal)
                ORDER BY i.name),
              '[]'::JSONB)
             FROM sale_items si JOIN items i ON i.id = si.item_id
             WHERE si.sale_id = p_sale_id)
  );
END;
$$;

REVOKE ALL ON FUNCTION create_sale(UUID, JSONB, sale_type, payment_method, UUID, NUMERIC, payment_method)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION create_sale(UUID, JSONB, sale_type, payment_method, UUID, NUMERIC, payment_method)
  TO authenticated;

REVOKE ALL ON FUNCTION get_receipt(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION get_receipt(UUID) TO authenticated;

-- ----------------------------------------------------------------------------
-- 4. Trigger fix — credit debt follows the TOTAL only; payments ledger
--    handles every part-payment (and only credit sales accrue paid amounts).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_apply_credit_sale() RETURNS TRIGGER AS $$
DECLARE
  old_total NUMERIC := COALESCE(OLD.total_amount, 0);
  new_total NUMERIC := COALESCE(NEW.total_amount, 0);
BEGIN
  IF NEW.customer_id IS NOT NULL AND NEW.payment_method = 'credit' THEN
    UPDATE customers SET current_balance = current_balance + (new_total - old_total)
    WHERE id = NEW.customer_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_apply_credit_sale ON sales;
CREATE TRIGGER trg_apply_credit_sale
  AFTER INSERT OR UPDATE OF total_amount ON sales
  FOR EACH ROW EXECUTE FUNCTION fn_apply_credit_sale();

CREATE OR REPLACE FUNCTION fn_apply_payment() RETURNS TRIGGER AS $$
DECLARE
  v_is_credit BOOLEAN;
BEGIN
  IF NEW.customer_id IS NOT NULL THEN
    UPDATE customers SET current_balance = current_balance - NEW.amount
    WHERE id = NEW.customer_id;
  END IF;

  IF NEW.sale_id IS NOT NULL THEN
    SELECT payment_method = 'credit' INTO v_is_credit FROM sales WHERE id = NEW.sale_id;
    IF COALESCE(v_is_credit, FALSE) THEN
      UPDATE sales
      SET amount_paid = amount_paid + NEW.amount,
          payment_status = CASE
            WHEN amount_paid + NEW.amount >= total_amount THEN 'paid'
            WHEN amount_paid + NEW.amount > 0 THEN 'partial'
            ELSE 'pending'
          END
      WHERE id = NEW.sale_id;
    END IF;
  END IF;

  IF NEW.purchase_id IS NOT NULL THEN
    UPDATE purchases SET amount_paid = amount_paid + NEW.amount
    WHERE id = NEW.purchase_id;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- 5. Lockdown — app writes go through create_sale; inventory writes are
--    admin / manager / stock-controller only (cashiers read).
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS "Staff record sales at own branch" ON sales;
DROP POLICY IF EXISTS "Insert sale_items via parent sale access" ON sale_items;
-- (SELECT policies on both tables stay, so lists/receipts keep working.)

DROP POLICY IF EXISTS "Admins and staff manage own branch inventory" ON inventory;
CREATE POLICY "Admins manage all inventory"
  ON inventory FOR ALL
  USING (is_admin())
  WITH CHECK (is_admin());

CREATE POLICY "Managers and stock controllers manage own branch inventory"
  ON inventory FOR ALL
  USING (is_admin()
         OR (branch_id = user_branch_id()
             AND current_user_role() IN ('manager', 'stock_controller')))
  WITH CHECK (is_admin()
              OR (branch_id = user_branch_id()
                  AND current_user_role() IN ('manager', 'stock_controller')));
-- "Staff view own branch inventory" (SELECT) already exists: cashiers read on.
