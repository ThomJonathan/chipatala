import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================================================
// EMPLOYEE HOME — REPOSITORY (branch-scoped, read-only except payments)
//   Every query is filtered to the staff member's own branch_id. RLS backs
//   this up for sales / sale_items / inventory (own-branch policies); the
//   other tables are readable without RLS. Buying prices and supplier data
//   are never selected here, so cashier layouts can't leak them.
// ============================================================================

class EmployeeHomeException implements Exception {
  final String message;
  const EmployeeHomeException(this.message);
  @override
  String toString() => message;
}

class LowItem {
  final String itemName;
  final double qtyOnHand;
  final double reorderLevel;
  const LowItem({required this.itemName, required this.qtyOnHand, required this.reorderLevel});
}

class ExpiringItem {
  final String itemName;
  final String expiryDate;
  final int daysToExpiry;
  final double qty;
  const ExpiringItem({
    required this.itemName,
    required this.expiryDate,
    required this.daysToExpiry,
    required this.qty,
  });
}

class RecentSale {
  final String id;
  final String time; // ISO sale_date
  final String receipt;
  final double total;
  final String method;
  final int itemCount;
  const RecentSale({
    required this.id,
    required this.time,
    required this.receipt,
    required this.total,
    required this.method,
    required this.itemCount,
  });
}

class ReceiptLine {
  final String itemName;
  final double qty;
  final double unitPrice;
  final double subtotal;
  const ReceiptLine({
    required this.itemName,
    required this.qty,
    required this.unitPrice,
    required this.subtotal,
  });
}

class Receipt {
  final String receiptNo;
  final String time;
  final String method;
  final double total;
  final double paid;
  final String cashier;
  final List<ReceiptLine> lines;
  const Receipt({
    required this.receiptNo,
    required this.time,
    required this.method,
    required this.total,
    required this.paid,
    required this.cashier,
    required this.lines,
  });
}

class OwingCustomer {
  final String id;
  final String name;
  final double balance;
  const OwingCustomer({required this.id, required this.name, required this.balance});
}

class LookupItem {
  final String itemId;
  final String name;
  final double retailMin;
  final double retailMax;
  final double? wholesaleMin;
  final double? wholesaleMax;
  final double qty;
  const LookupItem({
    required this.itemId,
    required this.name,
    required this.retailMin,
    required this.retailMax,
    required this.wholesaleMin,
    required this.wholesaleMax,
    required this.qty,
  });
}

class BranchMove {
  final String itemName;
  final String type;
  final double qty;
  final String time;
  final String? notes;
  const BranchMove({
    required this.itemName,
    required this.type,
    required this.qty,
    required this.time,
    required this.notes,
  });
}

class EmployeeHomeBundle {
  final int salesCount;
  final double salesTotal;
  final double cashTotal;
  final double mobileTotal;
  final double creditTotal;
  final double cardTotal;
  final List<LowItem> lowTop;
  final int lowCount;
  final List<ExpiringItem> expiringTop;
  final int expiringCount;
  final List<RecentSale> recentSales;
  final int owingCount;
  final double owingTotal;
  // Manager only:
  final double grossToday;
  final double expensesToday;
  // Stock controller only:
  final List<BranchMove> recentMoves;

  const EmployeeHomeBundle({
    required this.salesCount,
    required this.salesTotal,
    required this.cashTotal,
    required this.mobileTotal,
    required this.creditTotal,
    required this.cardTotal,
    required this.lowTop,
    required this.lowCount,
    required this.expiringTop,
    required this.expiringCount,
    required this.recentSales,
    required this.owingCount,
    required this.owingTotal,
    required this.grossToday,
    required this.expensesToday,
    required this.recentMoves,
  });
}

class EmployeeHomeRepository {
  final SupabaseClient _client = Supabase.instance.client;

