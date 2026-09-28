-- ============================================================================
-- DRUG STORE MANAGEMENT SYSTEM — MINIMAL SCHEMA
-- PostgreSQL 14+ (Neon or Supabase)
-- ============================================================================
--
-- Tables: users, branches, items, inventory, stock_movements, purchases,
-- purchase_items, sales, sale_items, customers, expenses, suppliers, payments.
--
-- Deliberate choices, so you know why they're there:
--
-- 1. `inventory` is one row per item PER BRANCH PER BATCH, not per item.
--    Same drug, two different expiry dates (your spreadsheet already shows
--    this) = two rows. This is what makes expiry tracking possible at all —
--    collapsing to one row per item would lose the second expiry date.
--
-- 2. `sale_items` exists even though you didn't list it, because a sale is
--    a basket of items, not one item. Without it, a single `sales` row can
--    only hold one drug per transaction — a real POS can't work that way.
--    It's a thin table, doesn't add real complexity.
--
-- 3. Suppliers get their own table, not just a text field — you're tracking
--    payment_status per purchase (paid/partial/pending), and a text field
--    can't answer "how much do we currently owe this supplier across all
--    invoices." That's a straight SUM(total_amount - amount_paid) once
--    purchases link to a real supplier_id.
--
-- 4. `payments` is a real ledger, not just a running-balance number.
--    `customers.current_balance` and `purchases.amount_paid` are still on
--    those tables as fast-read caches, but they are now maintained
--    AUTOMATICALLY by triggers below, from actual payment rows — never
--    edited directly by the app. Same idea for `sales.total_amount` and
--    `purchases.total_amount`: they're recalculated by trigger from their
--    line items, so they can't silently drift out of sync with reality.
--    This closes the exact gap flagged earlier: every balance on this
--    schema is now backed by a row that explains how it got there.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gives us gen_random_uuid()

CREATE TYPE user_role AS ENUM ('admin', 'manager', 'cashier', 'stock_controller');
CREATE TYPE sale_type AS ENUM ('retail', 'wholesale');
CREATE TYPE payment_method AS ENUM ('cash', 'mobile_money', 'card', 'credit');
CREATE TYPE payment_status AS ENUM ('paid', 'partial', 'pending');

CREATE TYPE stock_movement_type AS ENUM (
    'opening_stock',
    'purchase_in',
    'sale_out',
    'adjustment_out',   -- damaged / lost / expired / negative correction
    'adjustment_in'     -- positive correction / found stock
);

-- ============================================================================
-- BRANCHES & USERS
-- ============================================================================

