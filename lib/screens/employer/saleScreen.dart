import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';

import '../../appUser.dart';
import '../../widgets/employeeShell.dart';
import 'employeeUi.dart';
import 'receipt.dart';
import 'saleRepo.dart';

// ============================================================================
// SALE TAB — counter sales in five steps on one screen:
//   1 find items (search + category; no-stock greyed out)
//   2 cart (steppers capped at availability)
//   3 sale type (retail/wholesale re-prices every line)
//   4 customer (optional; required for credit; add on the spot)
//   5 payment (cash/change, or credit part-payment through the ledger)
//
// One create_sale call records everything atomically — a short sale is
// cancelled whole with a plain message, never half-saved. Receipts are PDF
// (80mm / 58mm / A5) with Print + Share + New sale. Reprints from Today's
// sales never show cash/change (not stored). Cashiers and managers sell;
// stock controllers get a notice; an admin picks a branch first.
// Lives in the shell's IndexedStack: nav bars stay visible throughout.
// ============================================================================

class _Line {
  final SaleItem item;
  double qty;
  _Line({required this.item, required this.qty});
}

class SaleScreen extends StatefulWidget {
  final AppUser user;
  final String branchName;
  const SaleScreen({super.key, required this.user, required this.branchName});

  @override
  State<SaleScreen> createState() => _SaleScreenState();
}

class _SaleScreenState extends State<SaleScreen> {
  final _repo = SaleRepository();
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  final _cashCtrl = TextEditingController();
  final _partCtrl = TextEditingController();

  List<ReportBranchLite> _branches = [];
  String? _adminBranchId;
  List<String> _categories = [];
  String _search = '';
  String? _category;
  List<SaleItem> _items = [];
  bool _itemsLoading = true;

  final Map<String, _Line> _cart = {};
  String _saleType = 'retail'; // retail | wholesale
  SaleCustomer? _customer;
  String _method = 'cash'; // cash | mobile_money | card | credit
  String _partMethod = 'cash';

  bool _processing = false;
  String? _formError;
  bool _historyMode = false;
  List<TodaySale> _today = [];
  bool _historyLoading = false;

  bool _loadedOnce = false;
  bool _wasSelected = false;

  bool get _isStock => widget.user.role == 'stock_controller';
  bool get _isAdmin => widget.user.role == 'admin';

  /// The branch this sale belongs to (admin picks one first).
  String? get _branchId => widget.user.branchId ?? _adminBranchId;