  ({DateTime start, DateTime end}) _todayRange() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    return (start: start, end: start.add(const Duration(days: 1)));
  }

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// [role] controls the extra sections: 'manager' adds profit/expenses,
  /// 'stock_controller' adds recent movements. Cashiers get neither.
  Future<EmployeeHomeBundle> fetchHome({required String branchId, required String role}) async {
    final range = _todayRange();
    final client = _client;

    // ---- Today's sales (also feeds the recent list) -------------------------
    final salesRows = await client
        .from('sales')
        .select('id, total_amount, payment_method, sale_date, receipt_number')
        .eq('branch_id', branchId)
        .gte('sale_date', range.start.toIso8601String())
        .lt('sale_date', range.end.toIso8601String())
        .order('sale_date', ascending: false)
        .limit(500) as List;

    var total = 0.0, cash = 0.0, mobile = 0.0, credit = 0.0, card = 0.0;
    for (final r in salesRows) {
      final amt = ((r['total_amount'] as num?) ?? 0).toDouble();
      total += amt;
      switch (r['payment_method'] as String?) {
        case 'cash':
          cash += amt;
        case 'mobile_money':
          mobile += amt;
        case 'credit':
          credit += amt;
        case 'card':
          card += amt;
      }
    }

    // ---- Recent sales + their line counts ------------------------------------
    final recentIds = salesRows.take(8).map((r) => r['id'] as String).toList();
    final counts = <String, int>{};
    if (recentIds.isNotEmpty) {
      final lines = await client
          .from('sale_items')
          .select('sale_id')
          .inFilter('sale_id', recentIds)
          .limit(500) as List;
      for (final l in lines) {
        final sid = l['sale_id'] as String;
        counts[sid] = (counts[sid] ?? 0) + 1;
      }
    }
    final recentSales = salesRows.take(8).map((r) {
      final id = r['id'] as String;
      return RecentSale(
        id: id,
        time: (r['sale_date'] as String?) ?? '',
        receipt: (r['receipt_number'] as String?) ?? '—',
        total: ((r['total_amount'] as num?) ?? 0).toDouble(),
        method: (r['payment_method'] as String?) ?? '',
        itemCount: counts[id] ?? 0,
      );
    }).toList();

    // ---- Low stock at this branch ---------------------------------------------
    final lowRows = await client
        .from('v_low_stock')
        .select('item_name, reorder_level, quantity_on_hand')
        .eq('branch_id', branchId)
        .limit(200) as List;
    final lowItems = lowRows
        .map((r) => LowItem(
              itemName: r['item_name'] as String,
              qtyOnHand: ((r['quantity_on_hand'] as num?) ?? 0).toDouble(),
              reorderLevel: ((r['reorder_level'] as num?) ?? 0).toDouble(),
            ))
        .toList();
    lowItems.sort((a, b) {
      double sev(LowItem x) => x.reorderLevel <= 0 ? 0 : (x.qtyOnHand / x.reorderLevel).clamp(0.0, 1.0);
      return sev(a).compareTo(sev(b));
    });

    // ---- Expiring soon at this branch ------------------------------------------
    final expRows = await client
        .from('v_expiring_soon')
        .select('item_name, expiry_date, days_to_expiry, quantity_available')
        .eq('branch_id', branchId)
        .limit(200) as List;
    final expItems = expRows
        .map((r) => ExpiringItem(
              itemName: r['item_name'] as String,
              expiryDate: (r['expiry_date'] as String?) ?? '',
              daysToExpiry: ((r['days_to_expiry'] as num?) ?? 999).toInt(),
              qty: ((r['quantity_available'] as num?) ?? 0).toDouble(),
            ))
        .toList();
    expItems.sort((a, b) => a.daysToExpiry.compareTo(b.daysToExpiry));

    // ---- Customers owing at this branch -----------------------------------------
    final debtRows = await client
        .from('v_customer_debts')
        .select('customer_id, name, current_balance')
        .eq('branch_id', branchId)
        .order('current_balance', ascending: false)
        .limit(200) as List;
    var owingTotal = 0.0;
    for (final r in debtRows) {
      owingTotal += ((r['current_balance'] as num?) ?? 0).toDouble();
    }

    // ---- Manager extras: gross profit + expenses today --------------------------
    var gross = 0.0, expTotal = 0.0;
    if (role == 'manager') {
      final todayIds = salesRows.map((r) => r['id'] as String).toList();
      for (var i = 0; i < todayIds.length; i += 200) {
        final chunk = todayIds.sublist(i, (i + 200).clamp(0, todayIds.length));
        final prows = await client
            .from('sale_items')
            .select('profit')
            .inFilter('sale_id', chunk)
            .limit(10000) as List;
        for (final p in prows) {
          gross += ((p['profit'] as num?) ?? 0).toDouble();
        }
      }
      final erows = await client
          .from('expenses')
          .select('amount')
          .eq('branch_id', branchId)
          .eq('expense_date', _todayStr()) as List;
      for (final r in erows) {
        expTotal += ((r['amount'] as num?) ?? 0).toDouble();
      }
    }

    // ---- Stock controller extras: recent movements -------------------------------
    var moves = <BranchMove>[];
    if (role == 'stock_controller') {
      final mrows = await client
          .from('stock_movements')
          .select('movement_type, quantity, notes, created_at, items(name)')
          .eq('branch_id', branchId)
          .order('created_at', ascending: false)
          .limit(10) as List;
      moves = mrows.map((r) {
        final item = r['items'];
        return BranchMove(
          itemName: (item is Map ? item['name'] as String? : null) ?? '—',
          type: (r['movement_type'] as String?) ?? '—',
          qty: ((r['quantity'] as num?) ?? 0).toDouble(),
          time: (r['created_at'] as String?) ?? '',
          notes: r['notes'] as String?,
        );
      }).toList();
    }

    return EmployeeHomeBundle(
      salesCount: salesRows.length,
      salesTotal: total,
      cashTotal: cash,
      mobileTotal: mobile,
      creditTotal: credit,
      cardTotal: card,
      lowTop: lowItems.take(3).toList(),
      lowCount: lowItems.length,
      expiringTop: expItems.take(3).toList(),
      expiringCount: expItems.length,
      recentSales: recentSales,
      owingCount: debtRows.length,
      owingTotal: owingTotal,
      grossToday: gross,
      expensesToday: expTotal,
      recentMoves: moves,
    );
  }

  /// Price + availability lookup. Never returns buying prices.
  Future<List<LookupItem>> lookup({required String branchId, required String query}) async {
    final q = query.trim();
    if (q.length < 2) return [];
    final items = await _client
        .from('items')
        .select('id, name')
        .ilike('name', '%$q%')
        .eq('is_active', true)
        .order('name')
        .limit(10) as List;
    if (items.isEmpty) return [];
    final ids = items.map((r) => r['id'] as String).toList();
    final stock = await _client
        .from('inventory')
        .select('item_id, quantity_available, retail_price, wholesale_price')
        .eq('branch_id', branchId)
        .inFilter('item_id', ids)
        .gt('quantity_available', 0)
        .limit(200) as List;

    final byItem = <String, List<Map>>{};
    for (final r in stock) {
      byItem.putIfAbsent(r['item_id'] as String, () => []).add(r as Map);
    }
    final out = <LookupItem>[];
    for (final it in items) {
      final id = it['id'] as String;
      final batches = byItem[id] ?? [];
      if (batches.isEmpty) continue;
      var qty = 0.0;
      var rMin = double.infinity, rMax = 0.0;
      double? wMin, wMax;
      for (final b in batches) {
        qty += ((b['quantity_available'] as num?) ?? 0).toDouble();
        final r = ((b['retail_price'] as num?) ?? 0).toDouble();
        if (r < rMin) rMin = r;
        if (r > rMax) rMax = r;
        final w = (b['wholesale_price'] as num?)?.toDouble();
        if (w != null) {
          wMin = wMin == null ? w : (w < wMin ? w : wMin);
          wMax = wMax == null ? w : (w > wMax ? w : wMax);
        }
      }
      out.add(LookupItem(
        itemId: id,
        name: it['name'] as String,
        retailMin: rMin.isFinite ? rMin : 0,
        retailMax: rMax,
        wholesaleMin: wMin,
        wholesaleMax: wMax,
        qty: qty,
      ));
    }
    return out;
  }

  Future<List<OwingCustomer>> owingCustomers({required String branchId}) async {
    final rows = await _client
        .from('v_customer_debts')
        .select('customer_id, name, current_balance')
        .eq('branch_id', branchId)
        .order('current_balance', ascending: false)
        .limit(200) as List;
    return rows
        .map((r) => OwingCustomer(
              id: (r['customer_id'] as String?) ?? '',
              name: (r['name'] as String?) ?? 'Unknown',
              balance: ((r['current_balance'] as num?) ?? 0).toDouble(),
            ))
        .toList();
  }

  Future<Receipt> receipt(String saleId) async {
    final head = await _client.from('sales').select('receipt_number, sale_date, payment_method, total_amount, amount_paid, cashier_id').eq('id', saleId).single();
    final lines = await _client
        .from('sale_items')
        .select('quantity, unit_price, subtotal, items(name)')
        .eq('sale_id', saleId)
        .limit(200) as List;
    var cashier = '';
    try {
      final u = await _client.from('users').select('full_name').eq('id', head['cashier_id']).single();
      cashier = (u['full_name'] as String?) ?? '';
    } catch (_) {}
    return Receipt(
      receiptNo: (head['receipt_number'] as String?) ?? '—',
      time: (head['sale_date'] as String?) ?? '',
      method: (head['payment_method'] as String?) ?? '',
      total: ((head['total_amount'] as num?) ?? 0).toDouble(),
      paid: ((head['amount_paid'] as num?) ?? 0).toDouble(),
      cashier: cashier,
      lines: lines.map((l) {
        final item = l['items'];
        return ReceiptLine(
          itemName: (item is Map ? item['name'] as String? : null) ?? '—',
          qty: ((l['quantity'] as num?) ?? 0).toDouble(),
          unitPrice: ((l['unit_price'] as num?) ?? 0).toDouble(),
          subtotal: ((l['subtotal'] as num?) ?? 0).toDouble(),
        );
      }).toList(),
    );
  }

  /// Records a customer payment. The DB trigger drops the customer's balance.
  Future<void> recordPayment({
    required String branchId,
    required String customerId,
    required double amount,
    required String method,
  }) async {
    if (amount <= 0) throw const EmployeeHomeException('Enter an amount above zero.');
    final uid = _client.auth.currentUser?.id;
    await _client.from('payments').insert({
      'branch_id': branchId,
      'customer_id': customerId,
      'amount': amount,
      'payment_method': method,
      if (uid != null) 'recorded_by': uid,
    });
  }
}
