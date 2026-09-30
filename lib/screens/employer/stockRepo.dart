import 'package:supabase_flutter/supabase_flutter.dart';

class StockException implements Exception {
  final String message;
  const StockException(this.message);
  @override
  String toString() => message;
}

class StockItem {
  final String id;
  final String name;
  final String category;
  final String unit;
  final double reorderLevel;
  final bool prescription;
  final bool discontinued;
  final bool hasExpired;
  final double quantity;
  final String? nextExpiry;
  final double retailPrice;
  final double wholesalePrice;

  const StockItem({
    required this.id,
    required this.name,
    required this.category,
    required this.unit,
    required this.reorderLevel,
    required this.prescription,
    required this.discontinued,
    required this.hasExpired,
    required this.quantity,
    required this.nextExpiry,
    required this.retailPrice,
    required this.wholesalePrice,
  });

  bool get isOut => quantity <= 0;
  bool get isLow => !isOut && quantity <= reorderLevel;
  bool get isExpiringSoon {
    if (nextExpiry == null) return false;
    final d = DateTime.tryParse(nextExpiry!);
    if (d == null) return false;
    return !d.isBefore(DateTime.now()) && d.difference(DateTime.now()).inDays <= 90;
  }
  bool get isExpired => hasExpired;
}

class StockBatchDetail {
  final String batchNumber;
  final double quantity;
  final String? expiryDate;
  final double retailPrice;
  final double wholesalePrice;
  const StockBatchDetail({
    required this.batchNumber,
    required this.quantity,
    required this.expiryDate,
    required this.retailPrice,
    required this.wholesalePrice,
  });
}

class StockAccessState {
  final String status;
  final DateTime? requestedAt;
  final DateTime? decidedAt;
  final DateTime? expiresAt;
  final DateTime? revokedAt;
  final String? revokedByName;
  const StockAccessState({
    required this.status,
    required this.requestedAt,
    required this.decidedAt,
    required this.expiresAt,
    required this.revokedAt,
    required this.revokedByName,
  });

  bool get canReceive => status == 'approved';
}

class DeliveryLine {
  final String itemId;
  final String itemName;
  final String unit;
  final String quantity;
  final String buyingPrice;
  final String retailPrice;
  final String wholesalePrice;
  final String batchNumber;
  final DateTime? expiryDate;
  const DeliveryLine({
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.quantity,
    required this.buyingPrice,
    required this.retailPrice,
    required this.wholesalePrice,
    required this.batchNumber,
    required this.expiryDate,
  });

  double get total =>
      (double.tryParse(quantity) ?? 0) * (double.tryParse(buyingPrice) ?? 0);
}

class StockRepository {
  final SupabaseClient _client = Supabase.instance.client;

  DateTime? _date(Object? value) =>
      value == null ? null : DateTime.tryParse(value.toString());

