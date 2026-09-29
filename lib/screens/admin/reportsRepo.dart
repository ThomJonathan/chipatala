import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================================================
// ADMIN REPORTS — REPOSITORY (read-only; every figure is computed live)
//   Sales + sale_items  -> revenue, trends, profit, best sellers
//   expenses            -> operating costs (what turns gross into net)
//   v_expected_profit_from_stock -> forward-looking stock profit (no period)
//   v_customer_debts / v_supplier_balances + payment-history views -> debts
// ============================================================================

class ReportBranch {
  final String id;
  final String name;
  const ReportBranch({required this.id, required this.name});
}

class SaleRow {
  final String id;
  final String branchId;
  final String branchName;
  final double totalAmount;
  final DateTime saleDate;
  final String paymentMethod;
  const SaleRow({
    required this.id,
    required this.branchId,
    required this.branchName,
    required this.totalAmount,
    required this.saleDate,
    required this.paymentMethod,
  });
}

class SaleItemRow {
  final String saleId;
  final String branchId;
  final String itemId;
  final String itemName;
  final double quantity;
  final double subtotal;
  final double profit;
  const SaleItemRow({
    required this.saleId,
    required this.branchId,
    required this.itemId,
    required this.itemName,
    required this.quantity,
    required this.subtotal,
    required this.profit,
  });
}

class ExpenseRow {
  final String id;
  final String branchId;
  final String branchName;
  final String category;
  final double amount;
  final String description;
  final String expenseDate;
  const ExpenseRow({
    required this.id,
    required this.branchId,
    required this.branchName,
    required this.category,
    required this.amount,
    required this.description,
    required this.expenseDate,
  });
}

class PeriodBundle {
  final List<SaleRow> sales;
  final List<SaleItemRow> saleItems;
  final List<ExpenseRow> expenses;
  final Map<String, double> stockProfitByBranch; // branchId -> potential
  const PeriodBundle({
    required this.sales,
    required this.saleItems,
    required this.expenses,
    required this.stockProfitByBranch,
  });

  static const empty = PeriodBundle(sales: [], saleItems: [], expenses: [], stockProfitByBranch: {});
}

class CustomerDebt {
  final String customerId;
  final String name;
  final String branchId;
  final String branchName;
  final double balance;
  const CustomerDebt({
    required this.customerId,
    required this.name,
    required this.branchId,
    required this.branchName,
    required this.balance,
  });
}

class SupplierDebt {
  final String supplierId;
  final String supplierName;
  final double amountOwed;
  const SupplierDebt({required this.supplierId, required this.supplierName, required this.amountOwed});
}

class DebtPayment {
  final double amount;
  final String method;
  final String date;
  final String? note;
  const DebtPayment({required this.amount, required this.method, required this.date, required this.note});
}

// ============================================================================
// PERIODS — every option from the spec. Years are whole calendar years:
// "last 3 years" in 2026 covers 1 Jan 2024 -> today.
// ============================================================================

enum ReportPeriodType { today, week, month, year, day, custom, lastYears }

enum TrendGranularity { hour, day, month, year }

class ReportPeriod {
  final ReportPeriodType type;
  final DateTime start; // inclusive, local
  final DateTime end; // exclusive, local
  final int years; // only for lastYears
  final DateTime? pickedDay; // only for day
  const ReportPeriod._(this.type, this.start, this.end, {this.years = 0, this.pickedDay});

  static DateTime _midnight(DateTime d) => DateTime(d.year, d.month, d.day);

  static ReportPeriod today() {
    final s = _midnight(DateTime.now());
    return ReportPeriod._(ReportPeriodType.today, s, s.add(const Duration(days: 1)));
  }

  static ReportPeriod week() {
    final now = DateTime.now();
    final s = _midnight(now.subtract(Duration(days: now.weekday - 1)));
    return ReportPeriod._(ReportPeriodType.week, s, s.add(const Duration(days: 7)));
  }

  static ReportPeriod month() {
    final now = DateTime.now();
    final s = DateTime(now.year, now.month, 1);
    final e = now.month == 12 ? DateTime(now.year + 1, 1, 1) : DateTime(now.year, now.month + 1, 1);
    return ReportPeriod._(ReportPeriodType.month, s, e);
  }