  String get _branchLabel {
    if (widget.user.branchId != null) return widget.branchName;
    if (_adminBranchId == null) return 'Choose a branch';
    return _branches.where((b) => b.id == _adminBranchId).map((b) => b.name).join();
  }

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _cashCtrl.dispose();
    _partCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selected = EmployeeShellScope.of(context)?.selectedIndex == 1;
    if (selected && !_wasSelected && _loadedOnce) _refreshAll(silent: true);
    _wasSelected = selected;
  }

  Future<void> _init() async {
    if (_isAdmin) {
      try {
        _branches = await _repo.fetchBranches();
      } catch (_) {}
    }
    try {
      _categories = await _repo.fetchCategories();
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
    await _refreshAll();
    _loadedOnce = true;
  }

  Future<void> _refreshAll({bool silent = false}) async {
    await Future.wait([_searchItems(silent: silent), _loadHistory(silent: true)]);
  }

  Future<void> _searchItems({bool silent = false}) async {
    final bid = _branchId;
    if (bid == null) {
      setState(() {
        _items = [];
        _itemsLoading = false;
      });
      return;
    }
    if (!silent) setState(() => _itemsLoading = true);
    try {
      final res = await _repo.searchItems(branchId: bid, query: _search, category: _category);
      if (!mounted) return;
      setState(() {
        _items = res;
        _itemsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _itemsLoading = false);
    }
  }

  Future<void> _loadHistory({bool silent = false}) async {
    final bid = _branchId;
    if (bid == null) return;
    if (!silent) setState(() => _historyLoading = true);
    try {
      final res = await _repo.todaySales(branchId: bid);
      if (!mounted) return;
      setState(() {
        _today = res;
        _historyLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _historyLoading = false);
    }
  }

  // ---- Cart --------------------------------------------------------------------

  double _priceOf(SaleItem item) => _saleType == 'wholesale' ? item.wholesale : item.retail;

  double get _total {
    var t = 0.0;
    for (final l in _cart.values) {
      t += l.qty * _priceOf(l.item);
    }
    return t;
  }

  int get _count => _cart.values.fold(0, (s, l) => s + l.qty.toInt());

  void _add(SaleItem item) {
    if (!item.inStock) return;
    final line = _cart[item.itemId];
    final cur = line?.qty ?? 0;
    if (cur + 1 > item.available) {
      empToast(context, 'Only ${empQty(item.available)} available for ${item.name}.', error: true);
      return;
    }
    setState(() {
      _cart[item.itemId] = _Line(item: item, qty: cur + 1);
    });
  }

  void _bump(String id, double delta) {
    final line = _cart[id];
    if (line == null) return;
    final next = line.qty + delta;
    if (next <= 0) {
      setState(() => _cart.remove(id));
      return;
    }
    if (next > line.item.available) {
      empToast(context, 'Only ${empQty(line.item.available)} available.', error: true);
      return;
    }
    setState(() => line.qty = next);
  }

  // ---- Checkout ------------------------------------------------------------------

  double? get _cashReceived => double.tryParse(_cashCtrl.text.trim());
  double? get _partAmount =>
      _partCtrl.text.trim().isEmpty ? 0 : double.tryParse(_partCtrl.text.trim());

  Future<void> _complete({bool fromSheet = false}) async {
    setState(() => _formError = null);
    final bid = _branchId;
    if (bid == null) {
      setState(() => _formError = 'Choose a branch first.');
      return;
    }
    if (_cart.isEmpty) {
      setState(() => _formError = 'The cart is empty — add an item first.');
      return;
    }
    if (_method == 'credit' && _customer == null) {
      setState(() => _formError = 'Credit sales need a customer. Add one below.');
      return;
    }
    double? cashGiven;
    if (_method == 'cash') {
      cashGiven = _cashReceived;
      if (cashGiven == null || cashGiven < _total) {
        setState(() => _formError = 'Cash received must cover the total of ${empMk(_total)}.');
        return;
      }
    }
    double part = 0;
    if (_method == 'credit') {
      final p = _partAmount;
      if (p == null || p < 0 || p > _total) {
        setState(() => _formError = 'Part-payment must be between 0 and ${empMk(_total)}.');
        return;
      }
      part = p;
    }

    setState(() => _processing = true);
    final saleTotal = _total;
    final cashGivenForReceipt = _method == 'cash' ? cashGiven : null;
    final changeForReceipt =
        (_method == 'cash' && cashGiven != null) ? cashGiven - saleTotal : null;
    try {
      final receipt = await _repo.createSale(
        branchId: bid,
        lines: [for (final l in _cart.values) {'item_id': l.item.itemId, 'quantity': l.qty}],
        saleType: _saleType,
        method: _method,
        customerId: _customer?.id,
        partPayment: _method == 'credit' ? part : null,
        partMethod: _method == 'credit' && part > 0 ? _partMethod : null,
      );
      if (!mounted) return;
      setState(() {
        _processing = false;
        _cart.clear();
        _customer = null;
        _cashCtrl.clear();
        _partCtrl.clear();
        _formError = null;
      });
      await _refreshAll(silent: true);
      if (!mounted) return;
      await _openReceipt(
        receipt,
        cashReceived: cashGivenForReceipt,
        change: changeForReceipt,
        isReprint: false,
      );
    } on SaleException catch (e) {
      if (mounted) setState(() => _processing = false);
      if (mounted) setState(() => _formError = e.message);
    } catch (e) {
      if (mounted) {
        setState(() {
          _processing = false;
          _formError = e.toString();
        });
      }
    }
  }

  Future<void> _openReceipt(Map<String, dynamic> receipt,
      {double? cashReceived, double? change, required bool isReprint}) async {
    await _showSaleSheet(
      context,
      builder: (_) => _ReceiptSheet(
        receipt: receipt,
        cashReceived: isReprint ? null : cashReceived,
        change: isReprint ? null : change,
        onNewSale: () => Navigator.of(context).pop(),
      ),
    );
  }

  Future<void> _reprint(TodaySale s) async {
    try {
      final receipt = await _repo.getReceipt(s.id);
      if (!mounted) return;
      await _openReceipt(receipt, isReprint: true);
    } on SaleException catch (e) {
      if (mounted) empToast(context, e.message, error: true);
    }
  }

  Future<void> _pickCustomer() async {
    final bid = _branchId;
    if (bid == null) return;
    final picked = await _showSaleSheet<SaleCustomer>(
      context,
      builder: (_) => _CustomerSheet(repo: _repo, branchId: bid),
    );
    if (picked != null && mounted) setState(() => _customer = picked);
  }

  // ---- Build -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: empBg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= empWideBreakpoint;
            final showBar = !wide &&
                !_isStock &&
                !_historyMode &&
                _cart.isNotEmpty &&
                _branchId != null;
            return Stack(
              children: [
                SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(wide ? 32 : 18, wide ? 28 : 14, wide ? 32 : 18, 24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1080),
                      child: _body(wide),
                    ),
                  ),
                ),
                if (showBar)
                  Positioned(
                    left: 18,
                    right: 18,
                    bottom: 12,
                    child: _cartBar(),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _cartBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: empPrimary,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: empPrimary.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$_count ${_count == 1 ? 'item' : 'items'}',
                    style: empSans(12, color: Colors.white70)),
                Text(empMk(_total),
                    style: empMono(17, weight: FontWeight.w700, color: Colors.white)),
              ],
            ),
          ),
          FilledButton(
            onPressed: _openCartSheet,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: empPrimary,
              minimumSize: const Size(0, 46),
              textStyle: empSans(14, weight: FontWeight.w700),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('View cart'),
          ),
        ],
      ),
    );
  }

  Future<void> _openCartSheet() async {
    await _showSaleSheet<void>(
      context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => EmpSheetFrame(
          title: 'Cart',
          subtitle: _branchLabel,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _checkoutCard(true),
              const SizedBox(height: 10),
              SizedBox(
                height: 54,
                child: FilledButton(
                  onPressed: _processing
                      ? null
                      : () async {
                          await _complete(fromSheet: true);
                          setSheet(() {});
                        },
                  style: empPrimaryButton(height: 54),
                  child: _processing
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text('Complete sale · ${empMk(_total)}'),
                ),
              ),
              if (_formError != null) ...[
                const SizedBox(height: 8),
                Text(_formError!,
                    style: empSans(12.5, weight: FontWeight.w600, color: empDanger)),
              ],
            ],
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _body(bool wide) {
    if (_isStock) {
      return const EmpCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sales are handled at the counter',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            SizedBox(height: 6),
            Text('Your role records stock, not sales. Head to the Stock tab to receive deliveries.',
                style: TextStyle(fontSize: 13)),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(wide),
        const SizedBox(height: 14),
        if (_isAdmin) ...[_adminBranchCard(), const SizedBox(height: 14)],
        if (_historyMode)
          _HistoryBlock(sales: _today, loading: _historyLoading, onTap: _reprint, onRefresh: () => _loadHistory())
        else if (wide)
          _desktop()
        else
          _mobileSearch(),
      ],
    );
  }

  Widget _header(bool wide) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_historyMode ? 'Today’s sales' : 'New sale',
                  style: empSans(22, weight: FontWeight.w700, color: empInk)),
              const SizedBox(height: 2),
              Text(_branchLabel, style: empSans(12.5, color: empMuted)),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: empSurface,
            border: Border.all(color: empBorder),
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.all(3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _modeTab('Sell', !_historyMode, () => setState(() => _historyMode = false)),
              _modeTab('History', _historyMode, () {
                setState(() => _historyMode = true);
                _loadHistory();
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _modeTab(String label, bool active, VoidCallback onTap) {
    return Material(
      color: active ? empPrimary : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(label,
              style: empSans(13,
                  weight: FontWeight.w600, color: active ? Colors.white : empMuted)),
        ),
      ),
    );
  }

  Widget _adminBranchCard() {
    return EmpCard(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: empBorder),
          borderRadius: BorderRadius.circular(10),
          color: Colors.white,
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _adminBranchId,
            isExpanded: true,
            hint: Text('Choose a branch to sell from', style: empSans(13.5, color: empMuted)),
            style: empSans(14, color: empInk),
            items: [for (final b in _branches) DropdownMenuItem(value: b.id, child: Text(b.name))],
            onChanged: (v) {
              setState(() => _adminBranchId = v);
              _refreshAll();
            },
          ),
        ),
      ),
    );
  }

  // ---- Desktop: two panels -----------------------------------------------------------

  Widget _desktop() {
    final selling = _branchId != null;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _searchRow(autofocus: true),
                const SizedBox(height: 10),
                _categoryChips(),
                const SizedBox(height: 10),
                _resultsList(),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: SingleChildScrollView(child: _checkoutCard(selling))),
                const SizedBox(height: 10),
                _completeButton(selling),
                if (_formError != null) ...[
                  const SizedBox(height: 8),
                  Text(_formError!,
                      style: empSans(12.5, weight: FontWeight.w600, color: empDanger)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---- Mobile: search + results, cart behind a bottom bar ------------------------------

  Widget _mobileSearch() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchRow(autofocus: false),
        const SizedBox(height: 10),
        _categoryChips(),
        const SizedBox(height: 10),
        _resultsList(),
        // Bottom cart bar reserves space so content isn't hidden behind it.
        SizedBox(height: _cart.isEmpty ? 8 : 76),
      ],
    );
  }

  // ---- Shared pieces ---------------------------------------------------------------------

  Widget _searchRow({required bool autofocus}) {
    return TextField(
      controller: _searchCtrl,
      focusNode: _searchFocus,
      autofocus: autofocus,
      onChanged: (v) {
        setState(() => _search = v);
        _searchItems(silent: true);
      },
      style: empSans(15, color: empInk),
      textInputAction: TextInputAction.search,
      decoration: empField('Search items…').copyWith(
        prefixIcon: const Icon(Icons.search, size: 22, color: empMuted),
        suffixIcon: _search.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear, size: 18, color: empMuted),
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _search = '');
                  _searchItems(silent: true);
                },
              ),
      ),
    );
  }

  Widget _categoryChips() {
    if (_categories.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _chip('All', _category == null, () {
            setState(() => _category = null);
            _searchItems(silent: true);
          }),
          const SizedBox(width: 8),
          for (final c in _categories) ...[
            _chip(c, _category == c, () {
              setState(() => _category = _category == c ? null : c);
              _searchItems(silent: true);
            }),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _chip(String label, bool active, VoidCallback onTap) {
    return Material(
      color: active ? empPrimary : empSurface,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: active ? empPrimary : empBorder),
          ),
          child: Text(label,
              style: empSans(13, weight: FontWeight.w600, color: active ? Colors.white : empMuted)),
        ),
      ),
    );
  }

  Widget _resultsList() {
    if (_branchId == null) {
      return const EmpEmpty(icon: Icons.storefront_outlined, message: 'Choose a branch above to start selling.');
    }
    if (_itemsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(color: empPrimary)),
      );
    }
    if (_items.isEmpty) {
      return EmpEmpty(
        icon: Icons.search_off_outlined,
        message: _search.trim().isEmpty
            ? 'No items with stock at this branch yet.'
            : 'No items found for “${_search.trim()}”.',
      );
    }
    return Column(
      children: [
        for (final item in _items) ...[
          _ItemRow(
            item: item,
            price: _priceOf(item),
            saleType: _saleType,
            onAdd: () => _add(item),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// Right panel (desktop) / cart sheet content (mobile).
  Widget _checkoutCard(bool selling) {
    return EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Cart ($_count ${_count == 1 ? 'item' : 'items'})',
              style: empSans(15, weight: FontWeight.w700, color: empInk)),
          const SizedBox(height: 10),
          if (_cart.isEmpty)
            Text('Tap + on an item to add it.', style: empSans(13, color: empMuted))
          else
            for (final l in _cart.values) _CartLineRow(line: l, price: _priceOf(l.item), onBump: _bump),
          const Divider(height: 20, color: empBorder),
          Text('Sale type', style: empSans(12.5, weight: FontWeight.w600, color: empMuted)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _typeTab('Retail', _saleType == 'retail', () => setState(() => _saleType = 'retail'))),
              const SizedBox(width: 8),
              Expanded(
                  child: _typeTab('Wholesale', _saleType == 'wholesale', () => setState(() => _saleType = 'wholesale'))),
            ],
          ),
          const SizedBox(height: 14),
          _CustomerBlock(
            customer: _customer,
            required: _method == 'credit',
            onPick: _pickCustomer,
            onClear: () => setState(() => _customer = null),
          ),
          const SizedBox(height: 14),
          _PaymentBlock(
            method: _method,
            onMethod: (m) => setState(() => _method = m),
            cashCtrl: _cashCtrl,
            total: _total,
            partCtrl: _partCtrl,
            partMethod: _partMethod,
            onPartMethod: (m) => setState(() => _partMethod = m),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: Text('Total', style: empSans(15, weight: FontWeight.w700, color: empInk))),
              Text(empMk(_total), style: empMono(19, weight: FontWeight.w700, color: empPrimary)),
            ],
          ),
          if (!selling)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Choose a branch to enable checkout.', style: empSans(12, color: empMuted)),
            ),
        ],
      ),
    );
  }

  Widget _typeTab(String label, bool active, VoidCallback onTap) {
    return Material(
      color: active ? empPrimaryTint : Colors.transparent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: active ? empPrimary : empBorder, width: active ? 1.5 : 1),
          ),
          child: Center(
            child: Text(label,
                style: empSans(13.5, weight: FontWeight.w600, color: active ? empPrimary : empMuted)),
          ),
        ),
      ),
    );
  }

  Widget _completeButton(bool selling) {
    return SizedBox(
      height: 56,
      child: FilledButton(
        onPressed: (!selling || _processing || _cart.isEmpty) ? null : _complete,
        style: empPrimaryButton(height: 56),
        child: _processing
            ? const SizedBox(
                width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Text('Complete sale · ${empMk(_total)}'),
      ),
    );
  }
}

