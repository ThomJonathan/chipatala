import 'dart:async';

import 'package:flutter/material.dart';

import '../../appUser.dart';
import '../../widgets/employeeShell.dart';
import 'employeeHome.dart';
import 'employeeUi.dart';
import 'stockRepo.dart';

class StockScreen extends StatefulWidget {
  final AppUser user;
  final String branchName;
  const StockScreen({super.key, required this.user, required this.branchName});

  @override
  State<StockScreen> createState() => _StockScreenState();
}

enum _StockFilter { all, low, expiring, expired, out }

class _StockScreenState extends State<StockScreen> {
  final _repo = StockRepository();
  final _search = TextEditingController();
  List<StockItem> _items = [];
  List<String> _categories = [];
  StockAccessState? _access;
  bool _loading = true;
  bool _receiveMode = false;
  String? _error;
  String? _category;
  _StockFilter _filter = _StockFilter.all;
  Timer? _timer;

  String get _branchId => widget.user.branchId!;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_receiveMode) _loadAccess(silent: true);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final selected = EmployeeShellScope.of(context)?.selectedIndex == 2;
    if (selected) {
      final filter = branchStockFilter.value;
      if (filter != null) {
        branchStockFilter.value = null;
        _filter = filter == 'low' ? _StockFilter.low : _StockFilter.expiring;
      }
      if (!_receiveMode) _load(silent: true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent)
      setState(() {
        _loading = true;
        _error = null;
      });
    try {
      final results = await Future.wait([
        _repo.fetchItems(branchId: _branchId),
        _repo.fetchCategories(),
        _repo.fetchAccess(),
      ]);
      if (!mounted) return;
      setState(() {
        _items = results[0] as List<StockItem>;
        _categories = results[1] as List<String>;
        _access = results[2] as StockAccessState?;
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

  Future<void> _loadAccess({bool silent = false}) async {
    try {
      final value = await _repo.fetchAccess();
      if (mounted) setState(() => _access = value);
    } catch (_) {
      if (!silent && mounted)
        empToast(context, 'Could not refresh stock access.', error: true);
    }
  }

  List<StockItem> get _visible {
    final q = _search.text.trim().toLowerCase();
    return _items.where((item) {
      if (q.isNotEmpty && !item.name.toLowerCase().contains(q)) return false;
      if (_category != null && item.category != _category) return false;
      switch (_filter) {
        case _StockFilter.low:
          return item.isLow;
        case _StockFilter.expiring:
          return item.isExpiringSoon;
        case _StockFilter.expired:
          return item.isExpired;
        case _StockFilter.out:
          return item.isOut;
        case _StockFilter.all:
          return true;
      }
    }).toList();
  }

  Future<void> _requestAccess() async {
    final reason = await _reasonSheet();
    if (reason == null) return;
    try {
      await _repo.requestAccess(reason);
      await _loadAccess();
      if (mounted) empToast(context, 'Request sent to the admin.');
    } on StockException catch (e) {
      if (mounted) empToast(context, e.message, error: true);
    }
  }

  Future<void> _endAccess() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Done receiving stock?'),
        content: const Text('This will end your stock access immediately.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("I'm done"),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _repo.endAccess();
      await _loadAccess();
      if (mounted) empToast(context, 'Stock access ended.');
    } on StockException catch (e) {
      if (mounted) empToast(context, e.message, error: true);
    }
  }

  Future<String?> _reasonSheet() async {
    final controller = TextEditingController();
    String? selected;
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => EmpSheetFrame(
          title: 'Request stock access',
          subtitle: 'Tell the admin why you need to receive or update stock.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final value in [
                    'Delivery arrived',
                    'MSD delivery arrived',
                    'Stock count',
                  ])
                    ChoiceChip(
                      label: Text(value),
                      selected: selected == value,
                      onSelected: (_) {
                        setSheet(() {
                          selected = value;
                          controller.text = value;
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                maxLines: 2,
                decoration: empField(
                  'Reason (optional)',
                  hint: 'For example: Delivery arrived',
                ),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, controller.text),
                style: empPrimaryButton(),
                child: const Text('Send request'),
              ),
            ],
          ),
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _details(StockItem item) async {
    final batches = await _repo.fetchBatches(
      branchId: _branchId,
      itemId: item.id,
    );
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => EmpSheetFrame(
        title: item.name,
        subtitle: '${item.category} · ${item.unit}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (item.prescription) _tag('Prescription', empWarnTint, empWarn),
            const SizedBox(height: 10),
            if (batches.isEmpty)
              const EmpEmpty(
                icon: Icons.inventory_2_outlined,
                message: 'Nothing is currently on the shelf.',
              )
            else
              for (final batch in batches) _BatchTile(batch: batch),
            const SizedBox(height: 12),
            if (!item.discontinued && !item.isOut)
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  EmployeeShell.switchTo(context, 1);
                },
                icon: const Icon(Icons.point_of_sale_outlined),
                label: const Text('Add to sale'),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tag(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: empSans(11, weight: FontWeight.w600, color: fg),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_receiveMode && _access?.canReceive == true) {
      return _ReceiveStockPage(
        branchId: _branchId,
        repo: _repo,
        onDone: () {
          setState(() => _receiveMode = false);
          _load();
        },
        onCancel: () => setState(() => _receiveMode = false),
      );
    }
    return Scaffold(
      backgroundColor: empBg,
      body: RefreshIndicator(
        color: empPrimary,
        onRefresh: () => _load(),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1180),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Stock',
                          style: empSans(
                            22,
                            weight: FontWeight.w700,
                            color: empInk,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () => _load(),
                        icon: const Icon(Icons.refresh, color: empMuted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _AccessBanner(
                    access: _access,
                    onRequest: _requestAccess,
                    onReceive: () => setState(() => _receiveMode = true),
                    onDone: _endAccess,
                  ),
                  const SizedBox(height: 14),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(40),
                      child: Center(
                        child: CircularProgressIndicator(color: empPrimary),
                      ),
                    )
                  else if (_error != null)
                    EmpCard(
                      child: Text(
                        _error!,
                        style: empSans(13, color: empDanger),
                      ),
                    )
                  else ...[
                    TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration:
                          empField(
                            'Search stock',
                            hint: 'Search by item name',
                          ).copyWith(
                            prefixIcon: const Icon(
                              Icons.search,
                              color: empMuted,
                            ),
                          ),
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _chip('All', _StockFilter.all, _items.length),
                          _chip(
                            'Low',
                            _StockFilter.low,
                            _items.where((i) => i.isLow).length,
                          ),
                          _chip(
                            'Expiring soon',
                            _StockFilter.expiring,
                            _items.where((i) => i.isExpiringSoon).length,
                          ),
                          _chip(
                            'Expired',
                            _StockFilter.expired,
                            _items.where((i) => i.isExpired).length,
                          ),
                          _chip(
                            'Out of stock',
                            _StockFilter.out,
                            _items.where((i) => i.isOut).length,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_categories.isNotEmpty)
                      DropdownButtonFormField<String?>(
                        value: _category,
                        decoration: empField('Category'),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('All categories'),
                          ),
                          ..._categories.map(
                            (c) => DropdownMenuItem(value: c, child: Text(c)),
                          ),
                        ],
                        onChanged: (v) => setState(() => _category = v),
                      ),
                    const SizedBox(height: 14),
                    if (_visible.isEmpty)
                      EmpEmpty(
                        icon: Icons.inventory_2_outlined,
                        message: _filter == _StockFilter.low
                            ? 'Nothing is low on stock right now.'
                            : 'No stock matches these filters.',
                      )
                    else
                      LayoutBuilder(
                        builder: (_, c) => c.maxWidth >= empWideBreakpoint
                            ? _desktopList(_visible)
                            : _mobileList(_visible),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip(String label, _StockFilter value, int count) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text('$label ($count)'),
      selected: _filter == value,
      onSelected: (_) => setState(() => _filter = value),
    ),
  );

  Widget _desktopList(List<StockItem> rows) => EmpCard(
    child: Column(
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Expanded(flex: 3, child: Text('Item')),
              Expanded(flex: 2, child: Text('Category')),
              Expanded(child: Text('Available')),
              Expanded(child: Text('Price')),
              Expanded(child: Text('Status')),
            ],
          ),
        ),
        for (final item in rows)
          _StockRow(item: item, onTap: () => _details(item)),
      ],
    ),
  );

  Widget _mobileList(List<StockItem> rows) => Column(
    children: [
      for (final item in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _StockCard(item: item, onTap: () => _details(item)),
        ),
    ],
  );
}