  static ReportPeriod year() {
    final now = DateTime.now();
    return ReportPeriod._(ReportPeriodType.year, DateTime(now.year, 1, 1), DateTime(now.year + 1, 1, 1));
  }

  static ReportPeriod singleDay(DateTime day) {
    final s = _midnight(day);
    return ReportPeriod._(ReportPeriodType.day, s, s.add(const Duration(days: 1)), pickedDay: s);
  }

  static ReportPeriod custom(DateTime from, DateTime to) {
    final s = _midnight(from);
    final e = _midnight(to).add(const Duration(days: 1));
    return ReportPeriod._(ReportPeriodType.custom, s, e);
  }

  static ReportPeriod lastYears(int n) {
    final now = DateTime.now();
    return ReportPeriod._(
      ReportPeriodType.lastYears,
      DateTime(now.year - n + 1, 1, 1),
      _midnight(now).add(const Duration(days: 1)),
      years: n,
    );
  }

  bool get isSingleDay => type == ReportPeriodType.today || type == ReportPeriodType.day;

  int get dayCount => end.difference(start).inDays;

  TrendGranularity get granularity {
    if (isSingleDay) return TrendGranularity.hour;
    if (dayCount <= 62) return TrendGranularity.day;
    if (dayCount <= 370) return TrendGranularity.month;
    return TrendGranularity.year;
  }

  String label() {
    String d(DateTime x) => '${x.day}/${x.month}/${x.year}';
    switch (type) {
      case ReportPeriodType.today:
        return 'Today';
      case ReportPeriodType.week:
        return 'This week';
      case ReportPeriodType.month:
        const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return '${m[start.month - 1]} ${start.year}';
      case ReportPeriodType.year:
        return '${start.year}';
      case ReportPeriodType.day:
        return d(start);
      case ReportPeriodType.custom:
        return '${d(start)} – ${d(end.subtract(const Duration(days: 1)))}';
      case ReportPeriodType.lastYears:
        return 'Last $years yrs';
    }
  }

  String describe() {
    String d(DateTime x) => '${x.day}/${x.month}/${x.year}';
    switch (type) {
      case ReportPeriodType.today:
        return 'Today, ${d(start)}';
      case ReportPeriodType.week:
        return 'Week of ${d(start)}';
      case ReportPeriodType.month:
        return label();
      case ReportPeriodType.year:
        return 'Year ${start.year}';
      case ReportPeriodType.day:
        return d(start);
      case ReportPeriodType.custom:
        return '${d(start)} → ${d(end.subtract(const Duration(days: 1)))}';
      case ReportPeriodType.lastYears:
        return '${start.year} → ${DateTime.now().year} so far';
    }
  }
}

// ============================================================================
// AGGREGATIONS (pure — easy to test, used by every tab + both exports)
// ============================================================================

class TrendPoint {
  final String label;
  final double value;
  const TrendPoint(this.label, this.value);
}

class BranchSales {
  final String branchId;
  final String branchName;
  final int transactions;
  final double revenue;
  const BranchSales({
    required this.branchId,
    required this.branchName,
    required this.transactions,
    required this.revenue,
  });
}

class ProfitRow {
  final String branchId;
  final String branchName;
  final double revenue;
  final double cogs;
  final double gross;
  final double expenses;
  final double net;
  final double stockProfit;
  const ProfitRow({
    required this.branchId,
    required this.branchName,
    required this.revenue,
    required this.cogs,
    required this.gross,
    required this.expenses,
    required this.net,
    required this.stockProfit,
  });
}

class BestRow {
  final String itemId;
  final String itemName;
  final double qty;
  final double revenue;
  final double profit;
  final int times;
  const BestRow({
    required this.itemId,
    required this.itemName,
    required this.qty,
    required this.revenue,
    required this.profit,
    required this.times,
  });
}

class CategoryTotal {
  final String category;
  final double amount;
  final int count;
  const CategoryTotal({required this.category, required this.amount, required this.count});
}

List<BranchSales> aggregateBranchSales(List<SaleRow> sales) {
  final map = <String, BranchSales>{};
  for (final s in sales) {
    final prev = map[s.branchId];
    map[s.branchId] = BranchSales(
      branchId: s.branchId,
      branchName: s.branchName,
      transactions: (prev?.transactions ?? 0) + 1,
      revenue: (prev?.revenue ?? 0) + s.totalAmount,
    );
  }
  final list = map.values.toList()..sort((a, b) => b.revenue.compareTo(a.revenue));
  return list;
}