// ============================================================================
// ITEM ROW (greyed out when there is nothing sellable)
// ============================================================================

class _ItemRow extends StatelessWidget {
  final SaleItem item;
  final double price;
  final String saleType;
  final VoidCallback onAdd;
  const _ItemRow({required this.item, required this.price, required this.saleType, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final enabled = item.inStock;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: EmpCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name,
                      style: empSans(14, weight: FontWeight.w600, color: enabled ? empInk : empMuted)),
                  const SizedBox(height: 2),
                  Text(
                    enabled
                        ? '${empMk(price)}${saleType == 'wholesale' ? ' wholesale' : ''} · ${empQty(item.available)} ${item.unit} left'
                        : 'Out of stock',
                    style: empSans(12.5, color: enabled ? empMuted : empDanger),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              height: 48,
              child: FilledButton(
                onPressed: enabled ? onAdd : null,
                style: FilledButton.styleFrom(
                  backgroundColor: empPrimary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: empBorder,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: EdgeInsets.zero,
                ),
                child: const Icon(Icons.add, size: 24),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// CART LINE
// ============================================================================

class _CartLineRow extends StatelessWidget {
  final _Line line;
  final double price;
  final void Function(String id, double delta) onBump;
  const _CartLineRow({required this.line, required this.price, required this.onBump});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(line.item.name, style: empSans(13.5, weight: FontWeight.w600, color: empInk)),
                Text('${empMk(price)} each · ${empMk(line.qty * price)}',
                    style: empSans(12, color: empMuted)),
              ],
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: empBorder),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove, size: 17),
                  color: empPrimary,
                  onPressed: () => onBump(line.item.itemId, -1),
                  visualDensity: VisualDensity.compact,
                ),
                SizedBox(
                  width: 30,
                  child: Center(
                    child: Text(empQty(line.qty), style: empMono(13.5, weight: FontWeight.w700, color: empInk)),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 17),
                  color: empPrimary,
                  onPressed: line.qty + 1 > line.item.available
                      ? null
                      : () => onBump(line.item.itemId, 1),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// CUSTOMER BLOCK
// ============================================================================

class _CustomerBlock extends StatelessWidget {
  final SaleCustomer? customer;
  final bool required;
  final VoidCallback onPick;
  final VoidCallback onClear;
  const _CustomerBlock({
    required this.customer,
    required this.required,
    required this.onPick,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Customer${required ? ' (required for credit)' : ' (optional)'}',
            style: empSans(12.5, weight: FontWeight.w600, color: empMuted)),
        const SizedBox(height: 6),
        if (customer == null)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onPick,
              style: OutlinedButton.styleFrom(
                foregroundColor: empPrimary,
                minimumSize: const Size(0, 44),
                side: const BorderSide(color: empBorder),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.person_add_outlined, size: 18),
              label: const Text('Add customer'),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: empPrimaryTint,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(customer!.name, style: empSans(13.5, weight: FontWeight.w700, color: empPrimary)),
                      if (customer!.balance > 0)
                        Text('Owes ${empMk(customer!.balance)}', style: empSans(11.5, color: empPrimary)),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: onPick,
                  child: Text('Change', style: empSans(12.5, weight: FontWeight.w600, color: empPrimary)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 17, color: empPrimary),
                  onPressed: onClear,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _CustomerSheet extends StatefulWidget {
  final SaleRepository repo;
  final String branchId;
  const _CustomerSheet({required this.repo, required this.branchId});

  @override
  State<_CustomerSheet> createState() => _CustomerSheetState();
}

class _CustomerSheetState extends State<_CustomerSheet> {
  final _searchCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  List<SaleCustomer> _results = [];
  bool _searching = false;
  bool _adding = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    setState(() => _searching = true);
    try {
      final res = await widget.repo.searchCustomers(branchId: widget.branchId, query: q);
      if (!mounted) return;
      if (_searchCtrl.text != q) return;
      setState(() {
        _results = res;
        _searching = false;
      });
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _create() async {
    if (_nameCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Enter the customer’s name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final c = await widget.repo.createCustomer(
        branchId: widget.branchId,
        name: _nameCtrl.text,
        phone: _phoneCtrl.text,
      );
      if (mounted) Navigator.of(context).pop(c);
    } on SaleException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return EmpSheetFrame(
      title: 'Customer',
      subtitle: 'Search, or add a new one on the spot.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _searchCtrl,
            onChanged: _search,
            style: empSans(14, color: empInk),
            decoration: empField('Search name…').copyWith(
              prefixIcon: const Icon(Icons.search, size: 20, color: empMuted),
            ),
          ),
          const SizedBox(height: 8),
          if (_searching)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: empPrimary)),
              ),
            )
          else
            for (final c in _results)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(c.name, style: empSans(14, weight: FontWeight.w600, color: empInk)),
                subtitle: Text(
                  '${c.phone.isEmpty ? 'no phone' : c.phone}${c.balance > 0 ? ' · owes ${empMk(c.balance)}' : ''}',
                  style: empSans(12, color: empMuted),
                ),
                trailing: const Icon(Icons.chevron_right, color: empMuted),
                onTap: () => Navigator.of(context).pop(c),
              ),
          TextButton.icon(
            onPressed: () => setState(() => _adding = !_adding),
            icon: Icon(_adding ? Icons.remove : Icons.add, size: 17),
            label: Text(_adding ? 'Hide new-customer form' : 'New customer',
                style: empSans(13, weight: FontWeight.w600, color: empPrimary)),
          ),
          if (_adding) ...[
            TextField(controller: _nameCtrl, style: empSans(14, color: empInk), decoration: empField('Full name')),
            const SizedBox(height: 10),
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              style: empSans(14, color: empInk),
              decoration: empField('Phone (optional)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: empSans(12.5, weight: FontWeight.w600, color: empDanger)),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving ? null : _create,
              style: empPrimaryButton(height: 46),
              child: _saving
                  ? const SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Save customer'),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// PAYMENT BLOCK
// ============================================================================

class _PaymentBlock extends StatelessWidget {
  final String method;
  final ValueChanged<String> onMethod;
  final TextEditingController cashCtrl;
  final double total;
  final TextEditingController partCtrl;
  final String partMethod;
  final ValueChanged<String> onPartMethod;
  const _PaymentBlock({
    required this.method,
    required this.onMethod,
    required this.cashCtrl,
    required this.total,
    required this.partCtrl,
    required this.partMethod,
    required this.onPartMethod,
  });

  @override
  Widget build(BuildContext context) {
    const methods = [
      ('cash', 'Cash', Icons.payments_outlined),
      ('mobile_money', 'MoMo', Icons.smartphone_outlined),
      ('card', 'Card', Icons.credit_card_outlined),
      ('credit', 'Credit', Icons.book_outlined),
    ];
    final cashGiven = double.tryParse(cashCtrl.text.trim());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Payment', style: empSans(12.5, weight: FontWeight.w600, color: empMuted)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (v, label, icon) in methods)
              ChoiceChip(
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [Icon(icon, size: 15), const SizedBox(width: 5), Text(label)],
                ),
                selected: method == v,
                onSelected: (_) => onMethod(v),
                selectedColor: empPrimary,
                backgroundColor: empSurface,
                side: BorderSide(color: method == v ? empPrimary : empBorder),
                labelStyle: empSans(13,
                    weight: FontWeight.w600, color: method == v ? Colors.white : empMuted),
                showCheckmark: false,
              ),
          ],
        ),
        if (method == 'cash') ...[
          const SizedBox(height: 10),
          TextField(
            controller: cashCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: empSans(15, color: empInk),
            onChanged: (_) => (context as Element).markNeedsBuild(),
            decoration: empField('Cash received (MK)'),
          ),
          if (cashGiven != null && cashGiven >= total) ...[
            const SizedBox(height: 6),
            Text('Change: ${empMk(cashGiven - total)}',
                style: empSans(13.5, weight: FontWeight.w700, color: empSuccess)),
          ],
        ],
        if (method == 'credit') ...[
          const SizedBox(height: 10),
          TextField(
            controller: partCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: empSans(14, color: empInk),
            onChanged: (_) => (context as Element).markNeedsBuild(),
            decoration: empField('Part-payment now (optional)', hint: '0 if nothing paid'),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final (v, label) in [('cash', 'Cash'), ('mobile_money', 'MoMo'), ('card', 'Card')])
                ChoiceChip(
                  label: Text(label),
                  selected: partMethod == v,
                  onSelected: (_) => onPartMethod(v),
                  selectedColor: empPrimaryTint,
                  backgroundColor: empSurface,
                  side: BorderSide(color: partMethod == v ? empPrimary : empBorder),
                  labelStyle: empSans(12.5,
                      weight: FontWeight.w600, color: partMethod == v ? empPrimary : empMuted),
                  showCheckmark: false,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

// ============================================================================
// TODAY'S SALES (history toggle + reprints)
// ============================================================================

class _HistoryBlock extends StatelessWidget {
  final List<TodaySale> sales;
  final bool loading;
  final ValueChanged<TodaySale> onTap;
  final VoidCallback onRefresh;
  const _HistoryBlock({
    required this.sales,
    required this.loading,
    required this.onTap,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(color: empPrimary)),
      );
    }
    if (sales.isEmpty) {
      return EmpEmpty(
        icon: Icons.receipt_long_outlined,
        message: 'No sales recorded at this branch today yet.',
      );
    }
    return EmpCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: List.generate(sales.length, (i) {
          final s = sales[i];
          var time = '';
          try {
            final d = DateTime.parse(s.time).toLocal();
            time = '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
          } catch (_) {}
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => onTap(s),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                decoration: BoxDecoration(
                  border:
                      i == sales.length - 1 ? null : const Border(bottom: BorderSide(color: empBorder)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(s.receipt, style: empSans(13, weight: FontWeight.w600, color: empInk)),
                          Text('$time · ${_methodName(s.method)}',
                              style: empSans(11.5, color: empMuted)),
                        ],
                      ),
                    ),
                    Text(empMk(s.total), style: empMono(13, weight: FontWeight.w700, color: empInk)),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 17, color: empMuted),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  String _methodName(String m) {
    switch (m) {
      case 'mobile_money':
        return 'MoMo';
      case 'credit':
        return 'Credit';
      case 'card':
        return 'Card';
      default:
        return 'Cash';
    }
  }
}

// ============================================================================
// RECEIPT SHEET (dialog on desktop, full-screen sheet on mobile)
// ============================================================================

Future<T?> _showSaleSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
  final wide = MediaQuery.of(context).size.width >= empWideBreakpoint;
  if (wide) {
    return showDialog<T>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(child: builder(ctx)),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      minChildSize: 0.5,
      builder: (_, ctrl) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SingleChildScrollView(controller: ctrl, child: builder(ctx)),
      ),
    ),
  );
}

class _ReceiptSheet extends StatefulWidget {
  final Map<String, dynamic> receipt;
  final double? cashReceived;
  final double? change;
  final VoidCallback onNewSale;
  const _ReceiptSheet({
    required this.receipt,
    required this.cashReceived,
    required this.change,
    required this.onNewSale,
  });

