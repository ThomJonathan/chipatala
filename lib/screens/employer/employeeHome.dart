import 'package:flutter/material.dart';

import '../../appUser.dart';
import '../../widgets/employeeShell.dart';
import 'employeeHomeRepo.dart';
import 'employeeUi.dart';
import 'expenseScreen.dart';

// ============================================================================
// EMPLOYEE HOME — first screen for branch staff (cashier-first).
//   Read-only apart from its shortcuts and expense recording. Everything
//   is live and limited to the user's own branch. Cashiers never see
//   profit, buying prices, other branches or suppliers — those are simply
//   not queried. Branch expenses can be recorded here and viewed under
//   the desktop Expenses tab.
//
//   Role variations: stock_controller gets Receive stock +
//   recent movements; manager gets the cashier layout + profit/expenses.
//
//   Lives inside EmployeeShell's IndexedStack, so the bottom nav (mobile)
//   and side rail (desktop) stay visible — details open in sheets/dialogs.
//   Numbers reload whenever Home is re-selected, plus pull-to-refresh.
// ============================================================================

class EmployeeHomeScreen extends StatefulWidget {
  final AppUser user;
  final String branchName;
  const EmployeeHomeScreen({
    super.key,
    required this.user,
    required this.branchName,
  });

  @override
  State<EmployeeHomeScreen> createState() => _EmployeeHomeScreenState();
}

String _greeting() {
  final h = DateTime.now().hour;
  if (h < 12) return 'Good morning';
  if (h < 17) return 'Good afternoon';
  return 'Good evening';
}