List<TrendPoint> buildTrend(List<SaleRow> sales, ReportPeriod p) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  switch (p.granularity) {
    case TrendGranularity.hour:
      final buckets = List<double>.filled(24, 0);
      for (final s in sales) {
        final local = s.saleDate.toLocal();
        if (local.isBefore(p.start) || !local.isBefore(p.end)) continue;
        buckets[local.hour] += s.totalAmount;
      }
      return [for (int h = 0; h < 24; h++) TrendPoint('${h}h', buckets[h])];
    case TrendGranularity.day:
      final days = p.dayCount <= 0 ? 1 : p.dayCount;
      final buckets = List<double>.filled(days, 0);
      for (final s in sales) {
        final local = s.saleDate.toLocal();
        final idx = DateTime(local.year, local.month, local.day).difference(p.start).inDays;
        if (idx >= 0 && idx < days) buckets[idx] += s.totalAmount;
      }
      return [
        for (int i = 0; i < days; i++)
          TrendPoint('${p.start.add(Duration(days: i)).day} ${months[p.start.add(Duration(days: i)).month - 1]}', buckets[i]),
      ];
    case TrendGranularity.month:
      final buckets = <String, double>{};
      final order = <String>[];
      var cursor = DateTime(p.start.year, p.start.month, 1);
      while (cursor.isBefore(p.end)) {
        final key = '${months[cursor.month - 1]} ${cursor.year}';
        buckets[key] = 0;
        order.add(key);
        cursor = cursor.month == 12
            ? DateTime(cursor.year + 1, 1, 1)
            : DateTime(cursor.year, cursor.month + 1, 1);
      }
      for (final s in sales) {
        final local = s.saleDate.toLocal();
        final key = '${months[local.month - 1]} ${local.year}';
        if (buckets.containsKey(key)) buckets[key] = buckets[key]! + s.totalAmount;
      }
      return [for (final k in order) TrendPoint(k, buckets[k]!)];
    case TrendGranularity.year:
      final buckets = <int, double>{};
      for (int y = p.start.year; y <= p.end.year; y++) {
        buckets[y] = 0;
      }
      for (final s in sales) {
        final y = s.saleDate.toLocal().year;
        if (buckets.containsKey(y)) buckets[y] = buckets[y]! + s.totalAmount;
      }
      final years = buckets.keys.toList()..sort();
      return [for (final y in years) TrendPoint('$y', buckets[y]!)];
  }
}

List<ProfitRow> buildProfit(
  List<SaleItemRow> items,
  List<ExpenseRow> expenses,
  Map<String, String> branchNames,
  Map<String, double> stockProfit,
) {
  final rev = <String, double>{};
  final cogs = <String, double>{};
  for (final it in items) {
    rev[it.branchId] = (rev[it.branchId] ?? 0) + it.subtotal;
    cogs[it.branchId] = (cogs[it.branchId] ?? 0) + (it.subtotal - it.profit);
  }
  final exp = <String, double>{};
  for (final e in expenses) {
    exp[e.branchId] = (exp[e.branchId] ?? 0) + e.amount;
  }
  final ids = <String>{...rev.keys, ...exp.keys, ...branchNames.keys};
  final rows = <ProfitRow>[];
  for (final id in ids) {
    final r = rev[id] ?? 0;
    final c = cogs[id] ?? 0;
    final g = r - c;
    final x = exp[id] ?? 0;
    rows.add(ProfitRow(
      branchId: id,
      branchName: branchNames[id] ?? 'Unknown branch',
      revenue: r,
      cogs: c,
      gross: g,
      expenses: x,
      net: g - x,
      stockProfit: stockProfit[id] ?? 0,
    ));
  }
  // Ranked best -> worst by net profit.
  rows.sort((a, b) => b.net.compareTo(a.net));
  return rows;
}

List<BestRow> buildBestSellers(List<SaleItemRow> items) {
  final map = <String, BestRow>{};
  for (final it in items) {
    final prev = map[it.itemId];
    map[it.itemId] = BestRow(
      itemId: it.itemId,
      itemName: it.itemName,
      qty: (prev?.qty ?? 0) + it.quantity,
      revenue: (prev?.revenue ?? 0) + it.subtotal,
      profit: (prev?.profit ?? 0) + it.profit,
      times: (prev?.times ?? 0) + 1,
    );
  }
  return map.values.toList();
}

