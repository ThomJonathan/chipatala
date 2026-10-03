import 'package:supabase_flutter/supabase_flutter.dart';

class EmployeeReportException implements Exception {
  final String message;
  const EmployeeReportException(this.message);
}

/// Display label for a stored payment_method value. 'mobile_money' is the
/// legacy value from before the Airtel Money / TNM Mpamba split.
String paymentMethodLabel(String m) {
  switch (m) {
    case 'cash':
      return 'Cash';
    case 'airtel_money':
      return 'Airtel Money';
    case 'tnm_mpamba':
      return 'TNM Mpamba';
    case 'mobile_money':
      return 'Mobile money';
    case 'card':
      return 'Card';
    case 'credit':
      return 'Credit';
    default:
      return m.isEmpty ? '—' : m;
  }
}

class EmployeeReportPeriod {
  final DateTime start;
  final DateTime end;
  final String label;
  final bool singleDay;
  const EmployeeReportPeriod({
    required this.start,
    required this.end,
    required this.label,
    required this.singleDay,
  });
  factory EmployeeReportPeriod.today() {
    final n = DateTime.now();
    final s = DateTime(n.year, n.month, n.day);
    return EmployeeReportPeriod(
      start: s,
      end: s.add(const Duration(days: 1)),
      label: 'Today',
      singleDay: true,
    );
  }
  factory EmployeeReportPeriod.month() {
    final n = DateTime.now();
    final s = DateTime(n.year, n.month);
    return EmployeeReportPeriod(
      start: s,
      end: DateTime(n.year, n.month + 1),
      label: 'This month',
      singleDay: false,
    );
  }
  factory EmployeeReportPeriod.day(DateTime d) {
    final s = DateTime(d.year, d.month, d.day);
    return EmployeeReportPeriod(
      start: s,
      end: s.add(const Duration(days: 1)),
      label: '${s.day}/${s.month}/${s.year}',
      singleDay: true,
    );
  }
}

class EmployeeReportSale {
  final String id, time, receipt, cashier, method;
  final double total;
  const EmployeeReportSale({
    required this.id,
    required this.time,
    required this.receipt,
    required this.cashier,
    required this.total,
    required this.method,
  });
}

class EmployeeBestSeller {
  final String name;
  final double quantity;
  final int sales;
  const EmployeeBestSeller({
    required this.name,
    required this.quantity,
    required this.sales,
  });
}

class EmployeeDebt {
  final String id, name;
  final double balance;
  const EmployeeDebt({
    required this.id,
    required this.name,
    required this.balance,
  });
}

class EmployeePayment {
  final String date, method;
  final double amount;
  const EmployeePayment({
    required this.date,
    required this.method,
    required this.amount,
  });
}

class EmployeeReportData {
  final List<EmployeeReportSale> sales;
  final List<EmployeeBestSeller> sellers;
  final List<EmployeeDebt> debts;
  const EmployeeReportData({
    required this.sales,
    required this.sellers,
    required this.debts,
  });
  double get total => sales.fold(0, (s, x) => s + x.total);
}

class EmployeeReportsRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<EmployeeReportData> fetch({
    required String branchId,
    required EmployeeReportPeriod period,
  }) async {
    final salesRows =
        await _client
                .from('sales')
                .select(
                  'id, sale_date, receipt_number, total_amount, payment_method, cashier:users(full_name)',
                )
                .eq('branch_id', branchId)
                .gte('sale_date', period.start.toIso8601String())
                .lt('sale_date', period.end.toIso8601String())
                .order('sale_date', ascending: false)
                .limit(1000)
            as List;
    final ids = salesRows.map((r) => r['id'] as String).toList();
    final lineRows = ids.isEmpty
        ? <dynamic>[]
        : await _client
                  .from('sale_items')
                  .select('sale_id, quantity, items(name)')
                  .inFilter('sale_id', ids)
                  .limit(5000)
              as List;
    final quantities = <String, double>{};
    final saleCounts = <String, Set<String>>{};
    for (final raw in lineRows) {
      final item = raw['items'];
      final name = item is Map
          ? (item['name'] as String? ?? 'Unknown')
          : 'Unknown';
      quantities[name] =
          (quantities[name] ?? 0) + ((raw['quantity'] as num?) ?? 0).toDouble();
      saleCounts
          .putIfAbsent(name, () => <String>{})
          .add(raw['sale_id'] as String);
    }
    final sales = salesRows.map((r) {
      final cashier = r['cashier'];
      return EmployeeReportSale(
        id: r['id'] as String,
        time: r['sale_date'] as String? ?? '',
        receipt: r['receipt_number'] as String? ?? '—',
        cashier: cashier is Map
            ? (cashier['full_name'] as String? ?? '—')
            : '—',
        total: ((r['total_amount'] as num?) ?? 0).toDouble(),
        method: paymentMethodLabel((r['payment_method'] as String?) ?? ''),
      );
    }).toList();
    final sellers =
        quantities.keys
            .map(
              (name) => EmployeeBestSeller(
                name: name,
                quantity: quantities[name]!,
                sales: saleCounts[name]!.length,
              ),
            )
            .toList()
          ..sort((a, b) => b.quantity.compareTo(a.quantity));
    final debtRows =
        await _client
                .from('v_customer_debts')
                .select('customer_id, name, current_balance')
                .eq('branch_id', branchId)
                .gt('current_balance', 0)
                .order('current_balance', ascending: false)
                .limit(500)
            as List;
    final debts = debtRows
        .map(
          (r) => EmployeeDebt(
            id: r['customer_id'] as String,
            name: r['name'] as String? ?? 'Unknown',
            balance: ((r['current_balance'] as num?) ?? 0).toDouble(),
          ),
        )
        .toList();
    return EmployeeReportData(sales: sales, sellers: sellers, debts: debts);
  }

  Future<List<EmployeePayment>> payments(String customerId) async {
    final rows =
        await _client
                .from('payments')
                .select('payment_date, amount, payment_method')
                .eq('customer_id', customerId)
                .order('payment_date', ascending: false)
                .limit(100)
            as List;
    return rows
        .map(
          (r) => EmployeePayment(
            date: r['payment_date'] as String? ?? '',
            method: paymentMethodLabel((r['payment_method'] as String?) ?? ''),
            amount: ((r['amount'] as num?) ?? 0).toDouble(),
          ),
        )
        .toList();
  }

  Future<void> recordPayment({
    required String branchId,
    required String customerId,
    required double amount,
    required String method,
  }) async {
    if (amount <= 0) {
      throw const EmployeeReportException('Enter an amount above zero.');
    }
    try {
      await _client.from('payments').insert({
        'branch_id': branchId,
        'customer_id': customerId,
        'amount': amount,
        'payment_method': method,
        if (_client.auth.currentUser != null)
          'recorded_by': _client.auth.currentUser!.id,
      });
    } on PostgrestException catch (e) {
      throw EmployeeReportException(e.message);
    }
  }
}
