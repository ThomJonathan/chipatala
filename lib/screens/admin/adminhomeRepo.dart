import 'package:supabase_flutter/supabase_flutter.dart';

export 'adminManagementRepo.dart';

// ============================================================================
// ADMIN HOME — REPOSITORY
//   Pulls real data from Supabase for the admin dashboard:
//     - branches            -> for the filter dropdown
//     - sales               -> total sold today, filtered/grouped by branch
//     - sales (credit only) -> credit given today
//     - v_low_stock         -> "needs attention" (low stock)
//     - v_expiring_soon     -> "needs attention" (expiring batches)
//
//   Requires dashboard_rls_and_views.sql to have been run — it adds the RLS
//   policies these queries need, and adds branch_name directly onto
//   v_low_stock / v_expiring_soon so no client-side join is needed here.
//
//   No profit anywhere — deliberately left out (see admin_home_screen.dart).
// ============================================================================

class Branch {
  final String id;
  final String name;
  const Branch({required this.id, required this.name});
}

enum AttentionType { lowStock, expiring }

class AttentionItem {
  final AttentionType type;
  final String itemName;
  final String branchName;
  final String detail;
  const AttentionItem({
    required this.type,
    required this.itemName,
    required this.branchName,
    required this.detail,
  });
}

class BranchSalesSummary {
  final String branchId;
  final String branchName;
  final double salesToday;
  const BranchSalesSummary({
    required this.branchId,
    required this.branchName,
    required this.salesToday,
  });
}

class ExpenseRecord {
  final String id;
  final String branchId;
  final String branchName;
  final String category;
  final double amount;
  final String description;
  final String expenseDate; // YYYY-MM-DD
  const ExpenseRecord({
    required this.id,
    required this.branchId,
    required this.branchName,
    required this.category,
    required this.amount,
    required this.description,
    required this.expenseDate,
  });
}

class AdminHomeData {
  final double salesToday;
  final int salesTransactionsToday;
  final double creditToday;
  final int creditSalesToday;
  final List<BranchSalesSummary> branchSales;
  final List<AttentionItem> attentionItems;
  final double expensesToday;
  final int expensesCountToday;
  final List<ExpenseRecord> recentExpenses;

  const AdminHomeData({
    required this.salesToday,
    required this.salesTransactionsToday,
    required this.creditToday,
    required this.creditSalesToday,
    required this.branchSales,
    required this.attentionItems,
    required this.expensesToday,
    required this.expensesCountToday,
    required this.recentExpenses,
  });

  static const empty = AdminHomeData(
    salesToday: 0,
    salesTransactionsToday: 0,
    creditToday: 0,
    creditSalesToday: 0,
    branchSales: [],
    attentionItems: [],
    expensesToday: 0,
    expensesCountToday: 0,
    recentExpenses: [],
  );
}

class AdminHomeRepository {
  final SupabaseClient _client = Supabase.instance.client;

