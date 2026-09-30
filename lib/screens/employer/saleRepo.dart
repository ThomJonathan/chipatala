import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================================================
// SALE — REPOSITORY
//   Search (sellable stock only), customers, create_sale / get_receipt RPCs,
//   today's sales list. Prices shown are selling prices; costs never leave
//   the server (create_sale records them from the batches it draws).
// ============================================================================

class SaleException implements Exception {
  final String message;
  const SaleException(this.message);
  @override
  String toString() => message;
}

class SaleItem {
  final String itemId;
  final String name;
  final String category;
  final String unit;
  final double retail;
  final double wholesale;
  final double available; // sellable units: on hand + unexpired
  const SaleItem({
    required this.itemId,
    required this.name,
    required this.category,
    required this.unit,
    required this.retail,
    required this.wholesale,
    required this.available,
  });

  bool get inStock => available > 0;
}

class SaleCustomer {
  final String id;
  final String name;
  final String phone;
  final double balance;
  const SaleCustomer({required this.id, required this.name, required this.phone, required this.balance});
}

class TodaySale {
  final String id;
  final String time;
  final String receipt;
  final double total;
  final String method;
  const TodaySale({
    required this.id,
    required this.time,
    required this.receipt,
    required this.total,
    required this.method,
  });
}

class SaleRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<String>> fetchCategories() async {
    final rows = await _client.from('items').select('category').eq('is_active', true).limit(2000) as List;
    final cats = <String>{};
    for (final r in rows) {
      final c = (r['category'] as String?)?.trim();
      if (c != null && c.isNotEmpty) cats.add(c);
    }
    return cats.toList()..sort();
  }

  Future<List<ReportBranchLite>> fetchBranches() async {
    final rows = await _client.from('branches').select('id, name').eq('is_active', true).order('name') as List;
    return rows.map((r) => ReportBranchLite(id: r['id'] as String, name: r['name'] as String)).toList();
  }

  /// Items with their sellable quantity at [branchId]. Expired batches and
  /// empty stock count as zero (greyed out, cannot be added).
  Future<List<SaleItem>> searchItems({required String branchId, String query = '', String? category}) async {
    dynamic q = _client.from('items').select('id, name, category, unit').eq('is_active', true);
    if (query.trim().isNotEmpty) q = q.ilike('name', '%${query.trim()}%');
    if (category != null) q = q.eq('category', category);
    final items = await q.order('name').limit(60) as List;
    if (items.isEmpty) return [];

    final ids = items.map((r) => r['id'] as String).toList();
    final today = _todayStr();
    final stock = await _client
        .from('inventory')
        .select('item_id, quantity_available, retail_price, wholesale_price, expiry_date')
        .eq('branch_id', branchId)
        .inFilter('item_id', ids)
        .gt('quantity_available', 0)
        .limit(2000) as List;

    // Group by item; sellable = unexpired. Display price = FEFO batch price.
    final byItem = <String, List<Map>>{};
    for (final r in stock) {
      byItem.putIfAbsent(r['item_id'] as String, () => []).add(r as Map);
    }
    int expRank(Map b) {
      final e = b['expiry_date'] as String?;
      if (e == null) return 1 << 30;
      return e.compareTo('');
    }

    final out = <SaleItem>[];
    for (final it in items) {
      final id = it['id'] as String;
      final batches = (byItem[id] ?? []).where((b) {
        final e = b['expiry_date'] as String?;
        return e == null || e.compareTo(today) >= 0;
      }).toList();
      batches.sort((a, b) => expRank(a).compareTo(expRank(b)));
      var avail = 0.0;
      for (final b in batches) {
        avail += ((b['quantity_available'] as num?) ?? 0).toDouble();
      }
      final first = batches.isNotEmpty ? batches.first : null;
      final retail = ((first?['retail_price'] as num?) ?? 0).toDouble();
      final wholesale = ((first?['wholesale_price'] as num?) ?? retail).toDouble();
      out.add(SaleItem(
        itemId: id,
        name: (it['name'] as String?) ?? '—',
        category: (it['category'] as String?) ?? 'Uncategorised',
        unit: (it['unit'] as String?) ?? 'unit',
        retail: retail,
        wholesale: wholesale,
        available: avail,
      ));
    }
    // In-stock first, then alphabetical.
    out.sort((a, b) {
      if (a.inStock != b.inStock) return a.inStock ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return out;
  }

  Future<List<SaleCustomer>> searchCustomers({required String branchId, String query = ''}) async {
    dynamic q = _client.from('customers').select('id, name, phone, current_balance').eq('branch_id', branchId);
    if (query.trim().isNotEmpty) q = q.ilike('name', '%${query.trim()}%');
    final rows = await q.order('name').limit(20) as List;
    return rows
        .map((r) => SaleCustomer(
              id: r['id'] as String,
              name: (r['name'] as String?) ?? '—',
              phone: (r['phone'] as String?) ?? '',
              balance: ((r['current_balance'] as num?) ?? 0).toDouble(),
            ))
        .toList();
  }

  Future<SaleCustomer> createCustomer({required String branchId, required String name, String phone = ''}) async {
    if (name.trim().isEmpty) throw const SaleException('Customer name is required.');
    final row = await _client.from('customers').insert({
      'branch_id': branchId,
      'name': name.trim(),
      'phone': phone.trim().isEmpty ? null : phone.trim(),
    }).select('id, name, phone, current_balance').single();
    return SaleCustomer(
      id: row['id'] as String,
      name: (row['name'] as String?) ?? '—',
      phone: (row['phone'] as String?) ?? '',
      balance: ((row['current_balance'] as num?) ?? 0).toDouble(),
    );
  }

  Future<List<TodaySale>> todaySales({required String branchId}) async {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final rows = await _client
        .from('sales')
        .select('id, sale_date, receipt_number, total_amount, payment_method')
        .eq('branch_id', branchId)
        .gte('sale_date', start.toIso8601String())
        .lt('sale_date', start.add(const Duration(days: 1)).toIso8601String())
        .order('sale_date', ascending: false)
        .limit(100) as List;
    return rows
        .map((r) => TodaySale(
              id: r['id'] as String,
              time: (r['sale_date'] as String?) ?? '',
              receipt: (r['receipt_number'] as String?) ?? '—',
              total: ((r['total_amount'] as num?) ?? 0).toDouble(),
              method: (r['payment_method'] as String?) ?? '',
            ))
        .toList();
  }

  /// Calls create_sale (schema.sql). The server resolves the branch from the
  /// signed-in user; p_branch_id is only used for admins. Server messages
  /// are already plain language, so they are shown as-is.
  Future<Map<String, dynamic>> createSale({
    required String branchId,
    required List<Map<String, dynamic>> lines, // [{item_id, quantity}]
    required String saleType, // retail | wholesale
    required String method, // cash | mobile_money | card | credit
    String? customerId,
    double? partPayment,
    String? partMethod,
  }) async {
    try {
      final res = await _client.rpc('create_sale', params: {
        'p_branch_id': branchId,
        'p_lines': lines,
        'p_sale_type': saleType,
        'p_payment_method': method,
        if (customerId != null) 'p_customer_id': customerId,
        if (partPayment != null && partPayment > 0) 'p_amount_paid': partPayment,
        if (partMethod != null) 'p_paid_method': partMethod,
      });
      return Map<String, dynamic>.from(res as Map);
    } on PostgrestException catch (e) {
      throw SaleException(_friendly(e.message));
    }
  }

  Future<Map<String, dynamic>> getReceipt(String saleId) async {
    try {
      final res = await _client.rpc('get_receipt', params: {'p_sale_id': saleId});
      return Map<String, dynamic>.from(res as Map);
    } on PostgrestException catch (e) {
      throw SaleException(_friendly(e.message));
    }
  }

  String _friendly(String server) {
    // schema.sql raises plain-language messages already
    // ('Not enough stock for AMLODIPINE: only 3 available.') — show as-is.
    final msg = server.trim();
    return msg.isEmpty ? 'Something went wrong. Please try again.' : msg;
  }

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
}

class ReportBranchLite {
  final String id;
  final String name;
  const ReportBranchLite({required this.id, required this.name});
}
