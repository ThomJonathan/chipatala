import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';

import '../../core/downloads.dart';
import '../../widgets/adminShell.dart';
import 'adminui.dart';
import 'inventoryRepo.dart';
import 'stockAccessRepo.dart';

final inventoryAttentionRequest = ValueNotifier<bool>(false);

// ============================================================================
// ADMIN INVENTORY — oversight and decisions, not data entry.
//   Embedded page inside AdminShell (nav bars stay visible — this screen only
//   ever opens sheets/dialogs, it never pushes a route).
//
//   Filter bar (branch, search, category) scopes everything: the summary
//   cards, all six tabs and every export. Tabs:
//     0 Stock overview · 1 Low stock · 2 Expiry · 3 Movements ·
//     4 Purchases · 5 Item catalog (the only place the admin edits data).
//
//   Desktop: sidebar stays, cards in one row, tabs as chips, full tables,
//   batches expand inline. Mobile: search + Filters button, swipeable cards,
//   chips row, stacked cards, actions in bottom sheets.
// ============================================================================

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});

  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

const _kTabs = [
  'Overview',
  'Low stock',
  'Expiry',
  'Movements',
  'Purchases',
  'Catalog',
];
const _kMovementTypes = [
  'purchase_in',
  'sale_out',
  'adjustment_in',
  'adjustment_out',
  'opening_stock',
];

String _fmtMk(double amount) {
  final neg = amount < 0;
  final s = amount.abs().round().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '${neg ? '-' : ''}$buf';
}

String _fmtQty(double q) =>
    q.toStringAsFixed(q.truncateToDouble() == q ? 0 : 2);

String _fmtDate(String? raw) {
  if (raw == null || raw.isEmpty) return '—';
  try {
    final d = DateTime.parse(raw);
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
  } catch (_) {
    return raw;
  }
}

String _fmtDateTime(String raw) {
  if (raw.isEmpty) return '—';
  try {
    final d = DateTime.parse(raw).toLocal();
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day} ${m[d.month - 1]}, $hh:$mm';
  } catch (_) {
    return raw;
  }
}

