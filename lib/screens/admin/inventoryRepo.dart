import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================================================
// ADMIN INVENTORY — REPOSITORY (oversight, not data entry)
//   Reads: branches, items, inventory (+ embeds), v_low_stock,
//          stock_movements, purchases (+ suppliers), v_supplier_balances.
//   Writes (admin only): stock adjustments (always with a reason, logged to
//          stock_movements), batch price changes, item catalog edits.
//
//   Tables involved have no RLS except branches/items/inventory, which all
//   carry "admin sees everything" policies — so an admin client can run all
//   of these directly. If RLS is ever enabled on stock_movements / purchases
//   / suppliers, add the same is_admin() read policies.
// ============================================================================

class InventoryException implements Exception {
  final String message;
  const InventoryException(this.message);
  @override
  String toString() => message;
}

class InvBranch {
  final String id;
  final String name;
  const InvBranch({required this.id, required this.name});
}

class StockBatch {
  final String id;
  final String itemId;
  final String itemName;
  final String branchId;
  final String branchName;
  final String batchNumber;
  final double buyingPrice;
  final double retailPrice;
  final double? wholesalePrice;
  final double qtyReceived;
  final double qtyAvailable;
  final String? expiryDate; // YYYY-MM-DD or null
  final String? receivedDate;

  const StockBatch({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.branchId,
    required this.branchName,
    required this.batchNumber,
    required this.buyingPrice,
    required this.retailPrice,
    required this.wholesalePrice,
    required this.qtyReceived,
    required this.qtyAvailable,
    required this.expiryDate,
    required this.receivedDate,
  });

  int? get daysToExpiry {
    if (expiryDate == null) return null;
    try {
      final exp = DateTime.parse(expiryDate!);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      return exp.difference(today).inDays;
    } catch (_) {
      return null;
    }
  }

  bool get isExpired => (daysToExpiry ?? 1) < 0;
}

enum StockStatus { out, low, ok }

class ItemStock {
  final String itemId;
  final String itemName;
  final String category;
  final String unit;
  final double reorderLevel;
  final bool itemActive;
  final List<StockBatch> batches;

  const ItemStock({
    required this.itemId,
    required this.itemName,
    required this.category,
    required this.unit,
    required this.reorderLevel,
    required this.itemActive,
    required this.batches,
  });

  double get qtyOnHand => batches.fold(0, (s, b) => s + b.qtyAvailable);

  StockStatus get status {
    if (qtyOnHand <= 0) return StockStatus.out;
    if (qtyOnHand <= reorderLevel) return StockStatus.low;
    return StockStatus.ok;
  }

  double get stockValue => batches.fold(0, (s, b) => s + b.qtyAvailable * b.buyingPrice);

  double get potentialProfit =>
      batches.fold(0, (s, b) => s + b.qtyAvailable * (b.retailPrice - b.buyingPrice));

  /// "Where it is": branch name -> quantity, largest first.
  List<MapEntry<String, double>> get byBranch {
    final map = <String, double>{};
    for (final b in batches) {
      map[b.branchName] = (map[b.branchName] ?? 0) + b.qtyAvailable;
    }
    final entries = map.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return entries;
  }
}

class InventorySummary {
  final double stockValue;
  final double potentialProfit;
  final int lowCount;
  final int expiring90;
  final int expired;
  const InventorySummary({
    required this.stockValue,
    required this.potentialProfit,
    required this.lowCount,
    required this.expiring90,
    required this.expired,
  });

  static const empty = InventorySummary(
    stockValue: 0,
    potentialProfit: 0,
    lowCount: 0,
    expiring90: 0,
    expired: 0,
  );
}

class LowStockRow {
  final String itemName;
  final String branchName;
  final double qtyOnHand;
  final double reorderLevel;
  const LowStockRow({
    required this.itemName,
    required this.branchName,
    required this.qtyOnHand,
    required this.reorderLevel,
  });

  double get severity => reorderLevel <= 0 ? 0 : (qtyOnHand / reorderLevel).clamp(0.0, 1.0);
}

class StockMovement {
  final String id;
  final String branchName;
  final String itemName;
  final String type;
  final double quantity;
  final String? notes;
  final String createdAt;
  const StockMovement({
    required this.id,
    required this.branchName,
    required this.itemName,
    required this.type,
    required this.quantity,
    required this.notes,
    required this.createdAt,
  });
}