  Future<StockAccessState?> fetchAccess() async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) return null;
    final rows = await _client
        .from('v_stock_access_requests')
        .select('effective_status, requested_at, decided_at, expires_at, revoked_at, revoked_by_name')
        .eq('user_id', uid)
        .order('requested_at', ascending: false)
        .limit(1) as List;
    if (rows.isEmpty) return null;
    final r = rows.first as Map;
    return StockAccessState(
      status: r['effective_status'] as String? ?? 'pending',
      requestedAt: _date(r['requested_at']),
      decidedAt: _date(r['decided_at']),
      expiresAt: _date(r['expires_at']),
      revokedAt: _date(r['revoked_at']),
      revokedByName: r['revoked_by_name'] as String?,
    );
  }

  Future<void> requestAccess(String reason) async {
    try {
      await _client.rpc('request_stock_access', params: {
        'p_reason': reason.trim().isEmpty ? null : reason.trim(),
      });
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }

  Future<void> endAccess() async {
    try {
      final uid = _client.auth.currentUser?.id;
      if (uid == null) throw const StockException('You are not signed in.');
      final row = await _client
          .from('v_stock_access_requests')
          .select('id')
          .eq('user_id', uid)
          .eq('effective_status', 'approved')
          .limit(1) as List;
      if (row.isEmpty) throw const StockException('Your stock access is no longer active.');
      await _client.rpc('revoke_stock_access', params: {'p_request_id': row.first['id']});
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }

  Future<List<String>> fetchCategories() async {
    final rows = await _client.from('items').select('category').eq('is_active', true).limit(2000) as List;
    final result = <String>{};
    for (final row in rows) {
      final value = (row['category'] as String?)?.trim();
      if (value != null && value.isNotEmpty) result.add(value);
    }
    return result.toList()..sort();
  }

  Future<List<StockItem>> fetchItems({required String branchId}) async {
    final items = await _client
        .from('items')
        .select('id, name, category, unit, reorder_level, requires_prescription, is_active')
        .order('name')
        .limit(2000) as List;
    final view = await _client.from('v_sellable_stock').select().eq('branch_id', branchId).limit(2000) as List;
    final expiredRows = await _client
        .from('inventory')
        .select('item_id')
        .eq('branch_id', branchId)
        .gt('quantity_available', 0)
        .lt('expiry_date', DateTime.now().toIso8601String().substring(0, 10))
        .limit(2000) as List;
    final expiredIds = {for (final row in expiredRows) row['item_id'] as String};
    final byId = <String, Map>{};
    for (final row in view) {
      byId[row['item_id'] as String] = row as Map;
    }
    return items.map((raw) {
      final r = raw as Map;
      final v = byId[r['id'] as String];
      return StockItem(
        id: r['id'] as String,
        name: r['name'] as String,
        category: (r['category'] as String?)?.trim().isNotEmpty == true ? (r['category'] as String).trim() : 'Uncategorised',
        unit: r['unit'] as String? ?? 'unit',
        reorderLevel: ((r['reorder_level'] as num?) ?? 0).toDouble(),
        prescription: r['requires_prescription'] as bool? ?? false,
        discontinued: (r['is_active'] as bool?) != true,
        hasExpired: expiredIds.contains(r['id'] as String),
        quantity: ((v?['sellable_quantity'] as num?) ?? 0).toDouble(),
        nextExpiry: v?['next_expiry_date'] as String?,
        retailPrice: ((v?['retail_price'] as num?) ?? 0).toDouble(),
        wholesalePrice: ((v?['wholesale_price'] as num?) ?? 0).toDouble(),
      );
    }).toList();
  }

  Future<List<StockBatchDetail>> fetchBatches({required String branchId, required String itemId}) async {
    final rows = await _client
        .from('inventory')
        .select('batch_number, quantity_available, expiry_date, retail_price, wholesale_price')
        .eq('branch_id', branchId)
        .eq('item_id', itemId)
        .order('expiry_date', ascending: true, nullsFirst: false)
        .limit(100) as List;
    return rows.map((r) => StockBatchDetail(
      batchNumber: r['batch_number'] as String? ?? '—',
      quantity: ((r['quantity_available'] as num?) ?? 0).toDouble(),
      expiryDate: r['expiry_date'] as String?,
      retailPrice: ((r['retail_price'] as num?) ?? 0).toDouble(),
      wholesalePrice: ((r['wholesale_price'] as num?) ?? 0).toDouble(),
    )).toList();
  }

  Future<List<Map<String, String>>> fetchSuppliers() async {
    final rows = await _client.from('suppliers').select('id, name').eq('is_active', true).order('name').limit(500) as List;
    return rows.map((r) => {'id': r['id'] as String, 'name': r['name'] as String}).toList();
  }

  Future<void> receive({
    required String branchId,
    String? supplierId,
    required String invoiceNumber,
    required DateTime purchaseDate,
    required List<DeliveryLine> lines,
  }) async {
    if (lines.isEmpty) throw const StockException('Add at least one item.');
    try {
      await _client.rpc('receive_stock_delivery', params: {
        'p_branch_id': branchId,
        'p_supplier_id': supplierId,
        'p_invoice_number': invoiceNumber.trim().isEmpty ? null : invoiceNumber.trim(),
        'p_purchase_date': purchaseDate.toIso8601String().substring(0, 10),
        'p_lines': lines.map((line) => {
          'item_id': line.itemId,
          'quantity': line.quantity,
          'buying_price': line.buyingPrice,
          'retail_price': line.retailPrice,
          'wholesale_price': line.wholesalePrice,
          'batch_number': line.batchNumber,
          'expiry_date': line.expiryDate?.toIso8601String().substring(0, 10),
        }).toList(),
      });
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }
}
