import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../appUser.dart';
import 'employeeUi.dart';
import 'receipt.dart';
import 'saleRepo.dart';
import 'reportsRepo.dart';

class EmployeeReportsScreen extends StatefulWidget {
  final AppUser user;
  const EmployeeReportsScreen({super.key, required this.user});
  @override
  State<EmployeeReportsScreen> createState() => _EmployeeReportsScreenState();
}

class _EmployeeReportsScreenState extends State<EmployeeReportsScreen> {
  final _repo = EmployeeReportsRepository();
  final _search = TextEditingController();
  EmployeeReportPeriod _period = EmployeeReportPeriod.month();
  EmployeeReportData? _data;
  bool _loading = true;
  String? _error;
  int _tab = 0;
  bool _bySales = false;
  String get _branchId => widget.user.branchId!;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await _repo.fetch(branchId: _branchId, period: _period);
      if (mounted) {
        setState(() {
          _data = value;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  String _money(double v) =>
      'MK ${v.round().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},')}';
  String _time(String raw) {
    final d = DateTime.tryParse(raw)?.toLocal();
    return d == null
        ? '—'
        : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _choosePeriod() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('Today'),
              onTap: () => Navigator.pop(ctx, 'today'),
            ),
            ListTile(
              title: const Text('This month'),
              onTap: () => Navigator.pop(ctx, 'month'),
            ),
            ListTile(
              title: const Text('Choose a date'),
              onTap: () => Navigator.pop(ctx, 'date'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'today') _period = EmployeeReportPeriod.today();
    if (choice == 'month') _period = EmployeeReportPeriod.month();
    if (choice == 'date' && mounted) {
      final d = await showDatePicker(
        context: context,
        firstDate: DateTime(2020),
        lastDate: DateTime.now(),
        initialDate: DateTime.now(),
      );
      if (d != null) _period = EmployeeReportPeriod.day(d);
    }
    if (choice != null) await _load();
  }

  Future<void> _receipt(EmployeeReportSale sale) async {
    try {
      final receipt = await SaleRepository().getReceipt(sale.id);
      await ReceiptService.printReceipt(receipt);
    } catch (e) {
      if (mounted) empToast(context, e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: empBg,
      body: RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 30),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Reports',
                          style: empSans(
                            22,
                            weight: FontWeight.w700,
                            color: empInk,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _choosePeriod,
                        icon: const Icon(
                          Icons.calendar_today_outlined,
                          size: 17,
                        ),
                        label: Text(_period.label),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (_loading)
                    const Padding(
                      padding: EdgeInsets.all(50),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_error != null)
                    EmpCard(
                      child: Text(
                        _error!,
                        style: empSans(13, color: empDanger),
                      ),
                    )
                  else if (d != null) ...[
                    _summary(d),
                    const SizedBox(height: 14),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _tabChip('Sales', 0),
                          _tabChip('Best sellers', 1),
                          _tabChip('Owing money', 2),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (_tab == 0)
                      _sales(d)
                    else if (_tab == 1)
                      _best(d)
                    else
                      _debts(d),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tabChip(String label, int value) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: _tab == value,
      onSelected: (_) => setState(() => _tab = value),
    ),
  );
  Widget _summary(EmployeeReportData d) => Row(
    children: [
      Expanded(
        child: EmpCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sales', style: empSans(12, color: empMuted)),
              const SizedBox(height: 5),
              Text(
                '${d.sales.length}',
                style: empMono(21, weight: FontWeight.w700, color: empInk),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: EmpCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Total', style: empSans(12, color: empMuted)),
              const SizedBox(height: 5),
              Text(
                _money(d.total),
                style: empMono(18, weight: FontWeight.w700, color: empPrimary),
              ),
            ],
          ),
        ),
      ),
    ],
  );
  Widget _sales(EmployeeReportData d) {
    final points = <FlSpot>[];
    for (var i = 0; i < d.sales.length; i++) {
      points.add(FlSpot(i.toDouble(), d.sales[d.sales.length - i - 1].total));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (points.isNotEmpty)
          SizedBox(
            height: 180,
            child: LineChart(
              LineChartData(
                lineBarsData: [
                  LineChartBarData(
                    spots: points,
                    isCurved: true,
                    color: empPrimary,
                    dotData: const FlDotData(show: false),
                  ),
                ],
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                gridData: const FlGridData(show: false),
              ),
            ),
          ),
        const SizedBox(height: 10),
        for (final sale in d.sales)
          Card(
            child: ListTile(
              onTap: () => _receipt(sale),
              leading: Text(_time(sale.time)),
              title: Text(sale.receipt),
              subtitle: Text('${sale.cashier} · ${sale.method}'),
              trailing: Text(_money(sale.total)),
            ),
          ),
      ],
    );
  }