String _todayLabel() {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = [
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
  final n = DateTime.now();
  return '${days[n.weekday - 1]} ${n.day} ${months[n.month - 1]} ${n.year}';
}

String _timeLabel(String iso) {
  try {
    final d = DateTime.parse(iso).toLocal();
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  } catch (_) {
    return '';
  }
}

String _methodLabel(String m) {
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

Future<T?> _showEmpSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
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
          child: builder(ctx),
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

class _EmployeeHomeScreenState extends State<EmployeeHomeScreen> {
  final _repo = EmployeeHomeRepository();
  final _lookupCtrl = TextEditingController();

  bool _loading = true;
  String? _error;
  EmployeeHomeBundle? _data;
  bool _loadedOnce = false;
  bool _wasSelected = false;

  String _lookupQuery = '';
  List<LookupItem> _lookupResults = [];
  bool _lookupLoading = false;

  bool get _isStock => widget.user.role == 'stock_controller';
  bool get _isManager => widget.user.role == 'manager';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _lookupCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload whenever the user returns to Home (IndexedStack keeps us alive).
    final selected = EmployeeShellScope.of(context)?.selectedIndex == 0;
    if (selected && !_wasSelected && _loadedOnce) _load(silent: true);
    _wasSelected = selected;
  }

  Future<void> _load({bool silent = false}) async {
    final branchId = widget.user.branchId;
    if (branchId == null) {
      setState(() {
        _loading = false;
        _error = 'No branch assigned to this account yet. Ask your admin to assign one.';
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
      final data = await _repo.fetchHome(
        branchId: branchId,
        role: widget.user.role,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
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

  Future<void> _runLookup(String q) async {
    setState(() {
      _lookupQuery = q;
      _lookupLoading = q.trim().length >= 2;
      if (q.trim().length < 2) _lookupResults = [];
    });
    if (q.trim().length < 2) return;
    final branchId = widget.user.branchId;
    if (branchId == null) return;
    try {
      final res = await _repo.lookup(branchId: branchId, query: q);
      if (!mounted) return;
      // Drop stale responses.
      if (_lookupCtrl.text != q) return;
      setState(() {
        _lookupResults = res;
        _lookupLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      if (_lookupCtrl.text != q) return;
      setState(() => _lookupLoading = false);
    }
  }

  Future<void> _openReceipt(RecentSale s) async {
    await _showEmpSheet<void>(
      context,
      builder: (_) => EmpSheetFrame(
        title: 'Receipt ${s.receipt}',
        subtitle: '${_timeLabel(s.time)} · ${_methodLabel(s.method)}',
        child: FutureBuilder<Receipt>(
          future: _repo.receipt(s.id),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                  child: CircularProgressIndicator(color: empPrimary),
                ),
              );
            }
            if (snap.hasError || !snap.hasData) {
              return Text(
                'Couldn’t load the receipt.',
                style: empSans(13.5, color: empDanger),
              );
            }
            final r = snap.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final l in r.lines)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l.itemName,
                                style: empSans(
                                  13.5,
                                  weight: FontWeight.w600,
                                  color: empInk,
                                ),
                              ),
                              Text(
                                '${empQty(l.qty)} × ${empMk(l.unitPrice)}',
                                style: empSans(12, color: empMuted),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          empMk(l.subtotal),
                          style: empMono(
                            13,
                            weight: FontWeight.w600,
                            color: empInk,
                          ),
                        ),
                      ],
                    ),
                  ),
                const Divider(color: empBorder),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Total',
                        style: empSans(
                          14,
                          weight: FontWeight.w700,
                          color: empInk,
                        ),
                      ),
                    ),
                    Text(
                      empMk(r.total),
                      style: empMono(
                        15,
                        weight: FontWeight.w700,
                        color: empInk,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Paid ${empMk(r.paid)}${r.cashier.isNotEmpty ? ' · ${r.cashier}' : ''}',
                  style: empSans(12, color: empMuted),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _openPaymentSheet() async {
    final branchId = widget.user.branchId;
    if (branchId == null) return;
    final done = await _showEmpSheet<bool>(
      context,
      builder: (_) => _PaymentSheet(repo: _repo, branchId: branchId),
    );
    if (done == true && mounted) {
      await _load(silent: true);
      if (mounted) empToast(context, 'Payment recorded.');
    }
  }

  // ---- Build -------------------------------------------------------------------

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
              final tablet = !wide && c.maxWidth >= empTabletBreakpoint;
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  wide ? 32 : 18,
                  wide ? 28 : 14,
                  wide ? 32 : 18,
                  24,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: _body(wide, tablet),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _body(bool wide, bool tablet) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 90),
        child: Center(child: CircularProgressIndicator(color: empPrimary)),
      );
    }
    if (_error != null || _data == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 60),
        child: EmpCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Couldn’t load Home',
                style: empSans(15, weight: FontWeight.w700, color: empInk),
              ),
              const SizedBox(height: 6),
              Text(
                _error ?? 'Something went wrong.',
                style: empSans(13, color: empMuted),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: _load,
                style: empPrimaryButton(height: 44),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final d = _data!;

    final greeting = _Greeting(
      userName: widget.user.fullName,
      branchName: widget.branchName,
      role: widget.user.role,
    );
    final action = _MainAction(
      isStock: _isStock,
      branchId: widget.user.branchId,
      onExpenseSaved: () => _load(silent: true),
    );
    final summary = _SummaryBlock(
      data: d,
      tablet: tablet,
      showManagerExtras: _isManager,
    );
    final lookup = _LookupBlock(
      controller: _lookupCtrl,
      loading: _lookupLoading,
      query: _lookupQuery,
      results: _lookupResults,
      onChanged: _runLookup,
    );
    final recent = _isStock
        ? _MovementsBlock(moves: d.recentMoves)
        : _RecentSalesBlock(sales: d.recentSales, onTap: _openReceipt);
    final owing = _OwingBlock(
      data: d,
      onPay: _openPaymentSheet,
      onOpenReports: () => EmployeeShell.switchTo(context, 3),
    );

    if (wide) {
      // Desktop: greeting across the top; two columns below.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          greeting,
          const SizedBox(height: 18),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      action,
                      const SizedBox(height: 14),
                      summary,
                      const SizedBox(height: 14),
                      recent,
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      lookup,
                      const SizedBox(height: 14),
                      owing,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // Mobile + tablet: one column in thumb-friendly order.
    final blocks = <Widget>[
      greeting,
      const SizedBox(height: 16),
      action,
      const SizedBox(height: 14),
      summary,
      const SizedBox(height: 14),
      lookup,
      const SizedBox(height: 14),
      recent,
      const SizedBox(height: 14),
      owing,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: blocks,
    );
  }
}

// ============================================================================
// GREETING + MAIN ACTION
// ============================================================================

class _Greeting extends StatelessWidget {
  final String userName;
  final String branchName;
  final String role;
  const _Greeting({
    required this.userName,
    required this.branchName,
    required this.role,
  });

  String get _roleLabel {
    switch (role) {
      case 'stock_controller':
        return 'Stock controller';
      case 'cashier':
        return 'Cashier';
      case 'manager':
        return 'Manager';
      case 'admin':
        return 'Admin';
      default:
        return role;
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = userName.trim().isEmpty
        ? 'there'
        : userName.trim().split(' ').first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_greeting()}, $first',
          style: empSans(22, weight: FontWeight.w700, color: empInk),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            const Icon(Icons.storefront_outlined, size: 14, color: empMuted),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                '${branchName.isEmpty ? 'Your branch' : branchName} · $_roleLabel · ${_todayLabel()}',
                style: empSans(12.5, color: empMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MainAction extends StatelessWidget {
  final bool isStock;
  final String? branchId;
  final VoidCallback onExpenseSaved;
  const _MainAction({
    required this.isStock,
    required this.branchId,
    required this.onExpenseSaved,
  });

  Future<void> _newExpense(BuildContext context) async {
    final bid = branchId;
    if (bid == null) {
      empToast(context, 'No branch assigned to this account yet.', error: true);
      return;
    }
    final saved = await showRecordExpenseSheet(context, branchId: bid);
    if (saved == true && context.mounted) {
      onExpenseSaved();
      empToast(context, 'Expense recorded.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: FilledButton.icon(
              onPressed: () =>
                  EmployeeShell.switchTo(context, isStock ? 2 : 1),
              style: empPrimaryButton(height: 54),
              icon: Icon(
                isStock ? Icons.add_box_outlined : Icons.point_of_sale_outlined,
                size: 20,
              ),
              label: Text(isStock ? 'Receive stock' : 'New sale'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: OutlinedButton.icon(
              onPressed: () => _newExpense(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: empPrimary,
                minimumSize: const Size(0, 54),
                side: const BorderSide(color: empBorder),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: const Icon(Icons.add_card_outlined, size: 19),
              label: const Text('New expense'),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// SUMMARY (today's branch figures — no profit or buying prices for cashiers)
// ============================================================================

class _SummaryBlock extends StatelessWidget {
  final EmployeeHomeBundle data;
  final bool tablet;
  final bool showManagerExtras;
  const _SummaryBlock({
    required this.data,
    required this.tablet,
    required this.showManagerExtras,
  });

  @override
  Widget build(BuildContext context) {
    final count = _StatCard(
      label: 'Sales today',
      value: '${data.salesCount}',
      sub: data.salesCount == 1 ? 'sale' : 'sales',
      icon: Icons.receipt_long_outlined,
    );
    final total = _StatCard(
      label: 'Total sales',
      value: empMk(data.salesTotal),
      sub: 'today',
      icon: Icons.payments_outlined,
      money: true,
    );
    final splitCard = EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _splitRow('Cash', data.cashTotal),
          _splitRow('Airtel Money', data.airtelTotal),
          _splitRow('TNM Mpamba', data.mpambaTotal),
          if (data.mobileTotal > 0)
            _splitRow('Mobile money (old)', data.mobileTotal),
          _splitRow('Credit', data.creditTotal),
          if (data.cardTotal > 0) _splitRow('Card', data.cardTotal),
        ],
      ),
    );

    final main = tablet
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: count),
              const SizedBox(width: 10),
              Expanded(child: total),
              const SizedBox(width: 10),
              Expanded(child: splitCard),
            ],
          )
        : Column(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: count),
                  const SizedBox(width: 10),
                  Expanded(child: total),
                ],
              ),
              const SizedBox(height: 10),
              splitCard,
            ],
          );

    if (!showManagerExtras) return main;
    return Column(
      children: [
        main,
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _StatCard(
                label: 'Gross profit today',
                value: empMk(data.grossToday),
                sub: 'branch',
                icon: Icons.trending_up_outlined,
                money: true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _StatCard(
                label: 'Expenses today',
                value: empMk(data.expensesToday),
                sub: 'branch',
                icon: Icons.receipt_outlined,
                money: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _splitRow(String label, double amount) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: empSans(12.5, color: empMuted)),
          ),
          Text(
            empMk(amount),
            style: empMono(12.5, weight: FontWeight.w600, color: empInk),
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final IconData icon;
  final bool money;
  const _StatCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    this.money = false,
  });

  @override
  Widget build(BuildContext context) {
    return EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: empPrimary),
          const SizedBox(height: 8),
          Text(
            value,
            style: money
                ? empMono(17, weight: FontWeight.w700, color: empInk)
                : empSans(22, weight: FontWeight.w700, color: empInk),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: empSans(12, weight: FontWeight.w600, color: empMuted),
          ),
          Text(sub, style: empSans(10.5, color: empMuted)),
        ],
      ),
    );
  }
}