List<CategoryTotal> buildCategoryTotals(List<ExpenseRow> expenses) {
  final map = <String, CategoryTotal>{};
  for (final e in expenses) {
    final prev = map[e.category];
    map[e.category] = CategoryTotal(
      category: e.category,
      amount: (prev?.amount ?? 0) + e.amount,
      count: (prev?.count ?? 0) + 1,
    );
  }
  final list = map.values.toList()..sort((a, b) => b.amount.compareTo(a.amount));
  return list;
}

// ============================================================================
// REPOSITORY
// ============================================================================

class ReportsRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<ReportBranch>> fetchBranches() async {
    final rows = await _client
        .from('branches')
        .select('id, name')
        .eq('is_active', true)
        .order('name') as List;
    return rows.map((r) => ReportBranch(id: r['id'] as String, name: r['name'] as String)).toList();
  }

  Future<PeriodBundle> fetchPeriodData({String? branchId, required ReportPeriod period}) async {
    final branches = await fetchBranches();
    final names = {for (final b in branches) b.id: b.name};

    // ---- Sales in range ----------------------------------------------------
    dynamic salesQ = _client.from('sales').select(
        'id, branch_id, total_amount, sale_date, payment_method, sale_type, branches(name)');
    if (branchId != null) salesQ = salesQ.eq('branch_id', branchId);
    final salesRows = await salesQ
        .gte('sale_date', period.start.toIso8601String())
        .lt('sale_date', period.end.toIso8601String())
        .order('sale_date')
        .limit(5000) as List;

    final sales = <SaleRow>[];
    final saleBranch = <String, String>{};
    for (final r in salesRows) {
      final br = r['branches'];
      final bId = r['branch_id'] as String;
      saleBranch[r['id'] as String] = bId;
      DateTime dt;
      try {
        dt = DateTime.parse(r['sale_date'] as String);
      } catch (_) {
        dt = period.start;
      }
      sales.add(SaleRow(
        id: r['id'] as String,
        branchId: bId,
        branchName: (br is Map ? br['name'] as String? : null) ?? names[bId] ?? 'Unknown branch',
        totalAmount: ((r['total_amount'] as num?) ?? 0).toDouble(),
        saleDate: dt,
        paymentMethod: (r['payment_method'] as String?) ?? '',
      ));
    }

    // ---- Sale items for those sales (profit + best sellers) ----------------
    final saleItems = <SaleItemRow>[];
    final ids = sales.map((s) => s.id).toList();
    if (ids.isNotEmpty) {
      // Chunked so very busy periods don't blow past URL limits.
      for (var i = 0; i < ids.length; i += 200) {
        final chunk = ids.sublist(i, (i + 200).clamp(0, ids.length));
        final rows = await _client
            .from('sale_items')
            .select('sale_id, item_id, quantity, subtotal, profit, items(name)')
            .inFilter('sale_id', chunk)
            .limit(10000) as List;
        for (final r in rows) {
          final item = r['items'];
          final sid = r['sale_id'] as String;
          saleItems.add(SaleItemRow(
            saleId: sid,
            branchId: saleBranch[sid] ?? '',
            itemId: (r['item_id'] as String?) ?? '',
            itemName: (item is Map ? item['name'] as String? : null) ?? 'Unknown item',
            quantity: ((r['quantity'] as num?) ?? 0).toDouble(),
            subtotal: ((r['subtotal'] as num?) ?? 0).toDouble(),
            profit: ((r['profit'] as num?) ?? 0).toDouble(),
          ));
        }
      }
    }

    // ---- Expenses in range (DATE column: compare date strings) -------------
    String d(DateTime x) =>
        '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    dynamic expQ = _client.from('expenses').select(
        'id, branch_id, category, amount, description, expense_date, branches(name)');
    if (branchId != null) expQ = expQ.eq('branch_id', branchId);
    final expRows = await expQ
        .gte('expense_date', d(period.start))
        .lt('expense_date', d(period.end))
        .order('expense_date', ascending: false)
        .limit(5000) as List;

    final expenses = expRows.map((r) {
      final br = r['branches'];
      final bId = r['branch_id'] as String;
      return ExpenseRow(
        id: r['id'] as String,
        branchId: bId,
        branchName: (br is Map ? br['name'] as String? : null) ?? names[bId] ?? 'Unknown branch',
        category: (r['category'] as String?)?.trim().isNotEmpty == true
            ? (r['category'] as String).trim()
            : 'Other',
        amount: ((r['amount'] as num?) ?? 0).toDouble(),
        description: (r['description'] as String?) ?? '',
        expenseDate: (r['expense_date'] as String?) ?? '',
      );
    }).toList();

    // ---- Expected profit sitting in current stock (no period) --------------
    final stockProfit = <String, double>{};
    try {
      final spRows = await _client.from('v_expected_profit_from_stock').select().limit(200) as List;
      for (final r in spRows) {
        final bId = r['branch_id'] as String?;
        if (bId == null) continue;
        if (branchId != null && bId != branchId) continue;
        stockProfit[bId] = ((r['potential_profit'] as num?) ?? 0).toDouble();
      }
    } catch (_) {
      // View missing/renamed — the rest of the report still works.
    }

    return PeriodBundle(sales: sales, saleItems: saleItems, expenses: expenses, stockProfitByBranch: stockProfit);
  }

  Future<({List<CustomerDebt> customers, List<SupplierDebt> suppliers})> fetchDebts(
      {String? branchId, required Map<String, String> branchNames}) async {
    dynamic cq = _client.from('v_customer_debts').select();
    if (branchId != null) cq = cq.eq('branch_id', branchId);
    final cRows = await cq.order('current_balance', ascending: false).limit(500) as List;
    final customers = cRows
        .map((r) {
          final bId = r['branch_id'] as String?;
          return CustomerDebt(
            customerId: (r['customer_id'] as String?) ?? '',
            name: (r['name'] as String?) ?? 'Unknown customer',
            branchId: bId ?? '',
            branchName: (bId != null ? branchNames[bId] : null) ?? 'Unknown branch',
            balance: ((r['current_balance'] as num?) ?? 0).toDouble(),
          );
        })
        .toList();

    final sRows = await _client.from('v_supplier_balances').select().limit(200) as List;
    final suppliers = sRows
        .map((r) => SupplierDebt(
              supplierId: (r['supplier_id'] as String?) ?? '',
              supplierName: (r['supplier_name'] as String?) ?? 'Unknown supplier',
              amountOwed: ((r['amount_owed'] as num?) ?? 0).toDouble(),
            ))
        .toList();
    return (customers: customers, suppliers: suppliers);
  }

  Future<List<DebtPayment>> fetchCustomerHistory(String customerId) async {
    final rows = await _client
        .from('v_customer_payment_history')
        .select()
        .eq('customer_id', customerId)
        .order('payment_date', ascending: false)
        .limit(200) as List;
    return rows
        .map((r) => DebtPayment(
              amount: ((r['amount'] as num?) ?? 0).toDouble(),
              method: (r['payment_method'] as String?) ?? '',
              date: (r['payment_date'] as String?) ?? '',
              note: null,
            ))
        .toList();
  }

  Future<List<DebtPayment>> fetchSupplierHistory(String supplierId) async {
    final rows = await _client
        .from('v_supplier_payment_history')
        .select()
        .eq('supplier_id', supplierId)
        .order('payment_date', ascending: false)
        .limit(200) as List;
    // Map purchase_id -> invoice number so rows explain themselves.
    final pids = rows.map((r) => r['purchase_id'] as String?).whereType<String>().toSet().toList();
    final invoices = <String, String>{};
    if (pids.isNotEmpty) {
      final prows =
          await _client.from('purchases').select('id, invoice_number').inFilter('id', pids).limit(500) as List;
      for (final p in prows) {
        invoices[p['id'] as String] = (p['invoice_number'] as String?) ?? '';
      }
    }
    return rows.map((r) {
      final pid = r['purchase_id'] as String?;
      final inv = pid == null ? null : invoices[pid];
      return DebtPayment(
        amount: ((r['amount'] as num?) ?? 0).toDouble(),
        method: (r['payment_method'] as String?) ?? '',
        date: (r['payment_date'] as String?) ?? '',
        note: inv != null && inv.isNotEmpty ? 'Invoice $inv' : null,
      );
    }).toList();
  }
}
