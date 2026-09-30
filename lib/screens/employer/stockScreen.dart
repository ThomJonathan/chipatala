import 'package:flutter/material.dart';

import '../../appUser.dart';
import '../../widgets/employeeShell.dart';
import 'employeeHome.dart' show branchStockFilter;
import 'employeeUi.dart';
import 'stockRepo.dart';

// ============================================================================
// CASHIER STOCK — own-branch stock list + receiving deliveries.
//   Receiving needs stock access (admin grant); without it the screen is
//   read-only with a "Request access" path. Home's alert cards deep-link
//   here pre-filtered via branchStockFilter. New stock appears on the sales
//   list immediately after receive_stock_delivery() commits.
// ============================================================================

class StockScreen extends StatefulWidget {
  final AppUser user;
  final String branchName;
  const StockScreen({super.key, required this.user, required this.branchName});

  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  final _repo = CashierStockRepository();
  final _searchCtrl = TextEditingController();

  bool _loading = true;
  String? _error;
  List<BranchStockRow> _rows = [];
  String _query = '';
  String _chip = 'all'; // all | low | expiring

  bool _canReceive = false;
  OwnAccess _access = const OwnAccess(state: OwnAccessState.none);

  bool _loadedOnce = false;
  bool _wasSelected = false;

  String? get _branchId => widget.user.branchId;

