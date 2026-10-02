import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================================================
// CASHIER STOCK — branch stock list + receive flow for staff with access.
//   Receiving goes through receive_stock_delivery() (one atomic call).
//   Access state comes from has_stock_access() + the cashier's own rows in
//   v_stock_access_requests. Buying prices are only ever typed into the
//   receive form — never shown on list rows.
// ============================================================================

// Bumped whenever branch stock changes elsewhere (receiving, adjustments)
// so the sale list refreshes its quantities.
final stockChanged = ValueNotifier<int>(0);

class StockException implements Exception {
  final String message;
  const StockException(this.message);
  @override
  String toString() => message;
}

class BranchStockRow {
  final String itemId;
  final String name;
  final String category;
  final String unit;
  final double qty;
  final double retail;
  final bool low;
  final bool expiring;
  const BranchStockRow({
    required this.itemId,
    required this.name,
    required this.category,
    required this.unit,
    required this.qty,
    required this.retail,
    required this.low,
    required this.expiring,
  });
}

class CatalogOption {
  final String id;
  final String name;
  const CatalogOption({required this.id, required this.name});
}

class SupplierOption {
  final String id;
  final String name;
  const SupplierOption({required this.id, required this.name});
}

enum OwnAccessState { none, pending, active }

class OwnAccess {
  final OwnAccessState state;
  final String? requestId;
  final DateTime? expiresAt;
  final DateTime? decidedAt;
  const OwnAccess({required this.state, this.requestId, this.expiresAt, this.decidedAt});
}

class ReceiveLine {
  final String itemId;
  final double quantity;
  final double buyingPrice;
  final double retailPrice;
  final double? wholesalePrice;
  final String? expiryDate; // YYYY-MM-DD
  final String? batchNumber;
  const ReceiveLine({
    required this.itemId,
    required this.quantity,
    required this.buyingPrice,
    required this.retailPrice,
    this.wholesalePrice,
    this.expiryDate,
    this.batchNumber,
  });

  Map<String, dynamic> toJson() => {
        'item_id': itemId,
        'quantity': quantity,
        'buying_price': buyingPrice,
        'retail_price': retailPrice,
        if (wholesalePrice != null) 'wholesale_price': wholesalePrice,
        if (expiryDate != null && expiryDate!.isNotEmpty) 'expiry_date': expiryDate,
        if (batchNumber != null && batchNumber!.trim().isNotEmpty) 'batch_number': batchNumber!.trim(),
      };
}

class CashierStockRepository {
  final SupabaseClient _client = Supabase.instance.client;

  String _todayStr() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  Future<List<BranchStockRow>> fetchStock({required String branchId, String query = ''}) async {
    dynamic q = _client.from('items').select('id, name, category, unit, reorder_level').eq('is_active', true);
    if (query.trim().isNotEmpty) q = q.ilike('name', '%${query.trim()}%');
    final items = await q.order('name').limit(200) as List;
    if (items.isEmpty) return [];
    final ids = items.map((r) => r['id'] as String).toList();
    final today = _todayStr();
    final stock = await _client
        .from('inventory')
        .select('item_id, quantity_available, retail_price, expiry_date')
        .eq('branch_id', branchId)
        .inFilter('item_id', ids)
        .gt('quantity_available', 0)
        .limit(2000) as List;

    final qtyBy = <String, double>{};
    final priceBy = <String, double>{};
    final expiring = <String>{};
    for (final r in stock) {
      final id = r['item_id'] as String;
      final qty = ((r['quantity_available'] as num?) ?? 0).toDouble();
      qtyBy[id] = (qtyBy[id] ?? 0) + qty;
      final retail = ((r['retail_price'] as num?) ?? 0).toDouble();
      if (!priceBy.containsKey(id) || retail < priceBy[id]!) priceBy[id] = retail;
      final exp = r['expiry_date'] as String?;
      if (exp != null && exp.compareTo(today) >= 0) {
        try {
          final d = DateTime.parse(exp);
          final now = DateTime.now();
          if (d.difference(DateTime(now.year, now.month, now.day)).inDays <= 90) {
            expiring.add(id);
          }
        } catch (_) {}
      }
    }
    final out = <BranchStockRow>[];
    for (final it in items) {
      final id = it['id'] as String;
      final qty = qtyBy[id] ?? 0;
      final reorder = ((it['reorder_level'] as num?) ?? 10).toDouble();
      out.add(BranchStockRow(
        itemId: id,
        name: (it['name'] as String?) ?? '—',
        category: (it['category'] as String?) ?? 'Uncategorised',
        unit: (it['unit'] as String?) ?? 'unit',
        qty: qty,
        retail: priceBy[id] ?? 0,
        low: qty <= reorder,
        expiring: expiring.contains(id),
      ));
    }
    return out;
  }

  Future<List<CatalogOption>> searchCatalog(String query) async {
    dynamic q = _client.from('items').select('id, name').eq('is_active', true);
    if (query.trim().isNotEmpty) q = q.ilike('name', '%${query.trim()}%');
    final rows = await q.order('name').limit(30) as List;
    return rows.map((r) => CatalogOption(id: r['id'] as String, name: (r['name'] as String?) ?? '—')).toList();
  }

  Future<List<SupplierOption>> fetchSuppliers() async {
    final rows = await _client.from('suppliers').select('id, name').eq('is_active', true).order('name').limit(200) as List;
    return rows.map((r) => SupplierOption(id: r['id'] as String, name: (r['name'] as String?) ?? '—')).toList();
  }

  Future<bool> hasAccess() async {
    try {
      final res = await _client.rpc('has_stock_access');
      return res as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<OwnAccess> myStatus() async {
    try {
      final rows = await _client.from('v_stock_access_requests').select('id, effective_status, expires_at, decided_at').limit(50) as List;
      for (final r in rows) {
        if ((r['effective_status'] as String?) == 'pending') {
          return const OwnAccess(state: OwnAccessState.pending);
        }
      }
      for (final r in rows) {
        if ((r['effective_status'] as String?) == 'approved') {
          DateTime? dt(Object? v) {
            if (v == null) return null;
            try {
              return DateTime.parse(v as String);
            } catch (_) {
              return null;
            }
          }

          return OwnAccess(
            state: OwnAccessState.active,
            requestId: r['id'] as String,
            expiresAt: dt(r['expires_at']),
            decidedAt: dt(r['decided_at']),
          );
        }
      }
      return const OwnAccess(state: OwnAccessState.none);
    } catch (_) {
      return const OwnAccess(state: OwnAccessState.none);
    }
  }

  Future<void> requestAccess(String reason) async {
    try {
      await _client.rpc('request_stock_access', params: {'p_reason': reason.trim().isEmpty ? null : reason.trim()});
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }

  Future<void> endOwnAccess(String requestId) async {
    try {
      await _client.rpc('revoke_stock_access', params: {'p_request_id': requestId});
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }

  Future<void> receive({
    required String branchId,
    String? supplierId,
    String? invoice,
    required List<ReceiveLine> lines,
  }) async {
    if (lines.isEmpty) throw const StockException('Add at least one delivery line.');
    try {
      await _client.rpc('receive_stock_delivery', params: {
        'p_branch_id': branchId,
        'p_supplier_id': ?supplierId,
        if (invoice != null && invoice.trim().isNotEmpty) 'p_invoice_number': invoice.trim(),
        'p_lines': [for (final l in lines) l.toJson()],
      });
    } on PostgrestException catch (e) {
      throw StockException(e.message);
    }
  }
}