class _AccessBanner extends StatelessWidget {
  final StockAccessState? access;
  final VoidCallback onRequest;
  final VoidCallback onReceive;
  final VoidCallback onDone;
  const _AccessBanner({
    required this.access,
    required this.onRequest,
    required this.onReceive,
    required this.onDone,
  });

  String _label() {
    if (access == null)
      return 'You can view stock. To receive stock, ask the admin.';
    switch (access!.status) {
      case 'pending':
        return 'Waiting for the admin’s approval, sent at ${_time(access!.requestedAt)}.';
      case 'approved':
        if (access!.expiresAt == null)
          return 'You have stock access until the admin removes it.';
        return 'You have stock access until ${_time(access!.expiresAt)} (${_remaining(access!.expiresAt!)} left).';
      case 'denied':
        return 'The admin did not approve your last request.';
      case 'expired':
        return 'Your stock access has ended because the time limit passed.';
      default:
        return 'Your stock access has ended${access!.revokedByName == null ? '' : ' — removed by ${access!.revokedByName}'}.';
    }
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: access?.canReceive == true
          ? empSuccessTint
          : access?.status == 'pending'
          ? empWarnTint
          : Colors.white,
      border: Border.all(color: empBorder),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              access?.canReceive == true
                  ? Icons.check_circle_outline
                  : Icons.lock_outline,
              color: access?.canReceive == true ? empSuccess : empMuted,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _label(),
                style: empSans(13.5, weight: FontWeight.w600, color: empInk),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (access?.canReceive == true) ...[
              FilledButton(
                onPressed: onReceive,
                style: empPrimaryButton(height: 42),
                child: const Text('Add stock'),
              ),
              OutlinedButton(onPressed: onDone, child: const Text("I'm done")),
            ] else if (access?.status != 'pending')
              FilledButton(
                onPressed: onRequest,
                style: empPrimaryButton(height: 42),
                child: const Text('Request stock access'),
              ),
          ],
        ),
      ],
    ),
  );
}