  @override
  void initState() {
    super.initState();
    _consumeIncomingFilter();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _consumeIncomingFilter({bool notify = false}) {
    final f = branchStockFilter.value;
    branchStockFilter.value = null;
    if (f == 'low' || f == 'expiring') {
      _chip = f!;
      if (notify && mounted) setState(() {});
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selected = EmployeeShellScope.of(context)?.selectedIndex == 2;
    if (selected && !_wasSelected) {
      if (_loadedOnce) {
        _consumeIncomingFilter(notify: true);
        _load(silent: true);
      }
    }
    _wasSelected = selected;
  }

  Future<void> _load({bool silent = false}) async {
    final bid = _branchId;
    if (bid == null) {
      setState(() {
        _loading = false;
        _error = 'No branch assigned to this account yet.';
      });
      return;
    }
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait([
        _repo.fetchStock(branchId: bid, query: _query),
        _repo.hasAccess(),
        _repo.myStatus(),
      ]);
      if (!mounted) return;
      setState(() {
        _rows = results[0] as List<BranchStockRow>;
        _canReceive = results[1] as bool;
        _access = results[2] as OwnAccess;
        _loading = false;
        _error = null;
        _loadedOnce = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<BranchStockRow> get _visible {
    return _rows.where((r) {
      switch (_chip) {
        case 'low':
          if (!r.low) return false;
        case 'expiring':
          if (!r.expiring) return false;
      }
      return true;
    }).toList();
  }

  Future<void> _requestAccess() async {
    final reason = await _showStockSheet<String>(
      context,
      builder: (_) => _ReasonSheet(),
    );
    if (reason == null || reason.trim().isEmpty) return;
    try {
      await _repo.requestAccess(reason);
      await _load(silent: true);
      if (mounted) empToast(context, 'Request sent. The admin will decide.');
    } on StockException catch (e) {
      if (mounted) empToast(context, e.message, error: true);
    }
  }

  Future<void> _endAccess() async {
    final id = _access.requestId;
    if (id == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End your stock access?'),
        content: const Text('You will no longer be able to receive stock.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep it')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('I’m done')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _repo.endOwnAccess(id);
      await _load(silent: true);
      if (mounted) empToast(context, 'Access ended.');
    } on StockException catch (e) {
      if (mounted) empToast(context, e.message, error: true);
    }
  }

  Future<void> _receive() async {
    final bid = _branchId;
    if (bid == null) return;
    final done = await _showStockSheet<bool>(
      context,
      builder: (_) => _ReceiveSheet(repo: _repo, branchId: bid),
    );
    if (done == true && mounted) {
      stockChanged.value++; // sale list + home pick up the new quantities
      await _load(silent: true);
      if (mounted) empToast(context, 'Delivery received — items are on the sales list.');
    }
  }

  // ---- Build ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: empBg,
      body: SafeArea(
        child: RefreshIndicator(
          color: empPrimary,
          onRefresh: () => _load(silent: true),
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= empWideBreakpoint;
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(wide ? 32 : 18, wide ? 28 : 14, wide ? 32 : 18, 24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: _body(wide),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _body(bool wide) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 90),
        child: Center(child: CircularProgressIndicator(color: empPrimary)),
      );
    }
    if (_error != null || _branchId == null) {
      return EmpCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Couldn’t load stock', style: empSans(15, weight: FontWeight.w700, color: empInk)),
            const SizedBox(height: 6),
            Text(_error ?? '', style: empSans(13, color: empMuted)),
            const SizedBox(height: 14),
            FilledButton(onPressed: _load, style: empPrimaryButton(height: 44), child: const Text('Retry')),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Stock', style: empSans(22, weight: FontWeight.w700, color: empInk)),
        const SizedBox(height: 2),
        Text(widget.branchName, style: empSans(12.5, color: empMuted)),
        const SizedBox(height: 14),
        _accessBanner(),
        const SizedBox(height: 14),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            onPressed: _canReceive ? _receive : null,
            style: empPrimaryButton(height: 54),
            icon: const Icon(Icons.add_box_outlined, size: 21),
            label: const Text('Receive stock'),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _searchCtrl,
          onChanged: (v) {
            setState(() => _query = v);
            _load(silent: true);
          },
          style: empSans(14, color: empInk),
          decoration: empField('Search stock…').copyWith(
            prefixIcon: const Icon(Icons.search, size: 20, color: empMuted),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _filterChip('All', 'all'),
            const SizedBox(width: 8),
            _filterChip('Low stock', 'low'),
            const SizedBox(width: 8),
            _filterChip('Expiring', 'expiring'),
          ],
        ),
        const SizedBox(height: 12),
        _list(),
      ],
    );
  }

  Widget _accessBanner() {
    if (_canReceive && _access.state == OwnAccessState.active) {
      final until = _access.expiresAt == null
          ? 'until the admin removes it'
          : 'until ${_fmtTime(_access.expiresAt!)}';
      return EmpCard(
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: empSuccessTint, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.verified_outlined, size: 19, color: empSuccess),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('You can receive stock', style: empSans(13.5, weight: FontWeight.w700, color: empInk)),
                  Text('Access lasts $until.', style: empSans(12, color: empMuted)),
                ],
              ),
            ),
            TextButton(
              onPressed: _endAccess,
              child: Text('I’m done', style: empSans(13, weight: FontWeight.w700, color: empPrimary)),
            ),
          ],
        ),
      );
    }
    if (_access.state == OwnAccessState.pending) {
      return EmpCard(
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: empWarnTint, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.hourglass_top_outlined, size: 19, color: empWarn),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Request waiting', style: empSans(13.5, weight: FontWeight.w700, color: empInk)),
                  Text('The admin hasn’t decided yet.', style: empSans(12, color: empMuted)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return EmpCard(
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: empPrimaryTint, borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.lock_outline, size: 19, color: empPrimary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Receiving needs permission', style: empSans(13.5, weight: FontWeight.w700, color: empInk)),
                Text('Ask the admin when a delivery arrives.', style: empSans(12, color: empMuted)),
              ],
            ),
          ),
          FilledButton(
            onPressed: _requestAccess,
            style: empPrimaryButton(height: 40),
            child: const Text('Request'),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String value) {
    final active = _chip == value;
    return ChoiceChip(
      label: Text(label),
      selected: active,
      onSelected: (_) => setState(() => _chip = value),
      selectedColor: empPrimary,
      backgroundColor: empSurface,
      side: BorderSide(color: active ? empPrimary : empBorder),
      labelStyle: empSans(13, weight: FontWeight.w600, color: active ? Colors.white : empMuted),
      showCheckmark: false,
    );
  }

  Widget _list() {
    final rows = _visible;
    if (rows.isEmpty) {
      return EmpEmpty(
        icon: Icons.inventory_2_outlined,
        message: _query.trim().isEmpty ? 'Nothing here for this filter.' : 'No stock found for “${_query.trim()}”.',
      );
    }
    return EmpCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: List.generate(rows.length, (i) {
          final r = rows[i];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: BoxDecoration(
              border: i == rows.length - 1 ? null : const Border(bottom: BorderSide(color: empBorder)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.name, style: empSans(13.5, weight: FontWeight.w600, color: empInk)),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (r.low) ...[
                            _pill('Low', empWarn, empWarnTint),
                            const SizedBox(width: 6),
                          ],
                          if (r.expiring) ...[
                            _pill('Expiring', empDanger, empDangerTint),
                            const SizedBox(width: 6),
                          ],
                          Text('${empQty(r.qty)} ${r.unit} · ${empMk(r.retail)}',
                              style: empSans(12, color: empMuted)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _pill(String label, Color fg, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: empSans(10.5, weight: FontWeight.w700, color: fg)),
    );
  }

  String _fmtTime(DateTime dt) {
    final l = dt.toLocal();
    return '${l.day}/${l.month}/${l.year} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

Future<T?> _showStockSheet<T>(BuildContext context, {required WidgetBuilder builder}) {
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
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(child: builder(ctx)),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: builder,
  );
}

class _ReasonSheet extends StatefulWidget {
  @override
  State<_ReasonSheet> createState() => _ReasonSheetState();
}

class _ReasonSheetState extends State<_ReasonSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EmpSheetFrame(
      title: 'Request stock access',
      subtitle: 'Tell the admin why you need it.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _ctrl,
            minLines: 2,
            maxLines: 3,
            style: empSans(14, color: empInk),
            decoration: empField('Reason', hint: 'e.g. MSD delivery arrived'),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_ctrl.text.trim()),
            style: empPrimaryButton(),
            child: const Text('Send request'),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// RECEIVE SHEET — delivery lines then one atomic receive_stock_delivery().
// ============================================================================

class _ReceiveLineForm {
  CatalogOption? item;
  final qtyCtrl = TextEditingController();
  final batchCtrl = TextEditingController();
  final buyCtrl = TextEditingController();
  final retailCtrl = TextEditingController();
  final wholeCtrl = TextEditingController();
  DateTime? expiry;
  void dispose() {
    qtyCtrl.dispose();
    batchCtrl.dispose();
    buyCtrl.dispose();
    retailCtrl.dispose();
    wholeCtrl.dispose();
  }
}

class _ReceiveSheet extends StatefulWidget {
  final CashierStockRepository repo;
  final String branchId;
  const _ReceiveSheet({required this.repo, required this.branchId});

  @override
  State<_ReceiveSheet> createState() => _ReceiveSheetState();
}

class _ReceiveSheetState extends State<_ReceiveSheet> {
  final List<_ReceiveLineForm> _lines = [_ReceiveLineForm()];
  List<SupplierOption> _suppliers = [];
  String? _supplierId;
  final _invoiceCtrl = TextEditingController();
  bool _saving = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    _loadSuppliers();
  }

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _invoiceCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSuppliers() async {
    try {
      final s = await widget.repo.fetchSuppliers();
      if (mounted) setState(() => _suppliers = s);
    } catch (_) {}
  }

  Future<void> _pickItem(_ReceiveLineForm line) async {
    final picked = await _showStockSheet<CatalogOption>(
      context,
      builder: (_) => _ItemPickerSheet(repo: widget.repo),
    );
    if (picked != null && mounted) setState(() => line.item = picked);
  }

  Future<void> _submit() async {
    final parsed = <ReceiveLine>[];
    for (final l in _lines) {
      if (l.item == null) {
        setState(() => _formError = 'Pick an item for every line.');
        return;
      }
      final qty = double.tryParse(l.qtyCtrl.text.trim());
      final buy = double.tryParse(l.buyCtrl.text.trim());
      final retail = double.tryParse(l.retailCtrl.text.trim());
      final whole = l.wholeCtrl.text.trim().isEmpty ? null : double.tryParse(l.wholeCtrl.text.trim());
      if (qty == null || qty <= 0 || buy == null || buy < 0 || retail == null || retail < 0) {
        setState(() => _formError = 'Each line needs quantity, buying and retail prices.');
        return;
      }
      if (whole != null && whole < 0) {
        setState(() => _formError = 'Wholesale prices cannot be negative.');
        return;
      }
      String? exp;
      if (l.expiry != null) {
        exp = '${l.expiry!.year}-${l.expiry!.month.toString().padLeft(2, '0')}-${l.expiry!.day.toString().padLeft(2, '0')}';
      }
      parsed.add(ReceiveLine(
        itemId: l.item!.id,
        quantity: qty,
        buyingPrice: buy,
        retailPrice: retail,
        wholesalePrice: whole,
        expiryDate: exp,
        batchNumber: l.batchCtrl.text,
      ));
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await widget.repo.receive(
        branchId: widget.branchId,
        supplierId: _supplierId,
        invoice: _invoiceCtrl.text,
        lines: parsed,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on StockException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _formError = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return EmpSheetFrame(
      title: 'Receive stock',
      subtitle: 'Delivered items go straight onto the sales list.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: empBorder),
              borderRadius: BorderRadius.circular(10),
              color: Colors.white,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: _supplierId,
                isExpanded: true,
                hint: Text('Supplier (optional)', style: empSans(13.5, color: empMuted)),
                style: empSans(14, color: empInk),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('No supplier')),
                  for (final s in _suppliers) DropdownMenuItem<String?>(value: s.id, child: Text(s.name)),
                ],
                onChanged: (v) => setState(() => _supplierId = v),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _invoiceCtrl,
            style: empSans(14, color: empInk),
            decoration: empField('Invoice number (optional)'),
          ),
          const SizedBox(height: 14),
          for (int i = 0; i < _lines.length; i++) ...[
            _lineCard(i, _lines[i]),
            const SizedBox(height: 10),
          ],
          OutlinedButton.icon(
            onPressed: () => setState(() => _lines.add(_ReceiveLineForm())),
            style: OutlinedButton.styleFrom(
              foregroundColor: empPrimary,
              minimumSize: const Size(0, 44),
              side: const BorderSide(color: empBorder),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add another item'),
          ),
          if (_formError != null) ...[
            const SizedBox(height: 10),
            Text(_formError!, style: empSans(12.5, weight: FontWeight.w600, color: empDanger)),
          ],
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: empPrimaryButton(),
            child: _saving
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Save delivery'),
          ),
        ],
      ),
    );
  }

  Widget _lineCard(int i, _ReceiveLineForm l) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: empBg,
        border: Border.all(color: empBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l.item?.name ?? 'Item ${i + 1}',
                    style: empSans(14, weight: FontWeight.w700, color: empInk)),
              ),
              TextButton(
                onPressed: () => _pickItem(l),
                child: Text(l.item == null ? 'Pick item' : 'Change',
                    style: empSans(13, weight: FontWeight.w700, color: empPrimary)),
              ),
              if (_lines.length > 1)
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 19, color: empDanger),
                  onPressed: () => setState(() {
                    l.dispose();
                    _lines.removeAt(i);
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: l.qtyCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: empSans(14, color: empInk),
                  decoration: empField('Qty'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: l.batchCtrl,
                  style: empSans(14, color: empInk),
                  decoration: empField('Batch no.'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: l.buyCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: empSans(14, color: empInk),
                  decoration: empField('Buying'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: l.retailCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: empSans(14, color: empInk),
                  decoration: empField('Retail'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: l.wholeCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: empSans(14, color: empInk),
                  decoration: empField('Wholesale?'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final now = DateTime.now();
              final d = await showDatePicker(
                context: context,
                initialDate: l.expiry ?? now,
                firstDate: DateTime(now.year, now.month, now.day),
                lastDate: DateTime(now.year + 10),
              );
              if (d != null && mounted) setState(() => l.expiry = d);
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: empInk,
              minimumSize: const Size(0, 44),
              side: const BorderSide(color: empBorder),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.calendar_month_outlined, size: 18),
            label: Text(l.expiry == null
                ? 'Expiry (optional)'
                : '${l.expiry!.day}/${l.expiry!.month}/${l.expiry!.year} — tap to change'),
          ),
        ],
      ),
    );
  }
}

class _ItemPickerSheet extends StatefulWidget {
  final CashierStockRepository repo;
  const _ItemPickerSheet({required this.repo});

  @override
  State<_ItemPickerSheet> createState() => _ItemPickerSheetState();
}

class _ItemPickerSheetState extends State<_ItemPickerSheet> {
  final _ctrl = TextEditingController();
  List<CatalogOption> _results = [];
  bool _searching = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    setState(() => _searching = true);
    try {
      final res = await widget.repo.searchCatalog(q);
      if (!mounted || _ctrl.text != q) return;
      setState(() {
        _results = res;
        _searching = false;
      });
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return EmpSheetFrame(
      title: 'Pick item',
      subtitle: 'Only products from the catalog.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _ctrl,
            onChanged: _search,
            autofocus: true,
            style: empSans(14, color: empInk),
            decoration: empField('Type a drug name…').copyWith(
              prefixIcon: const Icon(Icons.search, size: 20, color: empMuted),
            ),
          ),
          const SizedBox(height: 8),
          if (_searching)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
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
                trailing: const Icon(Icons.chevron_right, color: empMuted),
                onTap: () => Navigator.of(context).pop(c),
              ),
        ],
      ),
    );
  }
}