String _csvCell(String v) {
  if (v.contains(',') || v.contains('"') || v.contains('\n')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

class _MovementMeta {
  final String label;
  final IconData icon;
  final Color color;
  final bool isOut;
  const _MovementMeta(this.label, this.icon, this.color, this.isOut);
}

_MovementMeta _movementMeta(String type) {
  switch (type) {
    case 'purchase_in':
      return const _MovementMeta(
        'Purchase',
        Icons.shopping_cart_outlined,
        kSuccess,
        false,
      );
    case 'sale_out':
      return const _MovementMeta(
        'Sale',
        Icons.point_of_sale_outlined,
        kPrimary,
        true,
      );
    case 'adjustment_out':
      return const _MovementMeta(
        'Adjustment out',
        Icons.remove_circle_outline,
        kDanger,
        true,
      );
    case 'adjustment_in':
      return const _MovementMeta(
        'Adjustment in',
        Icons.add_circle_outline,
        kSuccess,
        false,
      );
    case 'opening_stock':
      return const _MovementMeta(
        'Opening',
        Icons.inventory_2_outlined,
        kInkMuted,
        false,
      );
    default:
      return _MovementMeta(type, Icons.swap_horiz_outlined, kInkMuted, false);
  }
}

class _InventoryScreenState extends State<InventoryScreen> {
  final _repo = InventoryRepository();
  final _searchCtrl = TextEditingController();

  List<InvBranch> _branches = [];
  List<String> _categories = [];
  String? _branchId; // null = all branches
  String _search = '';
  String? _category; // null = all categories
  bool _showInactive = false;
  String? _movementType; // null = all types
  int _tab = 0;

  // Stock-access "View activity" deep-link: movements filtered to one
  // cashier + the window their access was active. Removable via chip.
  String? _activityUserId;
  String? _activityUserName;
  DateTime? _activityFrom;
  DateTime? _activityTo;
  bool _wasInventorySelected = false;
  bool _showNeedsAttention = false;
  int _attentionFilter = 0; // 0 all, 1 low stock, 2 expiring

  bool _loading = true;
  String? _error;

  List<ItemStock> _items = [];
  List<LowStockRow> _low = [];
  List<StockMovement> _movements = [];
  List<PurchaseOrder> _purchases = [];
  List<SupplierBalance> _balances = [];
  List<CatalogItem> _catalog = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Pick up a "View activity" jump from the Stock access section: show
    // Movements scoped to that cashier + window (branch filter cleared so
    // the link always lands on results).
    final selected = AdminShellScope.of(context)?.selectedIndex == 1;
    if (selected && !_wasInventorySelected) {
      if (inventoryAttentionRequest.value) {
        inventoryAttentionRequest.value = false;
        setState(() {
          _showNeedsAttention = true;
          _attentionFilter = 0;
        });
      }
      final f = stockActivityFilter.value;
      if (f != null) {
        stockActivityFilter.value = null;
        setState(() {
          _tab = 3;
          _movementType = null;
          _branchId = null;
          _activityUserId = f.userId;
          _activityUserName = f.userName;
          _activityFrom = f.from;
          _activityTo = f.to;
        });
        _load();
      }
    }
    _wasInventorySelected = selected;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _repo.fetchBranches(),
        _repo.fetchCategories(),
        _repo.fetchOverview(branchId: _branchId),
        _repo.fetchLowStock(branchId: _branchId),
        _repo.fetchMovements(
          branchId: _branchId,
          limit: 150,
          performedBy: _activityUserId,
          from: _activityFrom,
          to: _activityTo,
        ),
        _repo.fetchPurchases(branchId: _branchId),
        _repo.fetchSupplierBalances(),
        _repo.fetchCatalog(includeInactive: true),
      ]);
      if (!mounted) return;
      setState(() {
        _branches = results[0] as List<InvBranch>;
        _categories = results[1] as List<String>;
        _items = results[2] as List<ItemStock>;
        _low = results[3] as List<LowStockRow>;
        _movements = results[4] as List<StockMovement>;
        _purchases = results[5] as List<PurchaseOrder>;
        _balances = results[6] as List<SupplierBalance>;
        _catalog = results[7] as List<CatalogItem>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Branch зміни → server refetch; search/category/type stay client-side.
  Future<void> _onBranchChanged(String? id) async {
    if (id == _branchId) return;
    setState(() => _branchId = id);
    await _load();
  }

  // ---- Client-side filtering (search + category) ---------------------------

  List<ItemStock> get _visibleItems {
    final q = _search.trim().toLowerCase();
    return _items.where((it) {
      if (_category != null && it.category != _category) return false;
      if (q.isEmpty) return true;
      if (it.itemName.toLowerCase().contains(q)) return true;
      return it.batches.any(
        (b) =>
            b.batchNumber.toLowerCase().contains(q) ||
            b.branchName.toLowerCase().contains(q),
      );
    }).toList();
  }

  List<CatalogItem> get _visibleCatalog {
    final q = _search.trim().toLowerCase();
    return _catalog.where((c) {
      if (!_showInactive && !c.isActive) return false;
      if (_category != null && c.category != _category) return false;
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q);
    }).toList();
  }

  List<StockMovement> get _visibleMovements {
    final q = _search.trim().toLowerCase();
    return _movements.where((m) {
      if (_movementType != null && m.type != _movementType) return false;
      if (q.isEmpty) return true;
      return m.itemName.toLowerCase().contains(q) ||
          m.branchName.toLowerCase().contains(q) ||
          (m.notes ?? '').toLowerCase().contains(q);
    }).toList();
  }

  List<PurchaseOrder> get _visiblePurchases {
    final q = _search.trim().toLowerCase();
    if (q.isEmpty) return _purchases;
    return _purchases.where((p) {
      return p.supplierName.toLowerCase().contains(q) ||
          p.branchName.toLowerCase().contains(q) ||
          p.invoiceNumber.toLowerCase().contains(q);
    }).toList();
  }

  /// Expiry buckets derived from the visible items: expired / <30 / 30-60 / 60-90.
  List<List<StockBatch>> _expiryBuckets() {
    final expired = <StockBatch>[];
    final u30 = <StockBatch>[];
    final u60 = <StockBatch>[];
    final u90 = <StockBatch>[];
    for (final it in _visibleItems) {
      for (final b in it.batches) {
        final d = b.daysToExpiry;
        if (d == null) continue;
        if (d < 0) {
          expired.add(b);
        } else if (d < 30) {
          u30.add(b);
        } else if (d <= 60) {
          u60.add(b);
        } else if (d <= 90) {
          u90.add(b);
        }
      }
    }
    int byDate(StockBatch a, StockBatch b) =>
        (a.expiryDate ?? '').compareTo(b.expiryDate ?? '');
    expired.sort(byDate);
    u30.sort(byDate);
    u60.sort(byDate);
    u90.sort(byDate);
    return [expired, u30, u60, u90];
  }

  InventorySummary get _summary => _repo.summarize(_visibleItems);

  String get _scopeName {
    if (_branchId == null) return 'All branches';
    return _branches.where((b) => b.id == _branchId).map((b) => b.name).join();
  }

  // ---- Actions ---------------------------------------------------------------

  Future<void> _adjust(StockBatch b) async {
    final done = await showAdaptiveSheet<bool>(
      context,
      builder: (_) => _AdjustSheet(repo: _repo, batch: b),
    );
    if (done == true && mounted) {
      await _load();
      if (mounted) showToast(context, 'Stock adjusted.');
    }
  }

  Future<void> _editPrices(StockBatch b) async {
    final done = await showAdaptiveSheet<bool>(
      context,
      builder: (_) => _PriceSheet(repo: _repo, batch: b),
    );
    if (done == true && mounted) {
      await _load();
      if (mounted) showToast(context, 'Prices updated.');
    }
  }

  Future<void> _addStock() async {
    final done = await showAdaptiveSheet<bool>(
      context,
      builder: (_) => _AddStockSheet(
        repo: _repo,
        branches: _branches,
        items: _catalog.where((item) => item.isActive).toList(),
      ),
    );
    if (done == true && mounted) {
      await _load();
      if (mounted) showToast(context, 'Stock added and available for sale.');
    }
  }

  Future<void> _addOrEditItem([CatalogItem? item]) async {
    final msg = await showAdaptiveSheet<String>(
      context,
      builder: (_) =>
          _ItemFormSheet(repo: _repo, item: item, categories: _categories),
    );
    if (msg == null) return;
    await _load();
    if (mounted) showToast(context, msg);
  }

  Future<void> _toggleItemActive(CatalogItem item) async {
    if (item.isActive) {
      final ok = await showConfirm(
        context,
        title: 'Discontinue ${item.name}?',
        message: 'It stays in history and existing batches, but can\'t be ordered or sold going forward.',
        confirmLabel: 'Discontinue',
      );
      if (!ok) return;
    }
    try {
      await _repo.setItemActive(item.id, !item.isActive);
      await _load();
      if (mounted) {
        showToast(
          context,
          item.isActive
              ? '${item.name} discontinued.'
              : '${item.name} is active again.',
        );
      }
    } on InventoryException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  void _jumpToTab(int tab) => setState(() => _tab = tab);

  // ---- CSV export: downloads a .csv file onto the user's device ------------

  bool _exporting = false;

  String _exportFileName(String tab) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'chipatala_${tab}_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
  }

  Future<void> _exportCurrentTab() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final scope = _scopeName;
      late String tab;
      late String csv;
      switch (_tab) {
        case 0:
          tab = 'stock_overview';
          final buf = StringBuffer(
            'Item,Category,Unit,Branches,Qty on hand,Reorder level,Status,Stock value (MK)\n',
          );
          for (final it in _visibleItems) {
            final where = it.byBranch
                .map((e) => '${e.key} (${_fmtQty(e.value)})')
                .join('; ');
            buf.writeln(
              [
                _csvCell(it.itemName),
                _csvCell(it.category),
                _csvCell(it.unit),
                _csvCell(where),
                _fmtQty(it.qtyOnHand),
                _fmtQty(it.reorderLevel),
                it.status.name,
                it.stockValue.round(),
              ].join(','),
            );
          }
          csv = buf.toString();
        case 1:
          tab = 'low_stock';
          final buf = StringBuffer('Item,Branch,Qty on hand,Reorder level\n');
          for (final r in _low) {
            buf.writeln(
              [
                _csvCell(r.itemName),
                _csvCell(r.branchName),
                _fmtQty(r.qtyOnHand),
                _fmtQty(r.reorderLevel),
              ].join(','),
            );
          }
          csv = buf.toString();
        case 2:
          tab = 'expiry';
          final buf = StringBuffer(
            'Item,Batch,Branch,Expiry date,Days to expiry,Qty,Value at risk (MK)\n',
          );
          for (final bucket in _expiryBuckets()) {
            for (final b in bucket) {
              buf.writeln(
                [
                  _csvCell(b.itemName),
                  _csvCell(b.batchNumber),
                  _csvCell(b.branchName),
                  b.expiryDate ?? '',
                  b.daysToExpiry ?? '',
                  _fmtQty(b.qtyAvailable),
                  (b.qtyAvailable * b.buyingPrice).round(),
                ].join(','),
              );
            }
          }
          csv = buf.toString();
        case 3:
          tab = 'stock_movements';
          final buf = StringBuffer('Date,Type,Item,Branch,Quantity,Notes\n');
          for (final m in _visibleMovements) {
            buf.writeln(
              [
                _csvCell(m.createdAt),
                m.type,
                _csvCell(m.itemName),
                _csvCell(m.branchName),
                _fmtQty(m.quantity),
                _csvCell(m.notes ?? ''),
              ].join(','),
            );
          }
          csv = buf.toString();
        case 4:
          tab = 'purchases';
          final buf = StringBuffer(
            'Date,Invoice,Branch,Supplier,Total (MK),Paid (MK),Balance (MK),Status\n',
          );
          for (final p in _visiblePurchases) {
            buf.writeln(
              [
                p.purchaseDate,
                _csvCell(p.invoiceNumber),
                _csvCell(p.branchName),
                _csvCell(p.supplierName),
                p.totalAmount.round(),
                p.amountPaid.round(),
                p.balance.round(),
                p.paymentStatus,
              ].join(','),
            );
          }
          csv = buf.toString();
        default:
          tab = 'item_catalog';
          final buf = StringBuffer(
            'Name,Category,Unit,Reorder level,Rx,Active\n',
          );
          for (final c in _visibleCatalog) {
            buf.writeln(
              [
                _csvCell(c.name),
                _csvCell(c.category),
                _csvCell(c.unit),
                _fmtQty(c.reorderLevel),
                c.requiresPrescription ? 'yes' : 'no',
                c.isActive ? 'yes' : 'no',
              ].join(','),
            );
          }
          csv = buf.toString();
      }
      final rows = csv.trim().split('\n').length - 1;
      final path = await saveDownload(
        name: _exportFileName(tab),
        bytes: Uint8List.fromList(utf8.encode(csv)),
        extension: 'csv',
        mimeType: MimeType.csv,
      );
      if (mounted) showToast(context, '$rows rows ($scope) saved to $path');
    } catch (e) {
      if (mounted) showToast(context, 'Export failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ---- Build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      body: SafeArea(
        child: RefreshIndicator(
          color: kPrimary,
          onRefresh: _load,
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= kWideContentBreakpoint;
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  wide ? 32 : 18,
                  wide ? 28 : 12,
                  wide ? 32 : 18,
                  96,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_showNeedsAttention)
                          _attentionTitle()
                        else
                          PageTitle(
                            title: 'Inventory',
                            subtitle: _loading
                                ? 'Loading…'
                                : '${_visibleItems.length} items · $_scopeName',
                            trailing: _exporting
                                ? const SizedBox(
                                    width: 44,
                                    height: 44,
                                    child: Center(
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: kPrimary,
                                        ),
                                      ),
                                    ),
                                  )
                                : OutlinedButton.icon(
                                    onPressed: _loading
                                        ? null
                                        : _exportCurrentTab,
                                    style: outlineButtonStyle(height: 44),
                                    icon: const Icon(
                                      Icons.download_outlined,
                                      size: 18,
                                    ),
                                    label: const Text('Export'),
                                  ),
                          ),
                        const SizedBox(height: 18),
                        if (_showNeedsAttention)
                          _attentionBody(wide)
                        else ...[
                          _filterBar(wide),
                          const SizedBox(height: 16),
                          _body(wide),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _attentionTitle() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          onPressed: () => setState(() => _showNeedsAttention = false),
          tooltip: 'Back to inventory',
          icon: const Icon(Icons.arrow_back, color: kInk),
          padding: EdgeInsets.zero,
          alignment: Alignment.topLeft,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: PageTitle(
            title: 'Needs attention',
            subtitle:
                '${_low.length + _expiryBuckets().fold(0, (s, b) => s + b.length)} items requiring action',
          ),
        ),
      ],
    );
  }

  Widget _attentionBody(bool wide) {
    final buckets = _expiryBuckets();
    final expiryCount = buckets.fold(0, (s, b) => s + b.length);
    final showLow = _attentionFilter == 0 || _attentionFilter == 1;
    final showExpiry = _attentionFilter == 0 || _attentionFilter == 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              FilterPill(
                label: 'All (${_low.length + expiryCount})',
                selected: _attentionFilter == 0,
                onTap: () => setState(() => _attentionFilter = 0),
              ),
              const SizedBox(width: 8),
              FilterPill(
                label: 'Low stock (${_low.length})',
                selected: _attentionFilter == 1,
                onTap: () => setState(() => _attentionFilter = 1),
              ),
              const SizedBox(width: 8),
              FilterPill(
                label: 'Expiring ($expiryCount)',
                selected: _attentionFilter == 2,
                onTap: () => setState(() => _attentionFilter = 2),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (showLow) ...[
          Text(
            'Low stock',
            style: sans(16, weight: FontWeight.w700, color: kInk),
          ),
          const SizedBox(height: 10),
          _LowStockTab(rows: _low, wide: wide),
          const SizedBox(height: 20),
        ],
        if (showExpiry) ...[
          Text(
            'Expiring and expired',
            style: sans(16, weight: FontWeight.w700, color: kInk),
          ),
          const SizedBox(height: 10),
          _ExpiryTab(buckets: buckets, wide: wide, onAdjust: _adjust),
        ],
        if ((!showLow || _low.isEmpty) && (!showExpiry || expiryCount == 0))
          const EmptyState(
            icon: Icons.check_circle_outline,
            title: 'Nothing needs attention',
            message: 'Stock levels and expiry dates are currently healthy.',
          ),
      ],
    );
  }

  Widget _filterBar(bool wide) {
    final branchDropdown = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _branchId,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 18,
            color: kInkMuted,
          ),
          style: sans(13.5, weight: FontWeight.w500, color: kInk),
          hint: Text(
            'All Branches',
            style: sans(13.5, weight: FontWeight.w500, color: kInk),
          ),
          onChanged: _onBranchChanged,
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All Branches'),
            ),
            ..._branches.map(
              (b) =>
                  DropdownMenuItem<String?>(value: b.id, child: Text(b.name)),
            ),
          ],
        ),
      ),
    );
    final categoryDropdown = Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _category,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 18,
            color: kInkMuted,
          ),
          style: sans(13.5, weight: FontWeight.w500, color: kInk),
          hint: Text(
            'All Categories',
            style: sans(13.5, weight: FontWeight.w500, color: kInk),
          ),
          onChanged: (v) => setState(() => _category = v),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All Categories'),
            ),
            ..._categories.map(
              (c) => DropdownMenuItem<String?>(value: c, child: Text(c)),
            ),
          ],
        ),
      ),
    );

    if (wide) {
      return Row(
        children: [
          branchDropdown,
          const SizedBox(width: 10),
          Expanded(
            child: SearchField(
              hint: 'Search item, batch or branch…',
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          const SizedBox(width: 10),
          categoryDropdown,
        ],
      );
    }
    // Mobile: search + Filters button; branch/category live in a sheet.
    final activeFilters =
        (_branchId != null ? 1 : 0) + (_category != null ? 1 : 0);
    return Row(
      children: [
        Expanded(
          child: SearchField(
            hint: 'Search stock…',
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: () async {
            final res = await showAdaptiveSheet<_FilterResult>(
              context,
              builder: (_) => _FiltersSheet(
                branches: _branches,
                categories: _categories,
                branchId: _branchId,
                category: _category,
              ),
            );
            if (res != null && mounted) {
              setState(() {
                _branchId = res.branchId;
                _category = res.category;
              });
              if (res.branchChanged) await _load();
            }
          },
          style: outlineButtonStyle(height: 46),
          icon: Badge(
            isLabelVisible: activeFilters > 0,
            label: Text('$activeFilters'),
            child: const Icon(Icons.tune_outlined, size: 18),
          ),
          label: const Text('Filters'),
        ),
      ],
    );
  }

  Widget _body(bool wide) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: Center(child: CircularProgressIndicator(color: kPrimary)),
      );
    }
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.icon(
                onPressed: _loading ? null : _addStock,
                style: primaryButtonStyle(height: 42),
                icon: const Icon(Icons.add_box_outlined, size: 18),
                label: const Text('Add stock'),
              ),
              OutlinedButton.icon(
                onPressed: _loading ? null : () => _addOrEditItem(),
                style: outlineButtonStyle(height: 42),
                icon: const Icon(Icons.playlist_add_outlined, size: 18),
                label: const Text('Add catalog item'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _summaryCards(wide),
        const SizedBox(height: 16),
        _tabChips(),
        const SizedBox(height: 14),
        _tabContent(wide),
      ],
    );
  }

  Widget _summaryCards(bool wide) {
    final s = _summary;
    final cards = [
      _SummaryCard(
        label: 'Stock value',
        value: 'MK ${_fmtMk(s.stockValue)}',
        sub: 'at buying price',
        icon: Icons.inventory_2_outlined,
        onTap: null,
      ),
      _SummaryCard(
        label: 'Low stock',
        value: '${s.lowCount}',
        sub: s.lowCount == 1 ? 'item needs reorder' : 'items need reorder',
        icon: Icons.warning_amber_rounded,
        alert: s.lowCount > 0,
        onTap: () => _jumpToTab(1),
      ),
      _SummaryCard(
        label: 'Expiring ≤ 90d',
        value: '${s.expiring90}',
        sub: 'batches at risk',
        icon: Icons.schedule_outlined,
        alert: s.expiring90 > 0,
        onTap: () => _jumpToTab(2),
      ),
      _SummaryCard(
        label: 'Expired',
        value: '${s.expired}',
        sub: s.expired > 0 ? 'needs write-off' : 'nothing expired',
        icon: Icons.dangerous_outlined,
        alert: s.expired > 0,
        danger: s.expired > 0,
        onTap: () => _jumpToTab(2),
      ),
    ];
    if (wide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < cards.length; i++) ...[
            Expanded(child: cards[i]),
            if (i != cards.length - 1) const SizedBox(width: 12),
          ],
        ],
      );
    }
    return SizedBox(
      height: 118,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) => SizedBox(width: 168, child: cards[i]),
      ),
    );
  }

  Widget _tabChips() {
    final buckets = _expiryBuckets();
    final expiryCount = buckets.fold(0, (s, b) => s + b.length);
    final labels = [
      'Overview',
      'Low stock (${_low.length})',
      'Expiry ($expiryCount)',
      'Movements',
      'Purchases (${_purchases.length})',
      'Catalog (${_catalog.where((c) => c.isActive).length})',
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < _kTabs.length; i++) ...[
            FilterPill(
              label: labels[i],
              selected: _tab == i,
              onTap: () => setState(() => _tab = i),
            ),
            if (i != _kTabs.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _tabContent(bool wide) {
    switch (_tab) {
      case 0:
        return _OverviewTab(
          items: _visibleItems,
          wide: wide,
          showBranch: _branchId == null,
          onAdjust: _adjust,
          onEditPrices: _editPrices,
        );
      case 1:
        return _LowStockTab(rows: _low, wide: wide);
      case 2:
        return _ExpiryTab(
          buckets: _expiryBuckets(),
          wide: wide,
          onAdjust: _adjust,
        );
      case 3:
        return _MovementsTab(
          movements: _visibleMovements,
          wide: wide,
          selectedType: _movementType,
          onTypeChanged: (t) => setState(() => _movementType = t),
          activityLabel: _activityUserId == null
              ? null
              : 'Activity: ${_activityUserName ?? 'cashier'} · ${_fmtDate(_activityFrom?.toIso8601String())} – ${_fmtDate(_activityTo?.toIso8601String())}',
          onClearActivity: _activityUserId == null
              ? null
              : () {
                  setState(() {
                    _activityUserId = null;
                    _activityUserName = null;
                    _activityFrom = null;
                    _activityTo = null;
                  });
                  _load();
                },
        );
      case 4:
        return _PurchasesTab(
          purchases: _visiblePurchases,
          balances: _balances,
          wide: wide,
        );
      default:
        return _CatalogTab(
          items: _visibleCatalog,
          wide: wide,
          showInactive: _showInactive,
          onToggleInactive: (v) => setState(() => _showInactive = v),
          onAdd: () => _addOrEditItem(),
          onEdit: _addOrEditItem,
          onToggleActive: _toggleItemActive,
        );
    }
  }
}

// ============================================================================
// SUMMARY CARD
// ============================================================================

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final bool alert;
  final bool danger;
  final VoidCallback? onTap;
  const _SummaryCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    this.alert = false,
    this.danger = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = danger ? kDanger : (alert ? kWarn : kPrimary);
    final iconBg = danger ? kDangerTint : (alert ? kWarnTint : kPrimaryTint);
    final card = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: iconColor),
              ),
              const Spacer(),
              if (onTap != null)
                const Icon(Icons.chevron_right, size: 16, color: kInkMuted),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: mono(17, weight: FontWeight.w700, color: kInk),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: sans(11.5, weight: FontWeight.w600, color: kInkMuted),
          ),
          Text(sub, style: sans(10.5, color: kInkMuted)),
        ],
      ),
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: card,
      ),
    );
  }
}