CREATE TABLE branches (
                          id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                          name        TEXT NOT NULL,          -- e.g. "Mzuzu Branch"
                          location    TEXT,
                          phone       TEXT,
                          is_active   BOOLEAN NOT NULL DEFAULT true,
                          created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE users (
                       id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                       full_name   TEXT NOT NULL,
                       username    TEXT NOT NULL UNIQUE,
                       phone       TEXT,
                       role        user_role NOT NULL,
                       branch_id   UUID REFERENCES branches(id),  -- NULL only for admin
                       is_active   BOOLEAN NOT NULL DEFAULT true,
                       created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
                       CONSTRAINT branch_required_unless_admin
                           CHECK (role = 'admin' OR branch_id IS NOT NULL)
);

-- ============================================================================
-- ITEMS (drugs, gloves, anything the store sells)
-- ============================================================================

CREATE TABLE items (
                       id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                       name                   TEXT NOT NULL,          -- e.g. "AMLODIPINE TABS", "GLOVES (BOX)"
                       category               TEXT,                   -- e.g. "Antibiotics", "Analgesics", "Supplies" — plain text, no lookup table needed
                       unit                   TEXT NOT NULL DEFAULT 'unit', -- tablet, bottle, box, pair...
                       reorder_level          NUMERIC(12,2) NOT NULL DEFAULT 10,
                       requires_prescription  BOOLEAN NOT NULL DEFAULT false,
                       is_active              BOOLEAN NOT NULL DEFAULT true,
                       created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_items_name ON items USING gin (to_tsvector('simple', name));
CREATE INDEX idx_items_category ON items(category);

-- ============================================================================
-- INVENTORY (batch-level stock — see note 1 above)
-- ============================================================================

CREATE TABLE inventory (
                           id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                           item_id             UUID NOT NULL REFERENCES items(id),
                           branch_id           UUID NOT NULL REFERENCES branches(id),
                           batch_number        TEXT,
                           buying_price        NUMERIC(12,2) NOT NULL,
                           retail_price        NUMERIC(12,2) NOT NULL,
                           wholesale_price     NUMERIC(12,2),
                           quantity_received   NUMERIC(12,2) NOT NULL,
                           quantity_available  NUMERIC(12,2) NOT NULL,
                           expiry_date         DATE,
                           received_date       DATE NOT NULL DEFAULT current_date,
                           created_by          UUID REFERENCES users(id),
                           created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
                           CONSTRAINT qty_not_negative CHECK (quantity_available >= 0)
);

CREATE INDEX idx_inventory_branch_item ON inventory(branch_id, item_id);
CREATE INDEX idx_inventory_expiry ON inventory(branch_id, expiry_date)
    WHERE quantity_available > 0;

-- ============================================================================
-- STOCK MOVEMENTS (audit trail — every quantity change writes a row here)
-- ============================================================================

-- inventory_id is NOT NULL: every movement must be traceable to one
-- specific batch (this is what note 1 above depends on for expiry/FEFO
-- to mean anything). reference_table/reference_id remain a soft link
-- (Postgres can't FK to "one of two tables") — that stays app-enforced.
CREATE TABLE stock_movements (
                                 id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                                 branch_id       UUID NOT NULL REFERENCES branches(id),
                                 item_id         UUID NOT NULL REFERENCES items(id),
                                 inventory_id    UUID NOT NULL REFERENCES inventory(id),
                                 movement_type   stock_movement_type NOT NULL,
                                 quantity        NUMERIC(12,2) NOT NULL CHECK (quantity > 0),  -- direction implied by movement_type
                                 reference_table TEXT,                    -- 'sales' or 'purchases'
                                 reference_id    UUID,
                                 notes           TEXT,
                                 performed_by    UUID REFERENCES users(id),
                                 created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_movements_branch_date ON stock_movements(branch_id, created_at);

-- ============================================================================
-- SUPPLIERS
-- ============================================================================

CREATE TABLE suppliers (
                           id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                           name            TEXT NOT NULL,
                           contact_person  TEXT,
                           phone           TEXT,
                           address         TEXT,
                           is_active       BOOLEAN NOT NULL DEFAULT true,
                           created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- PURCHASES (stock coming in)
-- ============================================================================

-- total_amount and amount_paid are cache columns, kept correct by triggers
-- below (from purchase_items and payments respectively) — never write to
-- them directly from application code.
CREATE TABLE purchases (
                           id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                           branch_id       UUID NOT NULL REFERENCES branches(id),
                           supplier_id     UUID REFERENCES suppliers(id),
                           invoice_number  TEXT,
                           payment_status  payment_status NOT NULL DEFAULT 'pending',
                           total_amount    NUMERIC(14,2) NOT NULL DEFAULT 0,
                           amount_paid     NUMERIC(14,2) NOT NULL DEFAULT 0,
                           purchase_date   DATE NOT NULL DEFAULT current_date,
                           created_by      UUID REFERENCES users(id),
                           created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- inventory_id is NOT NULL: every purchase line must create/point to an
-- actual batch — a purchase disconnected from real stock is a data bug,
-- not a valid state.
CREATE TABLE purchase_items (
                                id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                                purchase_id   UUID NOT NULL REFERENCES purchases(id) ON DELETE CASCADE,
                                item_id       UUID NOT NULL REFERENCES items(id),
                                inventory_id  UUID NOT NULL REFERENCES inventory(id),  -- the batch this purchase created
                                quantity      NUMERIC(12,2) NOT NULL CHECK (quantity > 0),
                                unit_cost     NUMERIC(12,2) NOT NULL,
                                subtotal      NUMERIC(14,2) NOT NULL
);

-- ============================================================================
-- CUSTOMERS (mainly for credit / debt tracking)
-- ============================================================================

CREATE TABLE customers (
                           id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                           branch_id        UUID REFERENCES branches(id),
                           name             TEXT NOT NULL,
                           phone            TEXT,
                           current_balance  NUMERIC(12,2) NOT NULL DEFAULT 0,  -- what they owe
                           created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- SALES (stock going out — see note 2 above for why sale_items exists)
-- ============================================================================

-- total_amount and amount_paid are cache columns, kept correct by triggers
-- below (from sale_items and payments respectively) — never write to them
-- directly from application code.
CREATE TABLE sales (
                       id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                       branch_id       UUID NOT NULL REFERENCES branches(id),
                       customer_id     UUID REFERENCES customers(id),
                       cashier_id      UUID NOT NULL REFERENCES users(id),
                       sale_type       sale_type NOT NULL DEFAULT 'retail',
                       payment_method  payment_method NOT NULL,
                       payment_status  payment_status NOT NULL DEFAULT 'paid',
                       total_amount    NUMERIC(14,2) NOT NULL DEFAULT 0,
                       amount_paid     NUMERIC(14,2) NOT NULL DEFAULT 0,
                       receipt_number  TEXT UNIQUE,
                       sale_date       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_sales_branch_date ON sales(branch_id, sale_date);

CREATE TABLE sale_items (
                            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                            sale_id       UUID NOT NULL REFERENCES sales(id) ON DELETE CASCADE,
                            item_id       UUID NOT NULL REFERENCES items(id),
                            inventory_id  UUID NOT NULL REFERENCES inventory(id), -- which batch was drawn (FEFO)
                            quantity      NUMERIC(12,2) NOT NULL CHECK (quantity > 0),
                            unit_price    NUMERIC(12,2) NOT NULL,   -- retail or wholesale price charged
                            unit_cost     NUMERIC(12,2) NOT NULL,   -- copied from inventory.buying_price at sale time
                            subtotal      NUMERIC(14,2) NOT NULL,
                            profit        NUMERIC(14,2) GENERATED ALWAYS AS ((unit_price - unit_cost) * quantity) STORED
);

-- ============================================================================
-- EXPENSES (needed for real net-profit numbers — see note in chat)
-- ============================================================================

CREATE TABLE expenses (
                          id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                          branch_id     UUID NOT NULL REFERENCES branches(id),
                          category      TEXT NOT NULL,   -- 'Transport', 'Electricity', 'Rent', 'Salaries', 'Internet', 'Repairs', 'Other'
                          amount        NUMERIC(12,2) NOT NULL,
                          description   TEXT,
                          expense_date  DATE NOT NULL DEFAULT current_date,
                          recorded_by   UUID REFERENCES users(id),
                          created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- PAYMENTS (the ledger behind customer debt and supplier balances)
-- ============================================================================
--
-- Exactly one of (customer_id, supplier_id) is set per row — a payment is
-- either money coming IN from a customer paying down credit, or money
-- going OUT to a supplier paying down an invoice. sale_id / purchase_id
-- link it to the specific transaction being paid down where relevant.

CREATE TABLE payments (
                          id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                          branch_id       UUID NOT NULL REFERENCES branches(id),
                          customer_id     UUID REFERENCES customers(id),
                          sale_id         UUID REFERENCES sales(id),       -- optional: which sale this pays down
                          supplier_id     UUID REFERENCES suppliers(id),
                          purchase_id     UUID REFERENCES purchases(id),   -- optional: which invoice this pays down
                          amount          NUMERIC(12,2) NOT NULL CHECK (amount > 0),
                          payment_method  payment_method NOT NULL,
                          payment_date    TIMESTAMPTZ NOT NULL DEFAULT now(),
                          recorded_by     UUID REFERENCES users(id),
                          notes           TEXT,
                          CONSTRAINT exactly_one_party CHECK (
                              (customer_id IS NOT NULL AND supplier_id IS NULL) OR
                              (supplier_id IS NOT NULL AND customer_id IS NULL)
                              )
);

CREATE INDEX idx_payments_customer ON payments(customer_id);
CREATE INDEX idx_payments_supplier ON payments(supplier_id);

-- ============================================================================
-- TRIGGERS — keep every cache column correct automatically. The app only
-- ever INSERTs into payments / sale_items / purchase_items; it never
-- touches customers.current_balance, purchases.amount_paid/total_amount,
-- or sales.total_amount directly.
-- ============================================================================

-- Customer pays down credit -> reduce their balance.
-- Supplier gets paid -> increase amount_paid on that purchase invoice.
CREATE FUNCTION fn_apply_payment() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.customer_id IS NOT NULL THEN
UPDATE customers SET current_balance = current_balance - NEW.amount
WHERE id = NEW.customer_id;
END IF;
    IF NEW.purchase_id IS NOT NULL THEN
UPDATE purchases SET amount_paid = amount_paid + NEW.amount
WHERE id = NEW.purchase_id;
END IF;
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_payment
    AFTER INSERT ON payments
    FOR EACH ROW EXECUTE FUNCTION fn_apply_payment();

-- A credit sale increases customer debt by (total_amount - amount_paid).
-- This fires on INSERT *and* on UPDATE OF total_amount, because total_amount
-- starts at 0 and is only filled in afterwards by fn_recalc_sale_total once
-- sale_items exist (a sale's header is created before its line items).
-- Using a before/after delta (rather than reading NEW.total_amount alone)
-- makes this correct regardless of that ordering, and safe to fire more
-- than once as line items are added one at a time.
CREATE FUNCTION fn_apply_credit_sale() RETURNS TRIGGER AS $$
DECLARE
old_debt NUMERIC := COALESCE(OLD.total_amount, 0) - COALESCE(OLD.amount_paid, 0);
    new_debt NUMERIC := COALESCE(NEW.total_amount, 0) - COALESCE(NEW.amount_paid, 0);
BEGIN
    IF NEW.customer_id IS NOT NULL AND NEW.payment_method = 'credit' THEN
UPDATE customers SET current_balance = current_balance + (new_debt - old_debt)
WHERE id = NEW.customer_id;
END IF;
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_credit_sale
    AFTER INSERT OR UPDATE OF total_amount, amount_paid ON sales
    FOR EACH ROW EXECUTE FUNCTION fn_apply_credit_sale();

-- Keep sales.total_amount in sync with its line items automatically.
CREATE FUNCTION fn_recalc_sale_total() RETURNS TRIGGER AS $$
DECLARE
target_sale_id UUID := COALESCE(NEW.sale_id, OLD.sale_id);
BEGIN
UPDATE sales SET total_amount = (
    SELECT COALESCE(SUM(subtotal), 0) FROM sale_items WHERE sale_id = target_sale_id
) WHERE id = target_sale_id;
RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_recalc_sale_total
    AFTER INSERT OR UPDATE OR DELETE ON sale_items
    FOR EACH ROW EXECUTE FUNCTION fn_recalc_sale_total();

-- Keep purchases.total_amount in sync with its line items automatically.
CREATE FUNCTION fn_recalc_purchase_total() RETURNS TRIGGER AS $$
DECLARE
target_purchase_id UUID := COALESCE(NEW.purchase_id, OLD.purchase_id);
BEGIN
UPDATE purchases SET total_amount = (
    SELECT COALESCE(SUM(subtotal), 0) FROM purchase_items WHERE purchase_id = target_purchase_id
) WHERE id = target_purchase_id;
RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_recalc_purchase_total
    AFTER INSERT OR UPDATE OR DELETE ON purchase_items
    FOR EACH ROW EXECUTE FUNCTION fn_recalc_purchase_total();

-- ============================================================================
-- DASHBOARD VIEWS — query these directly, don't recompute in app code
-- ============================================================================

-- Live stock per item per branch, summed across its batches
CREATE VIEW v_current_stock AS
SELECT
    inv.branch_id,
    inv.item_id,
    i.name AS item_name,
    i.reorder_level,
    SUM(inv.quantity_available) AS quantity_on_hand
FROM inventory inv
         JOIN items i ON i.id = inv.item_id
GROUP BY inv.branch_id, inv.item_id, i.name, i.reorder_level;

-- Low stock, needs reorder
CREATE VIEW v_low_stock AS
SELECT * FROM v_current_stock WHERE quantity_on_hand <= reorder_level;

-- Expiring within 90 days
CREATE VIEW v_expiring_soon AS
SELECT
    inv.id AS inventory_id,
    inv.branch_id,
    inv.item_id,
    i.name AS item_name,
    inv.quantity_available,
    inv.expiry_date,
    (inv.expiry_date - current_date) AS days_to_expiry
FROM inventory inv
         JOIN items i ON i.id = inv.item_id
WHERE inv.quantity_available > 0
  AND inv.expiry_date IS NOT NULL
  AND inv.expiry_date <= current_date + INTERVAL '90 days'
        ORDER BY inv.expiry_date ASC;

-- Today's sales per branch
CREATE VIEW v_today_sales AS
SELECT branch_id, COUNT(*) AS transaction_count, SUM(total_amount) AS total_sales
FROM sales
WHERE sale_date::date = current_date
GROUP BY branch_id;

-- Realised profit per branch per day
CREATE VIEW v_daily_profit AS
SELECT
    s.branch_id,
    s.sale_date::date AS sale_day,
    SUM(si.subtotal) AS revenue,
    SUM(si.unit_cost * si.quantity) AS cost_of_goods,
    SUM(si.profit) AS gross_profit
FROM sales s
         JOIN sale_items si ON si.sale_id = s.id
GROUP BY s.branch_id, s.sale_date::date;

-- Potential profit still on the shelf right now
CREATE VIEW v_expected_profit_from_stock AS
SELECT branch_id, SUM(quantity_available * (retail_price - buying_price)) AS potential_profit
FROM inventory
GROUP BY branch_id;

-- Net profit = realised gross profit to date minus expenses to date
CREATE VIEW v_branch_financial_summary AS
SELECT
    b.id AS branch_id,
    b.name AS branch_name,
    COALESCE(p.total_gross_profit, 0) AS total_gross_profit,
    COALESCE(e.total_expenses, 0) AS total_expenses,
    COALESCE(p.total_gross_profit, 0) - COALESCE(e.total_expenses, 0) AS net_profit
FROM branches b
         LEFT JOIN (SELECT branch_id, SUM(gross_profit) AS total_gross_profit FROM v_daily_profit GROUP BY branch_id) p
                   ON p.branch_id = b.id
         LEFT JOIN (SELECT branch_id, SUM(amount) AS total_expenses FROM expenses GROUP BY branch_id) e
                   ON e.branch_id = b.id;

-- Best-selling items (admin overview across all branches; filter by
-- branch_id in your query for a single store's view)
CREATE VIEW v_best_selling_items AS
SELECT
    si.item_id,
    i.name AS item_name,
    s.branch_id,
    SUM(si.quantity) AS total_quantity_sold,
    SUM(si.subtotal) AS total_revenue,
    SUM(si.profit) AS total_profit
FROM sale_items si
         JOIN sales s ON s.id = si.sale_id
         JOIN items i ON i.id = si.item_id
GROUP BY si.item_id, i.name, s.branch_id;

-- Outstanding customer debts
CREATE VIEW v_customer_debts AS
SELECT id AS customer_id, name, branch_id, current_balance
FROM customers
WHERE current_balance > 0;

-- Outstanding balances owed TO suppliers, across all their invoices
CREATE VIEW v_supplier_balances AS
SELECT
    s.id AS supplier_id,
    s.name AS supplier_name,
    SUM(p.total_amount - p.amount_paid) AS amount_owed
FROM suppliers s
         JOIN purchases p ON p.supplier_id = s.id
WHERE p.payment_status <> 'paid'
GROUP BY s.id, s.name
HAVING SUM(p.total_amount - p.amount_paid) > 0;

-- Full payment history for a customer (or filter by customer_id in your query)
CREATE VIEW v_customer_payment_history AS
SELECT id AS payment_id, customer_id, sale_id, branch_id, amount, payment_method, payment_date, recorded_by
FROM payments
WHERE customer_id IS NOT NULL
ORDER BY payment_date DESC;

-- Full payment history to a supplier
CREATE VIEW v_supplier_payment_history AS
SELECT id AS payment_id, supplier_id, purchase_id, branch_id, amount, payment_method, payment_date, recorded_by
FROM payments
WHERE supplier_id IS NOT NULL
ORDER BY payment_date DESC;


-- ============================================================================
-- LINK SUPABASE AUTH TO public.users
-- ============================================================================
-- Run this after your main schema. It does NOT replace the users table,
-- it wires it up to Supabase Auth so the two stay in sync automatically.

-- 1. users.id must be driven by the auth account, not generated on its own.
ALTER TABLE users ALTER COLUMN id DROP DEFAULT;
ALTER TABLE users
    ADD CONSTRAINT users_id_fkey_auth
        FOREIGN KEY (id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- 2. Add email so the client can read it without touching the auth schema
--    (the client API is not allowed to SELECT from auth.users directly).
ALTER TABLE users ADD COLUMN email TEXT;
UPDATE users SET email = '' WHERE email IS NULL; -- backfill any existing rows
ALTER TABLE users ALTER COLUMN email SET NOT NULL;

-- ============================================================================
-- 3. Auto-create the matching `users` row whenever someone signs up through
--    Supabase Auth. full_name / username come from the metadata you pass
--    into auth.signUp(data: {...}) on the Flutter side (see auth_repository.dart).
--
--    Username falls back to the email prefix + a slice of the user's own id,
--    so it still satisfies the UNIQUE constraint even if two people share an
--    email prefix (e.g. two "mable@" addresses at different domains).
-- ============================================================================
CREATE FUNCTION handle_new_auth_user() RETURNS TRIGGER AS $$
BEGIN
INSERT INTO public.users (id, email, full_name, username, role)
VALUES (
           NEW.id,
           NEW.email,
           COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
           COALESCE(
                   NEW.raw_user_meta_data->>'username',
            split_part(NEW.email, '@', 1) || '_' || substr(NEW.id::text, 1, 4)
        ),
           'cashier' -- default role; an admin reassigns it afterwards
       );
RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION handle_new_auth_user();

-- ============================================================================
-- 4. Row Level Security — staff can read their own row; admins can read
--    and update everyone's. Adjust branch scoping later if a manager should
--    only see their own branch's staff.
-- ============================================================================
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view their own profile"
    ON users FOR SELECT
                            USING (auth.uid() = id);

CREATE POLICY "Admins can view all profiles"
    ON users FOR SELECT
                            USING (
                            EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
                            );

CREATE POLICY "Admins can update any profile"
    ON users FOR UPDATE
                            USING (
                            EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.role = 'admin')
                            );

-- ============================================================================
-- PENDING-APPROVAL SIGNUP FLOW
-- Run after your main schema + auth_integration.sql.
--
-- Anyone can create an account. New accounts land with is_active = false,
-- a placeholder role, and no branch. They cannot meaningfully use the app
-- until an admin assigns a real role + branch and flips is_active = true
-- (see AuthRepository.approveUser on the Flutter side).
-- ============================================================================

-- 1. The original constraint required a branch for every non-admin user,
--    which blocked signup entirely since new users have no branch yet.
--    Relax it: a branch is only required once the account is active.
ALTER TABLE users DROP CONSTRAINT branch_required_unless_admin;
ALTER TABLE users ADD CONSTRAINT branch_required_unless_admin
    CHECK (role = 'admin' OR is_active = false OR branch_id IS NOT NULL);

-- 2. New signups now start inactive. 'cashier' is just a placeholder role
--    until an admin assigns the real one on approval — it has no effect
--    on access, since is_active = false blocks login regardless of role.
CREATE OR REPLACE FUNCTION handle_new_auth_user() RETURNS TRIGGER AS $$
BEGIN
INSERT INTO public.users (id, email, full_name, username, role, is_active)
VALUES (
           NEW.id,
           NEW.email,
           COALESCE(NEW.raw_user_meta_data->>'full_name', ''),
           COALESCE(
                   NEW.raw_user_meta_data->>'username',
            split_part(NEW.email, '@', 1) || '_' || substr(NEW.id::text, 1, 4)
        ),
           'cashier',
           false
       );
RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3. Fast lookup for an admin's "pending approvals" screen.
CREATE INDEX IF NOT EXISTS idx_users_pending ON users(is_active) WHERE is_active = false;

-- Existing RLS policies already cover this flow with no changes needed:
--   "Admins can view all profiles"  -> lets an admin list pending users
--   "Admins can update any profile" -> lets an admin set role/branch_id/is_active

-- ============================================================================
-- FIX: infinite recursion in RLS policies on `users`
--
-- The original "Admins can view/update all profiles" policies checked
-- role = 'admin' via a subquery on `users` itself. Every row-level check
-- on `users` re-triggers those same policies, which query `users` again,
-- forever. Postgres detects this and errors with 42P17.
--
-- Fix: do the admin check inside a SECURITY DEFINER function. It runs
-- with the function owner's privileges (normally the table owner), which
-- bypasses RLS on its own internal query — so it can safely check
-- "is this user an admin?" without re-entering the policy that's asking.
-- ============================================================================

CREATE OR REPLACE FUNCTION is_admin() RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
SELECT EXISTS (
    SELECT 1 FROM users WHERE id = auth.uid() AND role = 'admin'
);
$$;

DROP POLICY IF EXISTS "Admins can view all profiles" ON users;
CREATE POLICY "Admins can view all profiles"
    ON users FOR SELECT
                                 USING (is_admin());

DROP POLICY IF EXISTS "Admins can update any profile" ON users;
CREATE POLICY "Admins can update any profile"
    ON users FOR UPDATE
                                 USING (is_admin());

-- "Users can view their own profile" is untouched — it only checks
-- auth.uid() = id, no self-referencing subquery, so it was never the
-- source of the recursion.
CREATE OR REPLACE FUNCTION fn_apply_payment() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.customer_id IS NOT NULL THEN
UPDATE customers SET current_balance = current_balance - NEW.amount
WHERE id = NEW.customer_id;
END IF;

    IF NEW.sale_id IS NOT NULL THEN
UPDATE sales
SET amount_paid = amount_paid + NEW.amount,
    payment_status = CASE
                         WHEN amount_paid + NEW.amount >= total_amount THEN 'paid'
                         WHEN amount_paid + NEW.amount > 0 THEN 'partial'
                         ELSE 'pending'
        END
WHERE id = NEW.sale_id;
END IF;

    IF NEW.purchase_id IS NOT NULL THEN
UPDATE purchases SET amount_paid = amount_paid + NEW.amount
WHERE id = NEW.purchase_id;
END IF;
RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- FIX 1 — RLS: give admins (and branch staff) read access to the tables
-- the dashboard actually queries.
--
-- Run after your main schema + auth_integration.sql (this reuses is_admin()
-- from there).
--
-- Why this fixes the "empty dashboard" problem: v_low_stock and
-- v_expiring_soon are views, and views don't carry their own RLS policies.
-- Postgres enforces RLS by checking policies on the underlying TABLES
-- (inventory, items, branches, sales), evaluated as the querying user via
-- auth.uid() — not the view owner. So branches, inventory and sales having
-- no policies at all meant every query against them (views included) was
-- silently filtered down to zero rows once RLS is enabled on a table with
-- no matching policy — that's the default-deny behavior.
--
-- Scope of this fix: branches, items, inventory, sales, sale_items — what
-- the current admin dashboard needs. Staff also get branch-scoped access
-- (a cashier at Blantyre shouldn't see Mzuzu's sales) since you'll need
-- that regardless once staff screens start querying these tables. If you
-- later want the same pattern on purchases, payments, customers, expenses,
-- stock_movements and suppliers, it's a straightforward copy of the
-- "sales" block below with the table name swapped in — say the word and
-- I'll write that migration too.
-- ============================================================================

-- Helper: the branch_id of the currently authenticated user (NULL for
-- admins, who aren't tied to one branch).
CREATE OR REPLACE FUNCTION user_branch_id() RETURNS uuid
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path = public
AS $$
SELECT branch_id FROM users WHERE id = auth.uid();
$$;

-- ---------------------------------------------------------------------------
-- BRANCHES — reference data every signed-in, active user needs (for the
-- filter dropdown, branch names on receipts, etc). Only admins edit it.
-- ---------------------------------------------------------------------------
ALTER TABLE branches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can view branches"
    ON branches FOR SELECT
                               USING (auth.uid() IS NOT NULL);

CREATE POLICY "Admins manage branches"
    ON branches FOR ALL
    USING (is_admin())
    WITH CHECK (is_admin());

-- ---------------------------------------------------------------------------
-- ITEMS — the drug catalogue, same treatment as branches.
-- ---------------------------------------------------------------------------
ALTER TABLE items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated users can view items"
    ON items FOR SELECT
                            USING (auth.uid() IS NOT NULL);

CREATE POLICY "Admins manage items"
    ON items FOR ALL
    USING (is_admin())
    WITH CHECK (is_admin());

-- ---------------------------------------------------------------------------
-- INVENTORY — batch-level stock. Admins see every branch; staff see only
-- their own. v_current_stock, v_low_stock and v_expiring_soon are all built
-- on this table, so these two policies cover all three views at once.
-- ---------------------------------------------------------------------------
ALTER TABLE inventory ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins view all inventory"
    ON inventory FOR SELECT
                                USING (is_admin());

CREATE POLICY "Staff view own branch inventory"
    ON inventory FOR SELECT
                                USING (branch_id = user_branch_id());

CREATE POLICY "Admins and staff manage own branch inventory"
    ON inventory FOR ALL
    USING (is_admin() OR branch_id = user_branch_id())
    WITH CHECK (is_admin() OR branch_id = user_branch_id());

-- ---------------------------------------------------------------------------
-- SALES — admins see every branch; staff see and record only their own.
-- v_today_sales is built on this table, so it inherits these policies too.
-- ---------------------------------------------------------------------------
ALTER TABLE sales ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins view all sales"
    ON sales FOR SELECT
                            USING (is_admin());

CREATE POLICY "Staff view own branch sales"
    ON sales FOR SELECT
                            USING (branch_id = user_branch_id());

CREATE POLICY "Staff record sales at own branch"
    ON sales FOR INSERT
    WITH CHECK (is_admin() OR branch_id = user_branch_id());

CREATE POLICY "Admins update any sale"
    ON sales FOR UPDATE
                                   USING (is_admin())
                 WITH CHECK (is_admin());

-- sale_items has no branch_id of its own — access follows the parent sale.
ALTER TABLE sale_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "View sale_items via parent sale access"
    ON sale_items FOR SELECT
                                 USING (
                                 EXISTS (
                                 SELECT 1 FROM sales s
                                 WHERE s.id = sale_items.sale_id
                                 AND (is_admin() OR s.branch_id = user_branch_id())
                                 )
                                 );

CREATE POLICY "Insert sale_items via parent sale access"
    ON sale_items FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM sales s
            WHERE s.id = sale_items.sale_id
              AND (is_admin() OR s.branch_id = user_branch_id())
        )
    );

-- ============================================================================
-- FIX 2 — views carry branch_name directly, so the app doesn't need to
-- join against `branches` in Dart just to label a row.
--
-- branch_name is appended as the LAST column in each view (rather than
-- inserted where it reads naturally) so this is a safe CREATE OR REPLACE —
-- Postgres requires existing columns to keep their name/position/type in a
-- replaced view; new columns can only be added at the end.
-- ============================================================================

CREATE OR REPLACE VIEW v_current_stock AS
SELECT
    inv.branch_id,
    inv.item_id,
    i.name AS item_name,
    i.reorder_level,
    SUM(inv.quantity_available) AS quantity_on_hand,
    b.name AS branch_name
FROM inventory inv
         JOIN items i ON i.id = inv.item_id
         JOIN branches b ON b.id = inv.branch_id
GROUP BY inv.branch_id, inv.item_id, i.name, i.reorder_level, b.name;

-- v_low_stock is SELECT * from v_current_stock, so it picks up branch_name
-- automatically — no change needed, but re-stating it keeps this file
-- runnable top-to-bottom even if v_low_stock didn't exist yet.
CREATE OR REPLACE VIEW v_low_stock AS
SELECT * FROM v_current_stock WHERE quantity_on_hand <= reorder_level;

CREATE OR REPLACE VIEW v_expiring_soon AS
SELECT
    inv.id AS inventory_id,
    inv.branch_id,
    inv.item_id,
    i.name AS item_name,
    inv.quantity_available,
    inv.expiry_date,
    (inv.expiry_date - current_date) AS days_to_expiry,
    b.name AS branch_name
FROM inventory inv
         JOIN items i ON i.id = inv.item_id
         JOIN branches b ON b.id = inv.branch_id
WHERE inv.quantity_available > 0
  AND inv.expiry_date IS NOT NULL
  AND inv.expiry_date <= current_date + INTERVAL '90 days'
ORDER BY inv.expiry_date ASC;

-- ============================================================================
-- ADMIN MANAGEMENT — run once in the Supabase SQL editor, after your existing
-- schema + dashboard_rls_and_views.sql (this reuses is_admin()).
--
-- What already works without this file (existing RLS policies):
--   * create / edit / activate / deactivate branches   ("Admins manage branches")
--   * assign a user to a branch, remove them from one  ("Admins can update any profile")
--
-- What needs this file:
--   * deleting a branch   -> admin_delete_branch()
--   * deleting a user     -> admin_delete_user()
--     (the client API can't touch auth.users, so this runs server-side)
--
-- Both functions check is_admin() themselves, so a non-admin calling them gets
-- an error even though they are SECURITY DEFINER.
--
-- Deleting is refused when the row is referenced by real history (sales,
-- stock, payments...). Postgres raises a foreign-key error, the function
-- turns it into a readable message, and the whole operation rolls back —
-- nobody is left half-unassigned.
-- ============================================================================

CREATE OR REPLACE FUNCTION admin_delete_branch(p_branch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only admins can delete branches.';
END IF;

    -- Free the staff first. Non-admins are deactivated (the schema requires a
    -- branch for any active non-admin); admins just lose the link.
UPDATE users
SET branch_id = NULL,
    is_active = CASE WHEN role = 'admin' THEN is_active ELSE false END
WHERE branch_id = p_branch_id;

DELETE FROM branches WHERE id = p_branch_id;

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'This branch has stock, sales or other records and can''t be deleted. Deactivate it instead.';
END;
$$;

CREATE OR REPLACE FUNCTION admin_delete_user(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT is_admin() THEN
        RAISE EXCEPTION 'Only admins can delete users.';
END IF;

    IF p_user_id = auth.uid() THEN
        RAISE EXCEPTION 'You can''t delete your own account.';
END IF;

    -- public.users.id references auth.users(id) ON DELETE CASCADE, so removing
    -- the auth account removes the profile row too.
DELETE FROM auth.users WHERE id = p_user_id;

EXCEPTION
    WHEN foreign_key_violation THEN
        RAISE EXCEPTION 'This user has recorded sales, stock or payment activity, so the account can''t be deleted. Remove them from their branch instead.';
END;
$$;

-- Only signed-in users may call these (and they still must pass is_admin()).
REVOKE ALL ON FUNCTION admin_delete_branch(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION admin_delete_user(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION admin_delete_branch(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION admin_delete_user(uuid) TO authenticated;