// ============================================================================
// QUICK ITEM LOOKUP (prices + availability, no sale started)
// ============================================================================

class _LookupBlock extends StatelessWidget {
  final TextEditingController controller;
  final bool loading;
  final String query;
  final List<LookupItem> results;
  final ValueChanged<String> onChanged;
  const _LookupBlock({
    required this.controller,
    required this.loading,
    required this.query,
    required this.results,
    required this.onChanged,
  });

  String _price(double min, double max) =>
      (min == max) ? empMk(min) : '${empMk(min)} – ${empMk(max)}';

  @override
  Widget build(BuildContext context) {
    final q = query.trim();
    return EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Quick lookup',
            style: empSans(13.5, weight: FontWeight.w700, color: empInk),
          ),
          const SizedBox(height: 2),
          Text(
            'Prices and availability — no sale started.',
            style: empSans(11.5, color: empMuted),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            onChanged: onChanged,
            style: empSans(14, color: empInk),
            textInputAction: TextInputAction.search,
            decoration: empField('Type a drug name…').copyWith(
              prefixIcon: const Icon(Icons.search, size: 20, color: empMuted),
              suffixIcon: q.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18, color: empMuted),
                      onPressed: () {
                        controller.clear();
                        onChanged('');
                      },
                    ),
            ),
          ),
          if (loading) ...[
            const SizedBox(height: 12),
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: empPrimary,
                ),
              ),
            ),
          ] else if (q.length >= 2) ...[
            const SizedBox(height: 8),
            if (results.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No items found for “$q”.',
                  style: empSans(12.5, color: empMuted),
                ),
              )
            else
              for (final r in results)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              r.name,
                              style: empSans(
                                13.5,
                                weight: FontWeight.w600,
                                color: empInk,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Retail ${_price(r.retailMin, r.retailMax)}'
                              '${r.wholesaleMin != null ? ' · Wholesale ${_price(r.wholesaleMin!, r.wholesaleMax!)}' : ''}',
                              style: empSans(12, color: empMuted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: empPrimaryTint,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text(
                          '${empQty(r.qty)} left',
                          style: empSans(
                            11.5,
                            weight: FontWeight.w700,
                            color: empPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ],
      ),
    );
  }
}