String _time(DateTime? value) => value == null
    ? '—'
    : '${value.toLocal().hour.toString().padLeft(2, '0')}:${value.toLocal().minute.toString().padLeft(2, '0')}';
String _remaining(DateTime value) {
  final d = value.difference(DateTime.now());
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inMinutes.clamp(0, 59)}m';
}

class _StockRow extends StatelessWidget {
  final StockItem item;
  final VoidCallback onTap;
  const _StockRow({required this.item, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              item.name,
              style: empSans(13.5, weight: FontWeight.w600, color: empInk),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(item.category, style: empSans(12, color: empMuted)),
          ),
          Expanded(
            child: Text(
              '${empQty(item.quantity)} ${item.unit}',
              style: empSans(13, color: empInk),
            ),
          ),
          Expanded(
            child: Text(
              empMk(item.retailPrice),
              style: empSans(13, color: empInk),
            ),
          ),
          Expanded(child: _status(item)),
        ],
      ),
    ),
  );
}

class _StockCard extends StatelessWidget {
  final StockItem item;
  final VoidCallback onTap;
  const _StockCard({required this.item, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.name,
                  style: empSans(15, weight: FontWeight.w700, color: empInk),
                ),
              ),
              _status(item),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${item.category} · ${item.unit}',
            style: empSans(12, color: empMuted),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '${empQty(item.quantity)} available',
                  style: empSans(13, color: empInk),
                ),
              ),
              Text(
                empMk(item.retailPrice),
                style: empSans(13, weight: FontWeight.w600, color: empInk),
              ),
            ],
          ),
          if (item.prescription) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              color: empWarnTint,
              child: Text(
                'Prescription',
                style: empSans(11, weight: FontWeight.w600, color: empWarn),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

Widget _status(StockItem item) {
  final text = item.isExpired && item.isOut
      ? 'Expired'
      : item.isOut
      ? 'Out'
      : item.isLow
      ? 'Low'
      : 'In stock';
  final color = item.isOut
      ? empDanger
      : item.isLow
      ? empWarn
      : empSuccess;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: empSans(11, weight: FontWeight.w600, color: color),
    ),
  );
}