  /// Today's [start, end) as local-day timestamps, sent as ISO strings so
  /// Postgres compares sale_date (timestamptz) against real instants rather
  /// than relying on a `::date` cast we'd have to express through PostgREST.
  ({DateTime start, DateTime end}) _todayRange() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    return (start: start, end: start.add(const Duration(days: 1)));
  }

  Future<List<Branch>> fetchBranches() async {
    final rows = await _client
        .from('branches')
        .select('id, name')
        .eq('is_active', true)
        .order('name') as List;
    return rows
        .map((r) => Branch(id: r['id'] as String, name: r['name'] as String))
        .toList();
  }

  /// [branchId] null = all branches.
  Future<AdminHomeData> fetchAdminHomeData({String? branchId}) async {
    final range = _todayRange();
    final branches = await fetchBranches();
    final branchNames = {for (final b in branches) b.id: b.name};

    // ---- Sales today (every payment method) -------------------------------
    var salesQuery = _client
        .from('sales')
        .select('branch_id, total_amount')
        .gte('sale_date', range.start.toIso8601String())
        .lt('sale_date', range.end.toIso8601String());
    if (branchId != null) salesQuery = salesQuery.eq('branch_id', branchId);
    final salesRows = await salesQuery as List;

    double salesToday = 0;
    final Map<String, double> salesByBranch = {};
    for (final row in salesRows) {
      final amount = (row['total_amount'] as num).toDouble();
      salesToday += amount;
      final bId = row['branch_id'] as String;
      salesByBranch[bId] = (salesByBranch[bId] ?? 0) + amount;
    }

    final branchesInScope =
    branchId == null ? branches : branches.where((b) => b.id == branchId);
    final branchSales = branchesInScope
        .map((b) => BranchSalesSummary(
      branchId: b.id,
      branchName: b.name,
      salesToday: salesByBranch[b.id] ?? 0,
    ))
        .toList();

    // ---- Credit given today (payment_method = 'credit') --------------------
    var creditQuery = _client
        .from('sales')
        .select('total_amount')
        .eq('payment_method', 'credit')
        .gte('sale_date', range.start.toIso8601String())
        .lt('sale_date', range.end.toIso8601String());
    if (branchId != null) creditQuery = creditQuery.eq('branch_id', branchId);
    final creditRows = await creditQuery as List;

    double creditToday = 0;
    for (final row in creditRows) {
      creditToday += (row['total_amount'] as num).toDouble();
    }

    // ---- Expenses today ----------------------------------------------------
    final todayStr = _todayDateStr();
    var expTodayQuery = _client
        .from('expenses')
        .select('amount')
        .eq('expense_date', todayStr);
    if (branchId != null) expTodayQuery = expTodayQuery.eq('branch_id', branchId);
    final expTodayRows = await expTodayQuery as List;

    double expensesToday = 0;
    for (final row in expTodayRows) {
      expensesToday += (row['amount'] as num).toDouble();
    }

    // ---- Recent expenses (respects the same branch filter) -----------------
    dynamic recentBase = _client
        .from('expenses')
        .select('id, branch_id, category, amount, description, expense_date, created_at, branches(name)');
    if (branchId != null) recentBase = recentBase.eq('branch_id', branchId);
    final recentRows = await recentBase
        .order('expense_date', ascending: false)
        .order('created_at', ascending: false)
        .limit(30) as List;

    final recentExpenses = recentRows.map((row) {
      final embedded = row['branches'];
      final embeddedName =
      embedded is Map ? embedded['name'] as String? : null;
      final bId = row['branch_id'] as String;
      return ExpenseRecord(
        id: row['id'] as String,
        branchId: bId,
        branchName: embeddedName ?? branchNames[bId] ?? 'Unknown branch',
        category: (row['category'] as String?) ?? 'Other',
        amount: (row['amount'] as num).toDouble(),
        description: (row['description'] as String?) ?? '',
        expenseDate: (row['expense_date'] as String?) ?? todayStr,
      );
    }).toList();

    // ---- Low stock — branch_name now comes straight from the view --------
    var lowStockQuery = _client
        .from('v_low_stock')
        .select('branch_id, branch_name, item_name, reorder_level, quantity_on_hand');
    if (branchId != null) lowStockQuery = lowStockQuery.eq('branch_id', branchId);
    final lowStockRows = await lowStockQuery as List;

    // ---- Expiring within 90 days — same, branch_name from the view -------
    var expiringQuery = _client
        .from('v_expiring_soon')
        .select('branch_id, branch_name, item_name, expiry_date, days_to_expiry');
    if (branchId != null) expiringQuery = expiringQuery.eq('branch_id', branchId);
    final expiringRows = await expiringQuery as List;

    final attentionItems = <AttentionItem>[
      for (final row in lowStockRows)
        AttentionItem(
          type: AttentionType.lowStock,
          itemName: row['item_name'] as String,
          branchName: row['branch_name'] as String? ?? 'Unknown branch',
          detail:
          '${(row['quantity_on_hand'] as num).toStringAsFixed(0)} left · '
              'reorder at ${(row['reorder_level'] as num).toStringAsFixed(0)}',
        ),
      for (final row in expiringRows)
        AttentionItem(
          type: AttentionType.expiring,
          itemName: row['item_name'] as String,
          branchName: row['branch_name'] as String? ?? 'Unknown branch',
          detail: 'Expires in ${row['days_to_expiry']} days',
        ),
    ];

    // Low stock first, then expiring — keeps the more actionable ones (out
    // of stock right now) ahead of the ones with a runway.
    attentionItems.sort((a, b) {
      if (a.type != b.type) {
        return a.type == AttentionType.lowStock ? -1 : 1;
      }
      return 0;
    });

    return AdminHomeData(
      salesToday: salesToday,
      salesTransactionsToday: salesRows.length,
      creditToday: creditToday,
      creditSalesToday: creditRows.length,
      branchSales: branchSales,
      attentionItems: attentionItems,
      expensesToday: expensesToday,
      expensesCountToday: expTodayRows.length,
      recentExpenses: recentExpenses,
    );
  }

  String _todayDateStr() {
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    return '${now.year}-$mm-$dd';
  }
}