// ============================================================================
// RECENT SALES + RECEIPT
// ============================================================================

class _RecentSalesBlock extends StatelessWidget {
  final List<RecentSale> sales;
  final ValueChanged<RecentSale> onTap;
  const _RecentSalesBlock({required this.sales, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent sales',
          style: empSans(13.5, weight: FontWeight.w700, color: empInk),
        ),
        const SizedBox(height: 8),
        if (sales.isEmpty)
          const EmpEmpty(
            icon: Icons.point_of_sale_outlined,
            message: 'No sales yet today. Tap New sale to start.',
          )
        else
          EmpCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: List.generate(sales.length, (i) {
                final s = sales[i];
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(
                      i == 0 || i == sales.length - 1 ? 12 : 0,
                    ),
                    onTap: () => onTap(s),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        border: i == sales.length - 1
                            ? null
                            : const Border(
                                bottom: BorderSide(color: empBorder),
                              ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  s.receipt,
                                  style: empSans(
                                    13,
                                    weight: FontWeight.w600,
                                    color: empInk,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${_timeLabel(s.time)} · ${s.itemCount} ${s.itemCount == 1 ? 'item' : 'items'} · ${_methodLabel(s.method)}',
                                  style: empSans(11.5, color: empMuted),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            empMk(s.total),
                            style: empMono(
                              13,
                              weight: FontWeight.w700,
                              color: empInk,
                            ),
                          ),
                          const SizedBox(width: 4),
                          const Icon(
                            Icons.chevron_right,
                            size: 17,
                            color: empMuted,
                          ),
                        ],
                      ),
                    ),
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
// RECENT MOVEMENTS (stock controller instead of recent sales)
// ============================================================================

class _MovementsBlock extends StatelessWidget {
  final List<BranchMove> moves;
  const _MovementsBlock({required this.moves});

  String _label(String t) {
    switch (t) {
      case 'purchase_in':
        return 'Received';
      case 'sale_out':
        return 'Sold';
      case 'adjustment_out':
        return 'Adjusted out';
      case 'adjustment_in':
        return 'Adjusted in';
      case 'opening_stock':
        return 'Opening';
      default:
        return t;
    }
  }

  bool _isOut(String t) => t == 'sale_out' || t == 'adjustment_out';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent stock movements',
          style: empSans(13.5, weight: FontWeight.w700, color: empInk),
        ),
        const SizedBox(height: 8),
        if (moves.isEmpty)
          const EmpEmpty(
            icon: Icons.swap_horiz_outlined,
            message: 'No stock movements recorded yet.',
          )
        else
          EmpCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: List.generate(moves.length, (i) {
                final m = moves[i];
                final out = _isOut(m.type);
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    border: i == moves.length - 1
                        ? null
                        : const Border(bottom: BorderSide(color: empBorder)),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.itemName,
                              style: empSans(
                                13,
                                weight: FontWeight.w600,
                                color: empInk,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_label(m.type)} · ${_timeLabel(m.time)}',
                              style: empSans(11.5, color: empMuted),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${out ? '−' : '+'}${empQty(m.qty)}',
                        style: empMono(
                          13,
                          weight: FontWeight.w700,
                          color: out ? empDanger : empSuccess,
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
// CUSTOMERS OWING + RECORD PAYMENT
// ============================================================================

class _OwingBlock extends StatelessWidget {
  final EmployeeHomeBundle data;
  final VoidCallback onPay;
  final VoidCallback onOpenReports;
  const _OwingBlock({
    required this.data,
    required this.onPay,
    required this.onOpenReports,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onOpenReports,
      borderRadius: BorderRadius.circular(12),
      child: EmpCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: empPrimaryTint,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.people_outline,
                    size: 19,
                    color: empPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        data.owingCount == 0
                            ? 'No outstanding balances'
                            : '${data.owingCount} ${data.owingCount == 1 ? 'customer owes' : 'customers owe'} ${empMk(data.owingTotal)}',
                        style: empSans(
                          13.5,
                          weight: FontWeight.w700,
                          color: empInk,
                        ),
                      ),
                      Text(
                        'Customer debts at this branch',
                        style: empSans(11.5, color: empMuted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (data.owingCount > 0) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: onPay,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: empPrimary,
                    minimumSize: const Size(0, 44),
                    side: const BorderSide(color: empBorder),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  icon: const Icon(Icons.payments_outlined, size: 18),
                  label: const Text('Record payment'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PaymentSheet extends StatefulWidget {
  final EmployeeHomeRepository repo;
  final String branchId;
  const _PaymentSheet({required this.repo, required this.branchId});

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  List<OwingCustomer> _customers = [];
  String? _customerId;
  final _amountCtrl = TextEditingController();
  String _method = 'cash';
  bool _loading = true;
  bool _saving = false;
  String? _formError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await widget.repo.owingCustomers(branchId: widget.branchId);
      if (!mounted) return;
      setState(() {
        _customers = list;
        _loading = false;
        if (list.isNotEmpty) {
          _customerId = list.first.id;
          _amountCtrl.text = list.first.balance.toStringAsFixed(0);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      Navigator.of(context).pop();
    }
  }

  void _onCustomer(String? id) {
    setState(() => _customerId = id);
    final c = _customers.where((x) => x.id == id).toList();
    if (c.isNotEmpty) _amountCtrl.text = c.first.balance.toStringAsFixed(0);
  }

  Future<void> _submit() async {
    if (_customerId == null) {
      setState(() => _formError = 'Pick a customer first.');
      return;
    }
    final amount = double.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _formError = 'Enter an amount above zero.');
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await widget.repo.recordPayment(
        branchId: widget.branchId,
        customerId: _customerId!,
        amount: amount,
        method: _method,
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
    return EmpSheetFrame(
      title: 'Record payment',
      subtitle: 'A customer paying down their balance.',
      child: _loading
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: CircularProgressIndicator(color: empPrimary),
              ),
            )
          : Column(
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
                    child: DropdownButton<String>(
                      value: _customerId,
                      isExpanded: true,
                      style: empSans(14, color: empInk),
                      items: [
                        for (final c in _customers)
                          DropdownMenuItem(
                            value: c.id,
                            child: Text('${c.name} · owes ${empMk(c.balance)}'),
                          ),
                      ],
                      onChanged: _onCustomer,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: empSans(14, color: empInk),
                  decoration: empField('Amount (MK)'),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: empBorder),
                    borderRadius: BorderRadius.circular(10),
                    color: Colors.white,
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _method,
                      isExpanded: true,
                      style: empSans(14, color: empInk),
                      items: const [
                        DropdownMenuItem(value: 'cash', child: Text('Cash')),
                        DropdownMenuItem(
                          value: 'airtel_money',
                          child: Text('Airtel Money'),
                        ),
                        DropdownMenuItem(
                          value: 'tnm_mpamba',
                          child: Text('TNM Mpamba'),
                        ),
                        DropdownMenuItem(value: 'card', child: Text('Card')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _method = v);
                      },
                    ),
                  ),
                ),
                if (_formError != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _formError!,
                    style: empSans(
                      12.5,
                      weight: FontWeight.w600,
                      color: empDanger,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _saving ? null : _submit,
                  style: empPrimaryButton(),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Save payment'),
                ),
              ],
            ),
    );
  }
}