// ============================================================================
// TAB 0 — STOCK OVERVIEW (expandable batches)
// ============================================================================

class _OverviewTab extends StatelessWidget {
  final List<ItemStock> items;
  final bool wide;
  final bool showBranch;
  final ValueChanged<StockBatch> onAdjust;
  final ValueChanged<StockBatch> onEditPrices;
  const _OverviewTab({
    required this.items,
    required this.wide,
    required this.showBranch,
    required this.onAdjust,
    required this.onEditPrices,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const EmptyState(
        icon: Icons.inventory_2_outlined,
        title: 'No stock found',
        message: 'Try a different branch, category or search.',
      );
    }
    return Column(
      children: [
        if (wide) _overviewHeader(),
        if (wide) const SizedBox(height: 8),
        for (final it in items) ...[
          _OverviewRow(
            item: it,
            wide: wide,
            showBranch: showBranch,
            onAdjust: onAdjust,
            onEditPrices: onEditPrices,
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _overviewHeader() {
    const style = TextStyle(
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
      color: kInkMuted,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: const [
          Expanded(flex: 3, child: Text('ITEM', style: style)),
          Expanded(flex: 1, child: Text('ON HAND', style: style)),
          Expanded(flex: 1, child: Text('REORDER', style: style)),
          Expanded(flex: 1, child: Text('STATUS', style: style)),
          Expanded(
            flex: 1,
            child: Text('VALUE', style: style, textAlign: TextAlign.right),
          ),
          SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _OverviewRow extends StatelessWidget {
  final ItemStock item;
  final bool wide;
  final bool showBranch;
  final ValueChanged<StockBatch> onAdjust;
  final ValueChanged<StockBatch> onEditPrices;
  const _OverviewRow({
    required this.item,
    required this.wide,
    required this.showBranch,
    required this.onAdjust,
    required this.onEditPrices,
  });

  @override
  Widget build(BuildContext context) {
    final where = item.byBranch
        .take(2)
        .map((e) => '${e.key} (${_fmtQty(e.value)})')
        .join(' · ');
    final extra = item.byBranch.length > 2
        ? ' +${item.byBranch.length - 2} more'
        : '';
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        childrenPadding: EdgeInsets.zero,
        shape: const Border(),
        title: wide
            ? Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.itemName,
                          style: sans(
                            13.5,
                            weight: FontWeight.w600,
                            color: kInk,
                          ),
                        ),
                        Text(
                          '${item.category} · ${item.unit}${showBranch ? ' · $where$extra' : ''}',
                          style: sans(11.5, color: kInkMuted),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    flex: 1,
                    child: Text(
                      _fmtQty(item.qtyOnHand),
                      style: mono(13.5, weight: FontWeight.w600, color: kInk),
                    ),
                  ),
                  Expanded(
                    flex: 1,
                    child: Text(
                      _fmtQty(item.reorderLevel),
                      style: sans(13, color: kInkMuted),
                    ),
                  ),
                  Expanded(flex: 1, child: _StatusChip(status: item.status)),
                  Expanded(
                    flex: 1,
                    child: Text(
                      'MK ${_fmtMk(item.stockValue)}',
                      style: mono(12.5, weight: FontWeight.w600, color: kInk),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.itemName,
                          style: sans(
                            13.5,
                            weight: FontWeight.w600,
                            color: kInk,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_fmtQty(item.qtyOnHand)} ${item.unit} · $where$extra',
                          style: sans(11.5, color: kInkMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _StatusChip(status: item.status),
                ],
              ),
        children: [
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: kBorder)),
            ),
            child: Column(
              children: [
                for (int i = 0; i < item.batches.length; i++)
                  _BatchRow(
                    batch: item.batches[i],
                    unit: item.unit,
                    last: i == item.batches.length - 1,
                    onAdjust: onAdjust,
                    onEditPrices: onEditPrices,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final StockStatus status;
  const _StatusChip({required this.status});
  @override
  Widget build(BuildContext context) {
    switch (status) {
      case StockStatus.out:
        return const StatusPill(label: 'Out', bg: kDangerTint, fg: kDanger);
      case StockStatus.low:
        return const StatusPill(label: 'Low', bg: kWarnTint, fg: kWarn);
      case StockStatus.ok:
        return const StatusPill(label: 'OK', bg: kSuccessTint, fg: kSuccess);
    }
  }
}

class _BatchRow extends StatelessWidget {
  final StockBatch batch;
  final String unit;
  final bool last;
  final ValueChanged<StockBatch> onAdjust;
  final ValueChanged<StockBatch> onEditPrices;
  const _BatchRow({
    required this.batch,
    required this.unit,
    required this.last,
    required this.onAdjust,
    required this.onEditPrices,
  });

  @override
  Widget build(BuildContext context) {
    final d = batch.daysToExpiry;
    final expiryLabel = batch.expiryDate == null
        ? 'No expiry'
        : d == null
        ? _fmtDate(batch.expiryDate)
        : d < 0
        ? 'Expired ${_fmtDate(batch.expiryDate)}'
        : 'Exp $d d · ${_fmtDate(batch.expiryDate)}';
    final expiryColor = batch.isExpired
        ? kDanger
        : (d != null && d <= 30 ? kWarn : kInkMuted);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: kBg,
        border: last ? null : const Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Batch ${batch.batchNumber} · ${batch.branchName}',
                  style: sans(12.5, weight: FontWeight.w600, color: kInk),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fmtQty(batch.qtyAvailable)} $unit · Buy MK ${_fmtMk(batch.buyingPrice)} · Sell MK ${_fmtMk(batch.retailPrice)}',
                  style: sans(11.5, color: kInkMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  expiryLabel,
                  style: sans(
                    11.5,
                    weight: FontWeight.w600,
                    color: expiryColor,
                  ),
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 18, color: kInkMuted),
            color: Colors.white,
            onSelected: (v) {
              if (v == 'adjust') {
                onAdjust(batch);
              } else {
                onEditPrices(batch);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'adjust', child: Text('Adjust stock')),
              PopupMenuItem(value: 'prices', child: Text('Change prices')),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// TAB 1 — LOW STOCK (worst first)
// ============================================================================

class _LowStockTab extends StatelessWidget {
  final List<LowStockRow> rows;
  final bool wide;
  const _LowStockTab({required this.rows, required this.wide});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const EmptyState(
        icon: Icons.check_circle_outline,
        title: 'Stock levels are healthy',
        message: 'Nothing is at or below its reorder level for this filter.',
      );
    }
    return Column(
      children: [
        for (final r in rows) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.itemName,
                            style: sans(
                              13.5,
                              weight: FontWeight.w600,
                              color: kInk,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(r.branchName, style: sans(12, color: kInkMuted)),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${_fmtQty(r.qtyOnHand)} / ${_fmtQty(r.reorderLevel)}',
                          style: mono(
                            13,
                            weight: FontWeight.w700,
                            color: kWarn,
                          ),
                        ),
                        Text(
                          'on hand / reorder',
                          style: sans(10.5, color: kInkMuted),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: r.severity,
                    minHeight: 5,
                    backgroundColor: kWarnTint,
                    valueColor: const AlwaysStoppedAnimation<Color>(kWarn),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

// ============================================================================
// TAB 2 — EXPIRY (grouped by urgency)
// ============================================================================

class _ExpiryTab extends StatelessWidget {
  final List<List<StockBatch>> buckets;
  final bool wide;
  final ValueChanged<StockBatch> onAdjust;
  const _ExpiryTab({
    required this.buckets,
    required this.wide,
    required this.onAdjust,
  });

  @override
  Widget build(BuildContext context) {
    const titles = [
      'Already expired',
      'Under 30 days',
      '30 to 60 days',
      '60 to 90 days',
    ];
    const subs = [
      'Write off or remove from sale.',
      'Discount or push first.',
      'Plan to move soon.',
      'Watch list.',
    ];
    final total = buckets.fold(0, (s, b) => s + b.length);
    if (total == 0) {
      return const EmptyState(
        icon: Icons.check_circle_outline,
        title: 'No batches expiring soon',
        message: 'Nothing in scope expires within the next 90 days.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (int i = 0; i < buckets.length; i++)
          if (buckets[i].isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${titles[i]} (${buckets[i].length})',
                        style: sans(
                          13,
                          weight: FontWeight.w700,
                          color: i == 0 ? kDanger : kInk,
                        ),
                      ),
                      Text(subs[i], style: sans(11.5, color: kInkMuted)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final b in buckets[i]) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: kBorder),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            b.itemName,
                            style: sans(
                              13.5,
                              weight: FontWeight.w600,
                              color: kInk,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Batch ${b.batchNumber} · ${b.branchName} · ${_fmtDate(b.expiryDate)} '
                            '(${b.daysToExpiry! < 0 ? '${-b.daysToExpiry!}d overdue' : '${b.daysToExpiry!}d left'})',
                            style: sans(11.5, color: kInkMuted),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_fmtQty(b.qtyAvailable)} on hand · MK ${_fmtMk(b.qtyAvailable * b.buyingPrice)} at risk',
                            style: sans(
                              11.5,
                              weight: FontWeight.w600,
                              color: i == 0 ? kDanger : kWarn,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => onAdjust(b),
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        'Write off',
                        style: sans(
                          12.5,
                          weight: FontWeight.w600,
                          color: kPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 12),
          ],
      ],
    );
  }
}

// ============================================================================
// TAB 3 — STOCK MOVEMENTS (audit trail)
// ============================================================================

class _MovementsTab extends StatelessWidget {
  final List<StockMovement> movements;
  final bool wide;
  final String? selectedType;
  final ValueChanged<String?> onTypeChanged;
  final String? activityLabel;
  final VoidCallback? onClearActivity;
  const _MovementsTab({
    required this.movements,
    required this.wide,
    required this.selectedType,
    required this.onTypeChanged,
    this.activityLabel,
    this.onClearActivity,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (activityLabel != null) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: kPrimaryTint,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.person_search_outlined,
                  size: 17,
                  color: kPrimary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    activityLabel!,
                    style: sans(12.5, weight: FontWeight.w600, color: kPrimary),
                  ),
                ),
                InkWell(
                  onTap: onClearActivity,
                  borderRadius: BorderRadius.circular(14),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 16, color: kPrimary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              FilterPill(
                label: 'All types',
                selected: selectedType == null,
                onTap: () => onTypeChanged(null),
              ),
              const SizedBox(width: 8),
              for (final t in _kMovementTypes) ...[
                FilterPill(
                  label: _movementMeta(t).label,
                  selected: selectedType == t,
                  onTap: () => onTypeChanged(selectedType == t ? null : t),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (movements.isEmpty)
          const EmptyState(
            icon: Icons.history_outlined,
            title: 'No movements found',
            message: 'Try a different type, branch or search.',
          )
        else
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: List.generate(movements.length, (i) {
                final m = movements[i];
                final meta = _movementMeta(m.type);
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    border: i == movements.length - 1
                        ? null
                        : const Border(bottom: BorderSide(color: kBorder)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: meta.color.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(meta.icon, size: 17, color: meta.color),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.itemName,
                              style: sans(
                                13,
                                weight: FontWeight.w600,
                                color: kInk,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${m.branchName} · ${meta.label} · ${_fmtDateTime(m.createdAt)}${m.performedByName != null && m.performedByName!.trim().isNotEmpty ? ' · by ${m.performedByName!.trim()}' : ''}',
                              style: sans(11.5, color: kInkMuted),
                            ),
                            if ((m.notes ?? '').trim().isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                '“${m.notes!.trim()}”',
                                style: sans(
                                  11.5,
                                  color: kInkMuted,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '${meta.isOut ? '−' : '+'}${_fmtQty(m.quantity)}',
                        style: mono(
                          13,
                          weight: FontWeight.w700,
                          color: meta.color,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ),
          ),
      ],
    );
  }
}

// ============================================================================
// TAB 4 — PURCHASES + SUPPLIER BALANCES
// ============================================================================

class _PurchasesTab extends StatelessWidget {
  final List<PurchaseOrder> purchases;
  final List<SupplierBalance> balances;
  final bool wide;
  const _PurchasesTab({
    required this.purchases,
    required this.balances,
    required this.wide,
  });

  @override
  Widget build(BuildContext context) {
    final totalOwed = balances.fold(0.0, (s, b) => s + b.amountOwed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: kBorder),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Owed to suppliers',
                style: sans(12.5, weight: FontWeight.w600, color: kInkMuted),
              ),
              const SizedBox(height: 4),
              Text(
                'MK ${_fmtMk(totalOwed)}',
                style: mono(
                  21,
                  weight: FontWeight.w700,
                  color: totalOwed > 0 ? kDanger : kInk,
                ),
              ),
              if (balances.isNotEmpty) ...[
                const SizedBox(height: 10),
                for (final b in balances)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            b.supplierName,
                            style: sans(13, color: kInk),
                          ),
                        ),
                        Text(
                          'MK ${_fmtMk(b.amountOwed)}',
                          style: mono(
                            13,
                            weight: FontWeight.w600,
                            color: kDanger,
                          ),
                        ),
                      ],
                    ),
                  ),
              ] else ...[
                const SizedBox(height: 4),
                Text(
                  'Nothing owed right now.',
                  style: sans(12.5, color: kInkMuted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Stock orders (${purchases.length})',
          style: sans(13, weight: FontWeight.w600, color: kInkMuted),
        ),
        const SizedBox(height: 8),
        if (purchases.isEmpty)
          const EmptyState(
            icon: Icons.shopping_cart_outlined,
            title: 'No purchase orders',
            message: 'Orders recorded at branches will appear here.',
          )
        else
          for (final p in purchases) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: kBorder),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          p.invoiceNumber == '—'
                              ? p.supplierName
                              : '${p.supplierName} · ${p.invoiceNumber}',
                          style: sans(
                            13.5,
                            weight: FontWeight.w600,
                            color: kInk,
                          ),
                        ),
                      ),
                      _PaymentPill(status: p.paymentStatus),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${p.branchName} · ${_fmtDate(p.purchaseDate)} · ${p.lineCount} ${p.lineCount == 1 ? 'line' : 'lines'}',
                    style: sans(12, color: kInkMuted),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        'MK ${_fmtMk(p.totalAmount)}',
                        style: mono(14, weight: FontWeight.w700, color: kInk),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'paid MK ${_fmtMk(p.amountPaid)}',
                        style: sans(12, color: kInkMuted),
                      ),
                      const Spacer(),
                      if (p.balance > 0)
                        Text(
                          'owes MK ${_fmtMk(p.balance)}',
                          style: sans(
                            12,
                            weight: FontWeight.w700,
                            color: kDanger,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _PaymentPill extends StatelessWidget {
  final String status;
  const _PaymentPill({required this.status});
  @override
  Widget build(BuildContext context) {
    switch (status) {
      case 'paid':
        return const StatusPill(label: 'Paid', bg: kSuccessTint, fg: kSuccess);
      case 'partial':
        return const StatusPill(label: 'Partial', bg: kWarnTint, fg: kWarn);
      default:
        return const StatusPill(label: 'Pending', bg: kDangerTint, fg: kDanger);
    }
  }
}

// ============================================================================
// TAB 5 — ITEM CATALOG (the one place the admin edits data)
// ============================================================================

class _CatalogTab extends StatelessWidget {
  final List<CatalogItem> items;
  final bool wide;
  final bool showInactive;
  final ValueChanged<bool> onToggleInactive;
  final VoidCallback onAdd;
  final ValueChanged<CatalogItem> onEdit;
  final ValueChanged<CatalogItem> onToggleActive;
  const _CatalogTab({
    required this.items,
    required this.wide,
    required this.showInactive,
    required this.onToggleInactive,
    required this.onAdd,
    required this.onEdit,
    required this.onToggleActive,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Products (${items.length})',
                style: sans(13, weight: FontWeight.w600, color: kInkMuted),
              ),
            ),
            FilterPill(
              label: showInactive ? 'Hiding discontinued' : 'Show discontinued',
              selected: showInactive,
              onTap: () => onToggleInactive(!showInactive),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: onAdd,
              style: primaryButtonStyle(height: 40),
              icon: const Icon(Icons.add, size: 17),
              label: const Text('Add item'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (items.isEmpty)
          EmptyState(
            icon: Icons.category_outlined,
            title: 'No products found',
            message: 'Try a different search or category.',
            action: FilledButton.icon(
              onPressed: onAdd,
              style: primaryButtonStyle(height: 42),
              icon: const Icon(Icons.add, size: 17),
              label: const Text('Add item'),
            ),
          )
        else
          for (final c in items) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: kBorder),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                c.name,
                                style: sans(
                                  13.5,
                                  weight: FontWeight.w600,
                                  color: c.isActive ? kInk : kInkMuted,
                                ),
                              ),
                            ),
                            if (c.requiresPrescription) ...[
                              const SizedBox(width: 6),
                              const StatusPill(
                                label: 'Rx',
                                bg: kPrimaryTint,
                                fg: kPrimary,
                              ),
                            ],
                            if (!c.isActive) ...[
                              const SizedBox(width: 6),
                              const StatusPill(
                                label: 'Stopped',
                                bg: kSurface,
                                fg: kInkMuted,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${c.category} · ${c.unit} · reorder at ${_fmtQty(c.reorderLevel)}',
                          style: sans(11.5, color: kInkMuted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.edit_outlined,
                      size: 18,
                      color: kInkMuted,
                    ),
                    tooltip: 'Edit',
                    onPressed: () => onEdit(c),
                  ),
                  Switch(
                    value: c.isActive,
                    activeThumbColor: kPrimary,
                    onChanged: (_) => onToggleActive(c),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

// ============================================================================
// FILTERS SHEET (mobile)
// ============================================================================

class _FilterResult {
  final String? branchId;
  final String? category;
  final bool branchChanged;
  const _FilterResult({
    required this.branchId,
    required this.category,
    required this.branchChanged,
  });
}

class _FiltersSheet extends StatefulWidget {
  final List<InvBranch> branches;
  final List<String> categories;
  final String? branchId;
  final String? category;
  const _FiltersSheet({
    required this.branches,
    required this.categories,
    required this.branchId,
    required this.category,
  });

  @override
  State<_FiltersSheet> createState() => _FiltersSheetState();
}

class _FiltersSheetState extends State<_FiltersSheet> {
  late String? _branchId = widget.branchId;
  late String? _category = widget.category;

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: 'Filters',
      subtitle: 'Scope the whole inventory section.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Branch',
            style: sans(13, weight: FontWeight.w600, color: kInkMuted),
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              children: [
                RadioListTile<String?>(
                  value: null,
                  groupValue: _branchId,
                  onChanged: (v) => setState(() => _branchId = v),
                  title: Text('All Branches', style: sans(13.5, color: kInk)),
                  activeColor: kPrimary,
                  dense: true,
                ),
                for (final b in widget.branches)
                  RadioListTile<String?>(
                    value: b.id,
                    groupValue: _branchId,
                    onChanged: (v) => setState(() => _branchId = v),
                    title: Text(b.name, style: sans(13.5, color: kInk)),
                    activeColor: kPrimary,
                    dense: true,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Category',
            style: sans(13, weight: FontWeight.w600, color: kInkMuted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterPill(
                label: 'All',
                selected: _category == null,
                onTap: () => setState(() => _category = null),
              ),
              for (final c in widget.categories)
                FilterPill(
                  label: c,
                  selected: _category == c,
                  onTap: () =>
                      setState(() => _category = _category == c ? null : c),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _branchId = null;
                    _category = null;
                  }),
                  style: outlineButtonStyle(),
                  child: const Text('Clear'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    _FilterResult(
                      branchId: _branchId,
                      category: _category,
                      branchChanged: _branchId != widget.branchId,
                    ),
                  ),
                  style: primaryButtonStyle(),
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ADD STOCK SHEET — creates one sellable batch for a selected branch
// ============================================================================

class _AddStockSheet extends StatefulWidget {
  final InventoryRepository repo;
  final List<InvBranch> branches;
  final List<CatalogItem> items;

  const _AddStockSheet({
    required this.repo,
    required this.branches,
    required this.items,
  });

  @override
  State<_AddStockSheet> createState() => _AddStockSheetState();
}

class _AddStockSheetState extends State<_AddStockSheet> {
  final _quantityCtrl = TextEditingController();
  final _buyingCtrl = TextEditingController();
  final _retailCtrl = TextEditingController();
  final _wholesaleCtrl = TextEditingController();
  final _batchCtrl = TextEditingController();
  String? _branchId;
  String? _itemId;
  DateTime? _expiryDate;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _quantityCtrl.dispose();
    _buyingCtrl.dispose();
    _retailCtrl.dispose();
    _wholesaleCtrl.dispose();
    _batchCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickExpiry() async {
    final picked = await showDatePicker(
      context: context,
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      initialDate: _expiryDate ?? DateTime.now(),
    );
    if (picked != null) setState(() => _expiryDate = picked);
  }

  Future<void> _submit() async {
    final quantity = double.tryParse(_quantityCtrl.text.trim());
    final buying = double.tryParse(_buyingCtrl.text.trim());
    final retail = double.tryParse(_retailCtrl.text.trim());
    final wholesale = _wholesaleCtrl.text.trim().isEmpty
        ? null
        : double.tryParse(_wholesaleCtrl.text.trim());
    if (_branchId == null || _itemId == null) {
      setState(() => _error = 'Choose a branch and item.');
      return;
    }
    if (quantity == null || buying == null || retail == null || quantity <= 0) {
      setState(() => _error = 'Enter a valid quantity and prices.');
      return;
    }
    if (wholesale == null && _wholesaleCtrl.text.trim().isNotEmpty) {
      setState(
        () => _error = 'Enter a valid wholesale price or leave it empty.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repo.addStock(
        branchId: _branchId!,
        itemId: _itemId!,
        quantity: quantity,
        buyingPrice: buying,
        retailPrice: retail,
        wholesalePrice: wholesale,
        batchNumber: _batchCtrl.text,
        expiryDate: _expiryDate,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on InventoryException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: 'Add stock',
      subtitle: 'The new batch will be available for sale immediately.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _branchId,
            decoration: fieldDecoration('Branch'),
            items: widget.branches
                .map((b) => DropdownMenuItem(value: b.id, child: Text(b.name)))
                .toList(),
            onChanged: _saving
                ? null
                : (value) => setState(() => _branchId = value),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _itemId,
            decoration: fieldDecoration('Item'),
            items: widget.items
                .map(
                  (item) => DropdownMenuItem(
                    value: item.id,
                    child: Text('${item.name} · ${item.unit}'),
                  ),
                )
                .toList(),
            onChanged: _saving
                ? null
                : (value) => setState(() => _itemId = value),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _quantityCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: fieldDecoration('Quantity'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _batchCtrl,
                  decoration: fieldDecoration('Batch number', hint: 'Optional'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _buyingCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: fieldDecoration('Buying price'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _retailCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: fieldDecoration('Selling price'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _wholesaleCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: fieldDecoration('Wholesale price', hint: 'Optional'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _saving ? null : _pickExpiry,
            style: outlineButtonStyle(),
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text(
              _expiryDate == null
                  ? 'Expiry date (optional)'
                  : _fmtDate(_expiryDate!.toIso8601String()),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: sans(12.5, weight: FontWeight.w600, color: kDanger),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: primaryButtonStyle(),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Add sellable stock'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ADJUST SHEET — damage / loss / corrections, reason always recorded
// ============================================================================

class _AdjustSheet extends StatefulWidget {
  final InventoryRepository repo;
  final StockBatch batch;
  const _AdjustSheet({required this.repo, required this.batch});

  @override
  State<_AdjustSheet> createState() => _AdjustSheetState();
}

class _AdjustSheetState extends State<_AdjustSheet> {
  bool _removing = true;
  final _qtyCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  bool _saving = false;
  String? _formError;

  @override
  void dispose() {
    _qtyCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final qty = double.tryParse(_qtyCtrl.text.trim());
    if (qty == null || qty <= 0) {
      setState(() => _formError = 'Enter a quantity above zero.');
      return;
    }
    if (_reasonCtrl.text.trim().isEmpty) {
      setState(
        () => _formError =
            'A reason is required — it goes into the movement log.',
      );
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await widget.repo.adjustStock(
        inventoryId: widget.batch.id,
        branchId: widget.batch.branchId,
        itemId: widget.batch.itemId,
        deltaQty: _removing ? -qty : qty,
        reason: _reasonCtrl.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on InventoryException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.batch;
    return SheetFrame(
      title: 'Adjust stock',
      subtitle: '${b.itemName} · Batch ${b.batchNumber} · ${b.branchName}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kBorder),
            ),
            child: Text(
              '${_fmtQty(b.qtyAvailable)} on hand',
              style: mono(14, weight: FontWeight.w700, color: kInk),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilterPill(
                label: 'Remove',
                selected: _removing,
                onTap: () => setState(() => _removing = true),
              ),
              const SizedBox(width: 8),
              FilterPill(
                label: 'Add back',
                selected: !_removing,
                onTap: () => setState(() => _removing = false),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _qtyCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: sans(14, color: kInk),
            decoration: fieldDecoration(
              _removing ? 'Quantity to remove' : 'Quantity to add back',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reasonCtrl,
            style: sans(14, color: kInk),
            minLines: 2,
            maxLines: 3,
            decoration: fieldDecoration(
              'Reason',
              hint: 'e.g. 3 bottles broken in transit',
            ),
          ),
          if (_formError != null) ...[
            const SizedBox(height: 10),
            Text(
              _formError!,
              style: sans(12.5, weight: FontWeight.w600, color: kDanger),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: primaryButtonStyle(),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Save adjustment'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// PRICE SHEET — change batch prices
// ============================================================================

class _PriceSheet extends StatefulWidget {
  final InventoryRepository repo;
  final StockBatch batch;
  const _PriceSheet({required this.repo, required this.batch});

  @override
  State<_PriceSheet> createState() => _PriceSheetState();
}

class _PriceSheetState extends State<_PriceSheet> {
  late final TextEditingController _buy = TextEditingController(
    text: widget.batch.buyingPrice.toStringAsFixed(0),
  );
  late final TextEditingController _retail = TextEditingController(
    text: widget.batch.retailPrice.toStringAsFixed(0),
  );
  late final TextEditingController _whole = TextEditingController(
    text: widget.batch.wholesalePrice?.toStringAsFixed(0) ?? '',
  );
  bool _saving = false;
  String? _formError;

  @override
  void dispose() {
    _buy.dispose();
    _retail.dispose();
    _whole.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final buy = double.tryParse(_buy.text.trim());
    final retail = double.tryParse(_retail.text.trim());
    final whole = _whole.text.trim().isEmpty
        ? null
        : double.tryParse(_whole.text.trim());
    if (buy == null ||
        buy < 0 ||
        retail == null ||
        retail < 0 ||
        (_whole.text.trim().isNotEmpty && whole == null)) {
      setState(() => _formError = 'Enter valid prices (zero or above).');
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await widget.repo.updateBatchPrices(
        inventoryId: widget.batch.id,
        buyingPrice: buy,
        retailPrice: retail,
        wholesalePrice: whole,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.batch;
    return SheetFrame(
      title: 'Change prices',
      subtitle: '${b.itemName} · Batch ${b.batchNumber} · ${b.branchName}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _buy,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: sans(14, color: kInk),
            decoration: fieldDecoration('Buying price (MK)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _retail,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: sans(14, color: kInk),
            decoration: fieldDecoration('Retail price (MK)'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _whole,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: sans(14, color: kInk),
            decoration: fieldDecoration(
              'Wholesale price (MK)',
              hint: 'Optional',
            ),
          ),
          if (_formError != null) ...[
            const SizedBox(height: 10),
            Text(
              _formError!,
              style: sans(12.5, weight: FontWeight.w600, color: kDanger),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: primaryButtonStyle(),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Save prices'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// ITEM FORM SHEET — add / edit catalog product
// ============================================================================

class _ItemFormSheet extends StatefulWidget {
  final InventoryRepository repo;
  final CatalogItem? item;
  final List<String> categories;
  const _ItemFormSheet({
    required this.repo,
    this.item,
    required this.categories,
  });

  @override
  State<_ItemFormSheet> createState() => _ItemFormSheetState();
}

class _ItemFormSheetState extends State<_ItemFormSheet> {
  late final TextEditingController _name = TextEditingController(
    text: widget.item?.name ?? '',
  );
  late final TextEditingController _category = TextEditingController(
    text: widget.item?.category == 'Uncategorised'
        ? ''
        : (widget.item?.category ?? ''),
  );
  late final TextEditingController _unit = TextEditingController(
    text: widget.item?.unit ?? 'unit',
  );
  late final TextEditingController _reorder = TextEditingController(
    text: (widget.item?.reorderLevel ?? 10).toStringAsFixed(0),
  );
  late bool _rx = widget.item?.requiresPrescription ?? false;
  bool _saving = false;
  String? _formError;

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _unit.dispose();
    _reorder.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reorder = double.tryParse(_reorder.text.trim());
    if (_name.text.trim().isEmpty) {
      setState(() => _formError = 'Item name is required.');
      return;
    }
    if (reorder == null || reorder < 0) {
      setState(() => _formError = 'Reorder level must be zero or above.');
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      if (widget.item == null) {
        await widget.repo.createItem(
          name: _name.text,
          category: _category.text,
          unit: _unit.text,
          reorderLevel: reorder,
          requiresPrescription: _rx,
        );
      } else {
        await widget.repo.updateItem(
          id: widget.item!.id,
          name: _name.text,
          category: _category.text,
          unit: _unit.text,
          reorderLevel: reorder,
          requiresPrescription: _rx,
        );
      }
      if (mounted) {
        Navigator.of(context)
            .pop(widget.item == null ? 'Item added.' : 'Item updated.');
      }
    } on InventoryException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: widget.item == null ? 'Add item' : 'Edit item',
      subtitle: widget.item == null
          ? 'New product in the catalog.'
          : widget.item!.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            style: sans(14, color: kInk),
            decoration: fieldDecoration('Item name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _category,
            style: sans(14, color: kInk),
            decoration: fieldDecoration('Category', hint: 'e.g. Antibiotics'),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _unit,
                  style: sans(14, color: kInk),
                  decoration: fieldDecoration('Unit', hint: 'tablet, bottle…'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _reorder,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: sans(14, color: kInk),
                  decoration: fieldDecoration('Reorder level'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            value: _rx,
            onChanged: (v) => setState(() => _rx = v),
            title: Text(
              'Requires prescription',
              style: sans(13.5, color: kInk),
            ),
            activeThumbColor: kPrimary,
            contentPadding: EdgeInsets.zero,
          ),
          if (_formError != null) ...[
            const SizedBox(height: 6),
            Text(
              _formError!,
              style: sans(12.5, weight: FontWeight.w600, color: kDanger),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: primaryButtonStyle(),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Text(widget.item == null ? 'Add item' : 'Save changes'),
          ),
        ],
      ),
    );
  }
}