class PurchaseOrder {
  final String id;
  final String branchName;
  final String supplierName;
  final String invoiceNumber;
  final String paymentStatus;
  final double totalAmount;
  final double amountPaid;
  final String purchaseDate;
  final int lineCount;
  const PurchaseOrder({
    required this.id,
    required this.branchName,
    required this.supplierName,
    required this.invoiceNumber,
    required this.paymentStatus,
    required this.totalAmount,
    required this.amountPaid,
    required this.purchaseDate,
    required this.lineCount,
  });

  double get balance => totalAmount - amountPaid;
}

class SupplierBalance {
  final String supplierId;
  final String supplierName;
  final double amountOwed;
  const SupplierBalance({
    required this.supplierId,
    required this.supplierName,
    required this.amountOwed,
  });
}

class CatalogItem {
  final String id;
  final String name;
  final String category;
  final String unit;
  final double reorderLevel;
  final bool requiresPrescription;
  final bool isActive;
  const CatalogItem({
    required this.id,
    required this.name,
    required this.category,
    required this.unit,
    required this.reorderLevel,
    required this.requiresPrescription,
    required this.isActive,
  });
}

class InventoryRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<InvBranch>> fetchBranches() async {
    final rows = await _client
        .from('branches')
        .select('id, name')
        .eq('is_active', true)
        .order('name') as List;
    return rows.map((r) => InvBranch(id: r['id'] as String, name: r['name'] as String)).toList();
  }

  Future<List<String>> fetchCategories() async {
    final rows = await _client.from('items').select('category').limit(2000) as List;
    final cats = <String>{};
    for (final r in rows) {
      final c = (r['category'] as String?)?.trim();
      if (c != null && c.isNotEmpty) cats.add(c);
    }
    final sorted = cats.toList()..sort();
    return sorted;
  }

  /// All batches with stock on hand in scope, grouped per item.
  /// Search / category are applied client-side so the same fetch feeds
  /// the overview, low-stock, expiry and summary cards consistently.
  Future<List<ItemStock>> fetchOverview({String? branchId}) async {
    dynamic q = _client.from('inventory').select(
        'id, item_id, branch_id, batch_number, buying_price, retail_price, '
        'wholesale_price, quantity_received, quantity_available, expiry_date, '
        'received_date, items(id, name, category, unit, reorder_level, is_active), '
        'branches(name)');
    if (branchId != null) q = q.eq('branch_id', branchId);
    final rows = await q.gt('quantity_available', 0).limit(2000) as List;

    final batches = <StockBatch>[];
    for (final r in rows) {
      final item = r['items'];
      final br = r['branches'];
      final itemMap = item is Map ? item : null;
      batches.add(StockBatch(
        id: r['id'] as String,
        itemId: r['item_id'] as String,
        itemName: (itemMap?['name'] as String?) ?? 'Unknown item',
        branchId: r['branch_id'] as String,
        branchName: (br is Map ? br['name'] as String? : null) ?? 'Unknown branch',
        batchNumber: (r['batch_number'] as String?) ?? '—',
        buyingPrice: (r['buying_price'] as num).toDouble(),
        retailPrice: (r['retail_price'] as num).toDouble(),
        wholesalePrice: (r['wholesale_price'] as num?)?.toDouble(),
        qtyReceived: (r['quantity_received'] as num).toDouble(),
        qtyAvailable: (r['quantity_available'] as num).toDouble(),
        expiryDate: r['expiry_date'] as String?,
        receivedDate: r['received_date'] as String?,
      ));
    }

    final byItem = <String, List<StockBatch>>{};
    final meta = <String, Map>{};
    for (final b in batches) {
      byItem.putIfAbsent(b.itemId, () => []).add(b);
    }
    for (final r in rows) {
      final item = r['items'];
      if (item is Map && item['id'] != null) {
        meta.putIfAbsent(item['id'] as String, () => item);
      }
    }

    final items = <ItemStock>[];
    for (final entry in byItem.entries) {
      final m = meta[entry.key];
      items.add(ItemStock(
        itemId: entry.key,
        itemName: entry.value.first.itemName,
        category: (m?['category'] as String?)?.trim().isNotEmpty == true
            ? (m!['category'] as String).trim()
            : 'Uncategorised',
        unit: (m?['unit'] as String?) ?? 'unit',
        reorderLevel: ((m?['reorder_level'] as num?) ?? 10).toDouble(),
        itemActive: (m?['is_active'] as bool?) ?? true,
        batches: entry.value,
      ));
    }
    items.sort((a, b) => a.itemName.compareTo(b.itemName));
    return items;
  }

  InventorySummary summarize(List<ItemStock> items) {
    var value = 0.0;
    var profit = 0.0;
    var low = 0;
    var exp90 = 0;
    var expired = 0;
    for (final item in items) {
      value += item.stockValue;
      profit += item.potentialProfit;
      if (item.status == StockStatus.low || item.status == StockStatus.out) low++;
      for (final b in item.batches) {
        final d = b.daysToExpiry;
        if (d == null) continue;
        if (d < 0) {
          expired++;
        } else if (d <= 90) {
          exp90++;
        }
      }
    }
    return InventorySummary(
      stockValue: value,
      potentialProfit: profit,
      lowCount: low,
      expiring90: exp90,
      expired: expired,
    );
  }

  Future<List<LowStockRow>> fetchLowStock({String? branchId}) async {
    dynamic q = _client
        .from('v_low_stock')
        .select('branch_name, item_name, reorder_level, quantity_on_hand');
    if (branchId != null) q = q.eq('branch_id', branchId);
    final rows = await q.limit(500) as List;
    final list = rows
        .map((r) => LowStockRow(
              itemName: r['item_name'] as String,
              branchName: (r['branch_name'] as String?) ?? 'Unknown branch',
              qtyOnHand: (r['quantity_on_hand'] as num).toDouble(),
              reorderLevel: (r['reorder_level'] as num).toDouble(),
            ))
        .toList();
    // Worst first: lowest coverage ratio ahead.
    list.sort((a, b) => a.severity.compareTo(b.severity));
    return list;
  }

  Future<List<StockMovement>> fetchMovements({String? branchId, String? type, int limit = 150}) async {
    dynamic q = _client.from('stock_movements').select(
        'id, movement_type, quantity, notes, created_at, items(name), branches(name)');
    if (branchId != null) q = q.eq('branch_id', branchId);
    if (type != null) q = q.eq('movement_type', type);
    final rows = await q.order('created_at', ascending: false).limit(limit) as List;
    return rows.map((r) {
      final item = r['items'];
      final br = r['branches'];
      return StockMovement(
        id: r['id'] as String,
        branchName: (br is Map ? br['name'] as String? : null) ?? '—',
        itemName: (item is Map ? item['name'] as String? : null) ?? '—',
        type: (r['movement_type'] as String?) ?? '—',
        quantity: (r['quantity'] as num).toDouble(),
        notes: r['notes'] as String?,
        createdAt: (r['created_at'] as String?) ?? '',
      );
    }).toList();
  }

  Future<List<PurchaseOrder>> fetchPurchases({String? branchId}) async {
    dynamic q = _client.from('purchases').select(
        'id, invoice_number, payment_status, total_amount, amount_paid, '
        'purchase_date, suppliers(name), branches(name)');
    if (branchId != null) q = q.eq('branch_id', branchId);
    final rows = await q.order('purchase_date', ascending: false).limit(100) as List;

    // Line counts for the listed orders in one extra query.
    final ids = rows.map((r) => r['id'] as String).toList();
    final counts = <String, int>{};
    if (ids.isNotEmpty) {
      final lines = await _client
          .from('purchase_items')
          .select('purchase_id')
          .inFilter('purchase_id', ids)
          .limit(5000) as List;
      for (final l in lines) {
        final pid = l['purchase_id'] as String;
        counts[pid] = (counts[pid] ?? 0) + 1;
      }
    }

    return rows.map((r) {
      final sup = r['suppliers'];
      final br = r['branches'];
      final id = r['id'] as String;
      return PurchaseOrder(
        id: id,
        branchName: (br is Map ? br['name'] as String? : null) ?? '—',
        supplierName: (sup is Map ? sup['name'] as String? : null) ?? '—',
        invoiceNumber: (r['invoice_number'] as String?) ?? '—',
        paymentStatus: (r['payment_status'] as String?) ?? 'pending',
        totalAmount: ((r['total_amount'] as num?) ?? 0).toDouble(),
        amountPaid: ((r['amount_paid'] as num?) ?? 0).toDouble(),
        purchaseDate: (r['purchase_date'] as String?) ?? '',
        lineCount: counts[id] ?? 0,
      );
    }).toList();
  }

  Future<List<SupplierBalance>> fetchSupplierBalances() async {
    final rows = await _client.from('v_supplier_balances').select().limit(200) as List;
    return rows
        .map((r) => SupplierBalance(
              supplierId: (r['supplier_id'] as String?) ?? '',
              supplierName: (r['supplier_name'] as String?) ?? 'Unknown supplier',
              amountOwed: ((r['amount_owed'] as num?) ?? 0).toDouble(),
            ))
        .toList();
  }

  Future<List<CatalogItem>> fetchCatalog({bool includeInactive = true}) async {
    dynamic q = _client.from('items').select(
        'id, name, category, unit, reorder_level, requires_prescription, is_active');
    if (!includeInactive) q = q.eq('is_active', true);
    final rows = await q.order('name').limit(2000) as List;
    return rows
        .map((r) => CatalogItem(
              id: r['id'] as String,
              name: (r['name'] as String?) ?? '—',
              category: (r['category'] as String?)?.trim().isNotEmpty == true
                  ? (r['category'] as String).trim()
                  : 'Uncategorised',
              unit: (r['unit'] as String?) ?? 'unit',
              reorderLevel: ((r['reorder_level'] as num?) ?? 10).toDouble(),
              requiresPrescription: (r['requires_prescription'] as bool?) ?? false,
              isActive: (r['is_active'] as bool?) ?? true,
            ))
        .toList();
  }

  /// Admin stock adjustment. [deltaQty] is signed: negative removes stock
  /// (damage / loss / correction-out), positive adds it back. The [reason]
  /// is mandatory and is stored on the movement row as [notes].
  Future<void> adjustStock({
    required String inventoryId,
    required String branchId,
    required String itemId,
    required double deltaQty,
    required String reason,
  }) async {
    if (deltaQty == 0) throw const InventoryException('Quantity can\'t be zero.');
    if (reason.trim().isEmpty) throw const InventoryException('A reason is required.');

    final current = await _client
        .from('inventory')
        .select('quantity_available')
        .eq('id', inventoryId)
        .single();
    final onHand = (current['quantity_available'] as num).toDouble();
    final updated = onHand + deltaQty;
    if (updated < 0) {
      throw InventoryException(
          'Not enough stock: ${onHand.toStringAsFixed(0)} on hand, tried to remove ${(-deltaQty).toStringAsFixed(0)}.');
    }

    final uid = _client.auth.currentUser?.id;
    final type = deltaQty < 0 ? 'adjustment_out' : 'adjustment_in';

    await _client.from('inventory').update({'quantity_available': updated}).eq('id', inventoryId);
    try {
      await _client.from('stock_movements').insert({
        'branch_id': branchId,
        'item_id': itemId,
        'inventory_id': inventoryId,
        'movement_type': type,
        'quantity': deltaQty.abs(),
        'notes': reason.trim(),
        if (uid != null) 'performed_by': uid,
      });
    } catch (_) {
      // Stock was already updated — the movement log write failing must not
      // leave the two out of sync, so roll the quantity back and report.
      await _client.from('inventory').update({'quantity_available': onHand}).eq('id', inventoryId);
      throw const InventoryException('Couldn\'t record the movement. No stock was changed.');
    }
  }

  Future<void> updateBatchPrices({
    required String inventoryId,
    double? buyingPrice,
    double? retailPrice,
    double? wholesalePrice,
  }) async {
    final patch = <String, dynamic>{
      if (buyingPrice != null) 'buying_price': buyingPrice,
      if (retailPrice != null) 'retail_price': retailPrice,
      if (wholesalePrice != null) 'wholesale_price': wholesalePrice,
    };
    if (patch.isEmpty) throw const InventoryException('Nothing to update.');
    await _client.from('inventory').update(patch).eq('id', inventoryId);
  }

  Future<void> createItem({
    required String name,
    required String category,
    required String unit,
    required double reorderLevel,
    required bool requiresPrescription,
  }) async {
    if (name.trim().isEmpty) throw const InventoryException('Item name is required.');
    await _client.from('items').insert({
      'name': name.trim(),
      'category': category.trim().isEmpty ? null : category.trim(),
      'unit': unit.trim().isEmpty ? 'unit' : unit.trim(),
      'reorder_level': reorderLevel,
      'requires_prescription': requiresPrescription,
    });
  }

  Future<void> updateItem({
    required String id,
    required String name,
    required String category,
    required String unit,
    required double reorderLevel,
    required bool requiresPrescription,
  }) async {
    if (name.trim().isEmpty) throw const InventoryException('Item name is required.');
    await _client.from('items').update({
      'name': name.trim(),
      'category': category.trim().isEmpty ? null : category.trim(),
      'unit': unit.trim().isEmpty ? 'unit' : unit.trim(),
      'reorder_level': reorderLevel,
      'requires_prescription': requiresPrescription,
    }).eq('id', id);
  }

  Future<void> setItemActive(String id, bool active) async {
    await _client.from('items').update({'is_active': active}).eq('id', id);
  }
}