  @override
  State<_ReceiptSheet> createState() => _ReceiptSheetState();
}

class _ReceiptSheetState extends State<_ReceiptSheet> {
  String _format = 'roll80';
  bool _busy = false;

  PdfPageFormat get _pageFormat {
    switch (_format) {
      case 'roll57':
        return PdfPageFormat.roll57;
      case 'a5':
        return PdfPageFormat.a5;
      default:
        return PdfPageFormat.roll80;
    }
  }

  Future<void> _print() async {
    setState(() => _busy = true);
    try {
      await ReceiptService.printReceipt(widget.receipt,
          format: _pageFormat, cashReceived: widget.cashReceived, change: widget.change);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      await ReceiptService.shareReceipt(widget.receipt,
          format: _pageFormat, cashReceived: widget.cashReceived, change: widget.change);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.receipt;
    final items = ((r['items'] as List?) ?? []).cast<Map<String, dynamic>>();
    final total = ((r['total_amount'] as num?) ?? 0).toDouble();
    final paid = ((r['amount_paid'] as num?) ?? 0).toDouble();
    final due = ((r['balance_due'] as num?) ?? 0).toDouble();
    final method = (r['payment_method'] as String?) ?? '';
    final body = Padding(
      padding: EdgeInsets.fromLTRB(24, 12, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: empBorder, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.check_circle, size: 26, color: empSuccess),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Sale complete', style: empSans(18, weight: FontWeight.w700, color: empInk)),
                    Text('Receipt ${r['receipt_number'] ?? ''}', style: empSans(13, color: empMuted)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20, color: empMuted),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: empBg, borderRadius: BorderRadius.circular(10)),
            child: Column(
              children: [
                for (final it in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('${it['name']} × ${it['quantity']}',
                              style: empSans(13, color: empInk)),
                        ),
                        Text(empMk((it['subtotal'] as num).toDouble()),
                            style: empMono(13, weight: FontWeight.w600, color: empInk)),
                      ],
                    ),
                  ),
                const Divider(color: empBorder),
                Row(
                  children: [
                    Expanded(child: Text('Total', style: empSans(14, weight: FontWeight.w700, color: empInk))),
                    Text(empMk(total), style: empMono(16, weight: FontWeight.w700, color: empPrimary)),
                  ],
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(child: Text('Paid ($method)', style: empSans(12.5, color: empMuted))),
                    Text(empMk(paid), style: empMono(12.5, color: empMuted)),
                  ],
                ),
                if (due > 0)
                  Row(
                    children: [
                      Expanded(
                          child: Text('Balance owing',
                              style: empSans(12.5, weight: FontWeight.w700, color: empDanger))),
                      Text(empMk(due), style: empMono(12.5, weight: FontWeight.w700, color: empDanger)),
                    ],
                  ),
                if (widget.cashReceived != null) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(child: Text('Cash received', style: empSans(12.5, color: empMuted))),
                      Text(empMk(widget.cashReceived!), style: empMono(12.5, color: empMuted)),
                    ],
                  ),
                ],
                if (widget.change != null && widget.change! > 0)
                  Row(
                    children: [
                      Expanded(
                          child: Text('Change',
                              style: empSans(12.5, weight: FontWeight.w700, color: empSuccess))),
                      Text(empMk(widget.change!),
                          style: empMono(12.5, weight: FontWeight.w700, color: empSuccess)),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text('Paper size', style: empSans(12.5, weight: FontWeight.w600, color: empMuted)),
          const SizedBox(height: 6),
          Row(
            children: [
              _formatChip('80mm receipt', 'roll80'),
              const SizedBox(width: 8),
              _formatChip('58mm receipt', 'roll57'),
              const SizedBox(width: 8),
              _formatChip('A5 paper', 'a5'),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _print,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: empPrimary,
                    minimumSize: const Size(0, 50),
                    side: const BorderSide(color: empBorder),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.print_outlined, size: 19),
                  label: const Text('Print'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _share,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: empPrimary,
                    minimumSize: const Size(0, 50),
                    side: const BorderSide(color: empBorder),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.share_outlined, size: 19),
                  label: const Text('Share'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: widget.onNewSale,
              style: empPrimaryButton(height: 52),
              child: const Text('New sale'),
            ),
          ),
        ],
      ),
    );
    // Desktop dialog already scrolls; mobile sheet scrolls via its own view.
    if (MediaQuery.of(context).size.width >= empWideBreakpoint) return body;
    return SafeArea(child: body);
  }

  Widget _formatChip(String label, String value) {
    final active = _format == value;
    return ChoiceChip(
      label: Text(label),
      selected: active,
      onSelected: (_) => setState(() => _format = value),
      selectedColor: empPrimary,
      backgroundColor: empSurface,
      side: BorderSide(color: active ? empPrimary : empBorder),
      labelStyle:
          empSans(12.5, weight: FontWeight.w600, color: active ? Colors.white : empMuted),
      showCheckmark: false,
    );
  }
}