class _BatchTile extends StatelessWidget {
  final StockBatchDetail batch;
  const _BatchTile({required this.batch});
  @override
  Widget build(BuildContext context) {
    final expiry = batch.expiryDate == null
        ? 'Does not expire'
        : 'Expires ${batch.expiryDate}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: empBg,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Batch ${batch.batchNumber}',
                    style: empSans(13, weight: FontWeight.w600, color: empInk),
                  ),
                  Text(
                    '$expiry · ${empQty(batch.quantity)} left',
                    style: empSans(12, color: empMuted),
                  ),
                ],
              ),
            ),
            Text(
              empMk(batch.retailPrice),
              style: empSans(12.5, weight: FontWeight.w600, color: empInk),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeliveryDraft {
  final String itemId;
  final String itemName;
  final String unit;
  final quantity = TextEditingController();
  final buying = TextEditingController();
  final retail = TextEditingController();
  final wholesale = TextEditingController();
  final batch = TextEditingController();
  DateTime? expiry;
  _DeliveryDraft({
    required this.itemId,
    required this.itemName,
    required this.unit,
  });
  double get total =>
      (double.tryParse(quantity.text) ?? 0) *
      (double.tryParse(buying.text) ?? 0);
  void dispose() {
    quantity.dispose();
    buying.dispose();
    retail.dispose();
    wholesale.dispose();
    batch.dispose();
  }
}

class _ReceiveStockPage extends StatefulWidget {
  final String branchId;
  final StockRepository repo;
  final VoidCallback onDone;
  final VoidCallback onCancel;
  const _ReceiveStockPage({
    required this.branchId,
    required this.repo,
    required this.onDone,
    required this.onCancel,
  });
  @override
  State<_ReceiveStockPage> createState() => _ReceiveStockPageState();
}

class _ReceiveStockPageState extends State<_ReceiveStockPage> {
  final _invoice = TextEditingController();
  final List<_DeliveryDraft> _lines = [];
  List<Map<String, String>> _suppliers = [];
  List<StockItem> _catalog = [];
  String? _supplier;
  DateTime _date = DateTime.now();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _invoice.dispose();
    for (final l in _lines) l.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final r = await Future.wait([
        widget.repo.fetchSuppliers(),
        widget.repo.fetchItems(branchId: widget.branchId),
      ]);
      if (mounted)
        setState(() {
          _suppliers = r[0] as List<Map<String, String>>;
          _catalog = r[1] as List<StockItem>;
        });
    } catch (e) {
      if (mounted) empToast(context, e.toString(), error: true);
    }
  }

  Future<void> _addLine() async {
    final item = await showModalBottomSheet<StockItem>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CatalogPicker(items: _catalog),
    );
    if (item != null)
      setState(
        () => _lines.add(
          _DeliveryDraft(itemId: item.id, itemName: item.name, unit: item.unit),
        ),
      );
  }

  double get _total => _lines.fold(
    0,
    (sum, l) =>
        sum +
        (double.tryParse(l.quantity.text) ?? 0) *
            (double.tryParse(l.buying.text) ?? 0),
  );

  List<Widget> _lineWidgets() => [
    for (int i = 0; i < _lines.length; i++)
      _DeliveryLineCard(
        line: _lines[i],
        onRemove: () {
          final line = _lines.removeAt(i);
          line.dispose();
          setState(() {});
        },
        onChanged: () => setState(() {}),
      ),
  ];

  Future<void> _save() async {
    if (_lines.isEmpty) {
      empToast(context, 'Add at least one item.', error: true);
      return;
    }
    final values = <DeliveryLine>[];
    for (final l in _lines) {
      final qty = double.tryParse(l.quantity.text);
      final buy = double.tryParse(l.buying.text);
      final retail = double.tryParse(l.retail.text);
      if (qty == null ||
          qty <= 0 ||
          buy == null ||
          buy < 0 ||
          retail == null ||
          retail < 0) {
        empToast(
          context,
          'Check the quantity and prices for ${l.itemName}.',
          error: true,
        );
        return;
      }
      if (l.expiry != null &&
          l.expiry!.isBefore(
            DateTime.now().subtract(const Duration(days: 1)),
          )) {
        empToast(context, 'Expiry date cannot be in the past.', error: true);
        return;
      }
      values.add(
        DeliveryLine(
          itemId: l.itemId,
          itemName: l.itemName,
          unit: l.unit,
          quantity: l.quantity.text,
          buyingPrice: l.buying.text,
          retailPrice: l.retail.text,
          wholesalePrice: l.wholesale.text,
          batchNumber: l.batch.text,
          expiryDate: l.expiry,
        ),
      );
    }
    setState(() => _saving = true);
    try {
      await widget.repo.receive(
        branchId: widget.branchId,
        supplierId: _supplier,
        invoiceNumber: _invoice.text,
        purchaseDate: _date,
        lines: values,
      );
      stockChanged.value++;
      if (mounted) {
        empToast(
          context,
          '${values.length} item${values.length == 1 ? '' : 's'} received, total ${empMk(_total)}.',
        );
        widget.onDone();
      }
    } on StockException catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        empToast(context, e.message, error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final form = <Widget>[
      DropdownButtonFormField<String?>(
        value: _supplier,
        decoration: empField('Supplier'),
        items: [
          const DropdownMenuItem(
            value: null,
            child: Text('No supplier / cash buy'),
          ),
          ..._suppliers.map(
            (s) => DropdownMenuItem(value: s['id'], child: Text(s['name']!)),
          ),
        ],
        onChanged: (v) => setState(() => _supplier = v),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _invoice,
        decoration: empField('Invoice number (optional)'),
      ),
      const SizedBox(height: 10),
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Delivery date', style: empSans(13.5, color: empMuted)),
        subtitle: Text(
          '${_date.day} ${_date.month} ${_date.year}',
          style: empSans(14, weight: FontWeight.w600, color: empInk),
        ),
        trailing: const Icon(Icons.calendar_today_outlined),
        onTap: () async {
          final d = await showDatePicker(
            context: context,
            initialDate: _date,
            firstDate: DateTime(2020),
            lastDate: DateTime.now(),
          );
          if (d != null) setState(() => _date = d);
        },
      ),
      const SizedBox(height: 8),
      ..._lineWidgets(),
      OutlinedButton.icon(
        onPressed: _addLine,
        icon: const Icon(Icons.add),
        label: const Text('Add item'),
      ),
    ];
    return Scaffold(
      backgroundColor: empBg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: widget.onCancel,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Expanded(
                    child: Text(
                      'Add stock',
                      style: empSans(
                        21,
                        weight: FontWeight.w700,
                        color: empInk,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 110),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 980),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: form,
                    ),
                  ),
                ),
              ),
            ),
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_lines.length} item${_lines.length == 1 ? '' : 's'} · ${empMk(_total)}',
                      style: empSans(
                        14,
                        weight: FontWeight.w700,
                        color: empInk,
                      ),
                    ),
                  ),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    style: empPrimaryButton(height: 46),
                    child: Text(_saving ? 'Saving…' : 'Add sellable stock'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeliveryLineCard extends StatelessWidget {
  final _DeliveryDraft line;
  final VoidCallback onRemove;
  final VoidCallback onChanged;
  const _DeliveryLineCard({
    required this.line,
    required this.onRemove,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  line.itemName,
                  style: empSans(14, weight: FontWeight.w700, color: empInk),
                ),
              ),
              IconButton(
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline, color: empDanger),
              ),
            ],
          ),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              SizedBox(
                width: 150,
                child: TextField(
                  controller: line.quantity,
                  onChanged: (_) => onChanged(),
                  keyboardType: TextInputType.number,
                  decoration: empField('Quantity'),
                ),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  controller: line.buying,
                  onChanged: (_) => onChanged(),
                  keyboardType: TextInputType.number,
                  decoration: empField('Buying price'),
                ),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  controller: line.retail,
                  keyboardType: TextInputType.number,
                  decoration: empField('Retail price'),
                ),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  controller: line.wholesale,
                  keyboardType: TextInputType.number,
                  decoration: empField('Wholesale (optional)'),
                ),
              ),
              SizedBox(
                width: 170,
                child: TextField(
                  controller: line.batch,
                  decoration: empField('Batch number'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                line.expiry == null
                    ? 'No expiry date'
                    : 'Expires ${line.expiry!.day}/${line.expiry!.month}/${line.expiry!.year}',
                style: empSans(12.5, color: empMuted),
              ),
              const Spacer(),
              Text(
                empMk(line.total),
                style: empSans(13, weight: FontWeight.w700, color: empInk),
              ),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: line.expiry ?? DateTime.now(),
                    firstDate: DateTime.now(),
                    lastDate: DateTime(2100),
                  );
                  if (d != null) {
                    line.expiry = d;
                    onChanged();
                  }
                },
                child: const Text('Set expiry'),
              ),
            ],
          ),
          if ((double.tryParse(line.retail.text) ?? 0) <
              (double.tryParse(line.buying.text) ?? 0))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Retail price is below buying price.',
                style: empSans(12, color: empWarn),
              ),
            ),
        ],
      ),
    ),
  );
}

class _CatalogPicker extends StatefulWidget {
  final List<StockItem> items;
  const _CatalogPicker({required this.items});
  @override
  State<_CatalogPicker> createState() => _CatalogPickerState();
}

class _CatalogPickerState extends State<_CatalogPicker> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final rows = widget.items
        .where((i) => i.name.toLowerCase().contains(q.toLowerCase()))
        .toList();
    return EmpSheetFrame(
      title: 'Add catalog item',
      child: Column(
        children: [
          TextField(
            onChanged: (v) => setState(() => q = v),
            decoration: empField('Search item'),
          ),
          const SizedBox(height: 8),
          for (final item in rows.take(30))
            ListTile(
              title: Text(item.name),
              subtitle: Text('${item.category} · ${item.unit}'),
              onTap: () => Navigator.pop(context, item),
            ),
        ],
      ),
    );
  }
}