  Widget _best(EmployeeReportData d) {
    final rows = d.sellers.toList()
      ..sort(
        (a, b) => _bySales
            ? b.sales.compareTo(a.sales)
            : b.quantity.compareTo(a.quantity),
      );
    return Column(
      children: [
        Row(
          children: [
            const Text('Rank by'),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('Quantity'),
              selected: !_bySales,
              onSelected: (_) => setState(() => _bySales = false),
            ),
            const SizedBox(width: 6),
            ChoiceChip(
              label: const Text('Sales'),
              selected: _bySales,
              onSelected: (_) => setState(() => _bySales = true),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final x in rows)
          Card(
            child: ListTile(
              title: Text(x.name),
              subtitle: Text('${x.sales} separate sales'),
              trailing: Text(
                '${x.quantity % 1 == 0 ? x.quantity.toInt() : x.quantity} sold',
              ),
            ),
          ),
      ],
    );
  }

  Widget _debts(EmployeeReportData d) {
    final q = _search.text.toLowerCase();
    final rows = d.debts
        .where((x) => x.name.toLowerCase().contains(q))
        .toList();
    return Column(
      children: [
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: empField('Search customers'),
        ),
        const SizedBox(height: 10),
        if (rows.isEmpty)
          const EmpEmpty(
            icon: Icons.check_circle_outline,
            message: 'No customers owe money.',
          )
        else
          ...rows.map(
            (x) => Card(
              child: ListTile(
                title: Text(x.name),
                subtitle: const Text('Outstanding balance'),
                trailing: Text(
                  _money(x.balance),
                  style: empSans(13, weight: FontWeight.w700, color: empDanger),
                ),
                onTap: () => _customer(x),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _customer(EmployeeDebt debt) async {
    final history = await _repo.payments(debt.id);
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => EmpSheetFrame(
        title: debt.name,
        subtitle: 'Owes ${_money(debt.balance)}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final p in history)
              ListTile(
                title: Text(_money(p.amount)),
                subtitle: Text('${p.method} · ${p.date}'),
              ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () async {
                final amount = await _paymentDialog(debt);
                if (amount == null) return;
                await _load();
              },
              style: empPrimaryButton(),
              child: const Text('Record payment'),
            ),
          ],
        ),
      ),
    );
  }

  Future<double?> _paymentDialog(EmployeeDebt debt) async {
    final ctrl = TextEditingController();
    String method = 'cash';
    final amount = await showDialog<double>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Record payment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Balance: ${_money(debt.balance)}'),
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Amount'),
              ),
              DropdownButton<String>(
                value: method,
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
                onChanged: (v) => set(() => method = v!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final v = double.tryParse(ctrl.text);
                if (v == null || v <= 0 || v > debt.balance) return;
                await _repo.recordPayment(
                  branchId: _branchId,
                  customerId: debt.id,
                  amount: v,
                  method: method,
                );
                if (ctx.mounted) Navigator.pop(ctx, v);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    return amount;
  }
}
