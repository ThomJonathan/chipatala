import 'dart:convert';
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'adminui.dart';
import 'reportsRepo.dart';

// ============================================================================
// ADMIN REPORTS — read-only performance + debts. Nothing is entered here;
// every figure is computed live from sales, sale_items, expenses, payments.
//
// Embedded page inside AdminShell (nav bars stay visible — only sheets,
// dialogs and the share panel ever open). Filter bar (branch + period)
// scopes every tab except Debts balances, which are always current.
// Build order followed: period selector + Sales, then Profit, Best sellers,
// Expenses, Debts with payment histories — each in both layouts.
// ============================================================================

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

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

String _compact(double v) {
  final a = v.abs();
  if (a >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
  if (a >= 10000) return '${(v / 1000).toStringAsFixed(0)}k';
  if (a >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return v.round().toString();
}

String _fmtQty(double q) => q.toStringAsFixed(q.truncateToDouble() == q ? 0 : 2);

String _fmtDate(String? raw) {
  if (raw == null || raw.isEmpty) return '—';
  try {
    final d = DateTime.parse(raw).toLocal();
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${m[d.month - 1]} ${d.year}';
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

enum _BestRank { qty, revenue, profit, times }

class _ReportsScreenState extends State<ReportsScreen> {
  final _repo = ReportsRepository();
  final _debtSearchCtrl = TextEditingController();

  List<ReportBranch> _branches = [];
  String? _branchId; // null = all branches
  ReportPeriod _period = ReportPeriod.month();
  int _tab = 0;
  _BestRank _rankBy = _BestRank.qty;
  String _debtSearch = '';

  bool _loading = true;
  String? _error;
  PeriodBundle _bundle = PeriodBundle.empty;
  List<CustomerDebt> _customers = [];
  List<SupplierDebt> _suppliers = [];

  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debtSearchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final branches = await _repo.fetchBranches();
      final names = {for (final b in branches) b.id: b.name};
      final results = await Future.wait([
        _repo.fetchPeriodData(branchId: _branchId, period: _period),
        _repo.fetchDebts(branchId: _branchId, branchNames: names),
      ]);
      if (!mounted) return;
      setState(() {
        _branches = branches;
        _bundle = results[0] as PeriodBundle;
        final debts = results[1] as ({List<CustomerDebt> customers, List<SupplierDebt> suppliers});
        _customers = debts.customers;
        _suppliers = debts.suppliers;
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

  String get _scopeName {
    if (_branchId == null) return 'All branches';
    return _branches.where((b) => b.id == _branchId).map((b) => b.name).join();
  }

  // ---- Derived figures -------------------------------------------------------

  double get _revenue => _bundle.sales.fold(0.0, (s, r) => s + r.totalAmount);
  double get _gross => _bundle.saleItems.fold(0.0, (s, r) => s + r.profit);
  double get _expenses => _bundle.expenses.fold(0.0, (s, r) => s + r.amount);
  double get _net => _gross - _expenses;

  Map<String, String> get _branchNames => {for (final b in _branches) b.id: b.name};

  // ---- Filter actions ----------------------------------------------------------

  Future<void> _onBranchChanged(String? id) async {
    if (id == _branchId) return;
    setState(() => _branchId = id);
    await _load();
  }

  Future<void> _pickPeriod(String value) async {
    final now = DateTime.now();
    switch (value) {
      case 'today':
        setState(() => _period = ReportPeriod.today());
      case 'week':
        setState(() => _period = ReportPeriod.week());
      case 'month':
        setState(() => _period = ReportPeriod.month());
      case 'year':
        setState(() => _period = ReportPeriod.year());
      case 'day':
        final d = await showDatePicker(
          context: context,
          initialDate: now,
          firstDate: DateTime(2020),
          lastDate: now,
        );
        if (d == null) return;
        setState(() => _period = ReportPeriod.singleDay(d));
      case 'custom':
        final r = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2020),
          lastDate: now,
          initialDateRange: DateTimeRange(start: now.subtract(const Duration(days: 29)), end: now),
        );
        if (r == null) return;
        setState(() => _period = ReportPeriod.custom(r.start, r.end));
      case 'y2':
        setState(() => _period = ReportPeriod.lastYears(2));
      case 'y3':
        setState(() => _period = ReportPeriod.lastYears(3));
      case 'y5':
        setState(() => _period = ReportPeriod.lastYears(5));
      case 'y7':
        setState(() => _period = ReportPeriod.lastYears(7));
      case 'yCustom':
        final n = await _askYears();
        if (n == null) return;
        setState(() => _period = ReportPeriod.lastYears(n));
      default:
        return;
    }
    await _load();
  }

  String get _periodValue {
    switch (_period.type) {
      case ReportPeriodType.today:
        return 'today';
      case ReportPeriodType.week:
        return 'week';
      case ReportPeriodType.month:
        return 'month';
      case ReportPeriodType.year:
        return 'year';
      case ReportPeriodType.day:
        return 'day';
      case ReportPeriodType.custom:
        return 'custom';
      case ReportPeriodType.lastYears:
        switch (_period.years) {
          case 2:
            return 'y2';
          case 3:
            return 'y3';
          case 5:
            return 'y5';
          case 7:
            return 'y7';
          default:
            return 'yCustom';
        }
    }
  }

  Future<int?> _askYears() async {
    final ctrl = TextEditingController(text: '4');
    return showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('How many years?', style: sans(16, weight: FontWeight.w700, color: kInk)),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          style: sans(15, color: kInk),
          decoration: fieldDecoration('Number of years', hint: 'e.g. 4'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('Cancel', style: sans(13.5, weight: FontWeight.w600, color: kInkMuted)),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(ctrl.text.trim());
              if (n == null || n < 1 || n > 30) return;
              Navigator.of(ctx).pop(n);
            },
            style: primaryButtonStyle(height: 40),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  // ---- Exports -----------------------------------------------------------------

  String _fileBase(String tab) {
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'chipatala_${tab}_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
  }

  /// Builds the CSV for the current tab (shared by CSV + PDF exports).
  ({String tab, String title, List<String> headers, List<List<String>> rows, List<String> summary}) _buildExport() {
    final branchSales = aggregateBranchSales(_bundle.sales);
    switch (_tab) {
      case 0:
        return (
          tab: 'sales',
          title: 'Sales report',
          headers: const ['Branch', 'Transactions', 'Revenue (MK)'],
          rows: [
            for (final b in branchSales) [b.branchName, '${b.transactions}', '${b.revenue.round()}'],
          ],
          summary: [
            'Transactions: ${_bundle.sales.length}',
            'Revenue: MK ${_fmtMk(_revenue)}',
          ],
        );
      case 1:
        final profit = buildProfit(_bundle.saleItems, _bundle.expenses, _branchNamesForProfit(), _bundle.stockProfitByBranch);
        return (
          tab: 'profit',
          title: 'Profit report',
          headers: const ['Branch', 'Revenue', 'COGS', 'Gross profit', 'Expenses', 'Net profit', 'Profit in stock'],
          rows: [
            for (final p in profit)
              [p.branchName, '${p.revenue.round()}', '${p.cogs.round()}', '${p.gross.round()}', '${p.expenses.round()}', '${p.net.round()}', '${p.stockProfit.round()}'],
          ],
          summary: [
            'Revenue: MK ${_fmtMk(_revenue)}',
            'Gross profit: MK ${_fmtMk(_gross)}',
            'Expenses: MK ${_fmtMk(_expenses)}',
            'Net profit: MK ${_fmtMk(_net)}',
          ],
        );
      case 2:
        final best = _rankedBest();
        return (
          tab: 'best_sellers',
          title: 'Best sellers',
          headers: const ['Item', 'Qty sold', 'Revenue (MK)', 'Profit (MK)', 'Times sold'],
          rows: [
            for (final b in best)
              [b.itemName, _fmtQty(b.qty), '${b.revenue.round()}', '${b.profit.round()}', '${b.times}'],
          ],
          summary: ['Ranked by ${_rankLabel(_rankBy).toLowerCase()} · ${best.length} items'],
        );
      case 3:
        return (
          tab: 'expenses',
          title: 'Expenses report',
          headers: const ['Date', 'Category', 'Branch', 'Description', 'Amount (MK)'],
          rows: [
            for (final e in _bundle.expenses)
              [e.expenseDate, e.category, e.branchName, e.description, '${e.amount.round()}'],
          ],
          summary: ['Total: MK ${_fmtMk(_expenses)} across ${_bundle.expenses.length} records'],
        );
      default:
        return (
          tab: 'debts',
          title: 'Debts report',
          headers: const ['Type', 'Name', 'Branch', 'Balance (MK)'],
          rows: [
            for (final c in _customers) ['Customer', c.name, c.branchName, '${c.balance.round()}'],
            for (final s in _suppliers) ['Supplier', s.supplierName, 'All branches', '${s.amountOwed.round()}'],
          ],
          summary: [
            'Customers owe: MK ${_fmtMk(_customers.fold(0.0, (s, c) => s + c.balance))}',
            'Owed to suppliers: MK ${_fmtMk(_suppliers.fold(0.0, (s, x) => s + x.amountOwed))}',
          ],
        );
    }
  }

  Map<String, String> _branchNamesForProfit() {
    final names = Map<String, String>.from(_branchNames);
    for (final s in _bundle.sales) {
      names.putIfAbsent(s.branchId, () => s.branchName);
    }
    for (final e in _bundle.expenses) {
      names.putIfAbsent(e.branchId, () => e.branchName);
    }
    return names;
  }

  Future<void> _exportCsv() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final ex = _buildExport();
      final buf = StringBuffer('${ex.headers.map(_csvCell).join(',')}\n');
      for (final r in ex.rows) {
        buf.writeln(r.map(_csvCell).join(','));
      }
      final path = await FileSaver.instance.saveFile(
        name: _fileBase(ex.tab),
        bytes: Uint8List.fromList(utf8.encode(buf.toString())),
        fileExtension: 'csv',
        mimeType: MimeType.csv,
      );
      if (mounted) showToast(context, '${ex.rows.length} rows saved to $path');
    } catch (e) {
      if (mounted) showToast(context, 'Export failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportPdf() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final ex = _buildExport();
      final doc = pw.Document();
      final brandBlue = PdfColor.fromHex('143D9E');
      final gold = PdfColor.fromHex('C9A227');
      final now = DateTime.now();
      doc.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          header: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('TUMAINI INVESTMENTS',
                  style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold, color: brandBlue)),
              pw.Text(ex.title, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 2),
              pw.Text('$_scopeName · ${_period.describe()}',
                  style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
              pw.Divider(color: gold, thickness: 2),
            ],
          ),
          footer: (ctx) => pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Generated ${now.day}/${now.month}/${now.year}',
                  style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
              pw.Text('Page ${ctx.pageNumber}/${ctx.pagesCount}',
                  style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
            ],
          ),
          build: (_) => [
            pw.Wrap(
              spacing: 12,
              runSpacing: 6,
              children: [for (final s in ex.summary) pw.Text(s, style: const pw.TextStyle(fontSize: 10))],
            ),
            pw.SizedBox(height: 12),
            pw.TableHelper.fromTextArray(
              headers: ex.headers,
              data: ex.rows,
              headerStyle: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white),
              headerDecoration: const pw.BoxDecoration(color: PdfColors.blue900),
              cellStyle: const pw.TextStyle(fontSize: 9),
              oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
            ),
          ],
        ),
      );
      await Printing.sharePdf(bytes: await doc.save(), filename: '${_fileBase(ex.tab)}.pdf');
    } catch (e) {
      if (mounted) showToast(context, 'PDF failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  // ---- Best sellers --------------------------------------------------------------

  List<BestRow> _rankedBest() {
    final list = buildBestSellers(_bundle.saleItems);
    switch (_rankBy) {
      case _BestRank.qty:
        list.sort((a, b) => b.qty.compareTo(a.qty));
      case _BestRank.revenue:
        list.sort((a, b) => b.revenue.compareTo(a.revenue));
      case _BestRank.profit:
        list.sort((a, b) => b.profit.compareTo(a.profit));
      case _BestRank.times:
        list.sort((a, b) => b.times.compareTo(a.times));
    }
    return list;
  }

  static String _rankLabel(_BestRank r) {
    switch (r) {
      case _BestRank.qty:
        return 'Quantity';
      case _BestRank.revenue:
        return 'Revenue';
      case _BestRank.profit:
        return 'Profit';
      case _BestRank.times:
        return 'Times sold';
    }
  }

  // ---- Build -----------------------------------------------------------------------

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
                padding: EdgeInsets.fromLTRB(wide ? 32 : 18, wide ? 28 : 12, wide ? 32 : 18, 96),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PageTitle(
                          title: 'Reports',
                          subtitle: _loading ? 'Loading…' : '$_scopeName · ${_period.describe()}',
                          trailing: _exporting
                              ? const SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: Center(
                                    child: SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(strokeWidth: 2, color: kPrimary),
                                    ),
                                  ),
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: _loading ? null : _exportCsv,
                                      style: outlineButtonStyle(height: 44),
                                      icon: const Icon(Icons.table_chart_outlined, size: 18),
                                      label: const Text('CSV'),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton.icon(
                                      onPressed: _loading ? null : _exportPdf,
                                      style: outlineButtonStyle(height: 44),
                                      icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                                      label: const Text('PDF'),
                                    ),
                                  ],
                                ),
                        ),
                        const SizedBox(height: 18),
                        _filterBar(wide),
                        const SizedBox(height: 16),
                        _body(wide),
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

  static const _periodItems = [
    ('today', 'Today'),
    ('week', 'This week'),
    ('month', 'This month'),
    ('year', 'This year'),
    ('day', 'Specific date…'),
    ('custom', 'Custom range…'),
    ('y2', 'Last 2 years'),
    ('y3', 'Last 3 years'),
    ('y5', 'Last 5 years'),
    ('y7', 'Last 7 years'),
    ('yCustom', 'Custom years…'),
  ];

  Widget _branchDropdown() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: _branchId,
          icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: kInkMuted),
          style: sans(13.5, weight: FontWeight.w500, color: kInk),
          hint: Text('All Branches', style: sans(13.5, weight: FontWeight.w500, color: kInk)),
          onChanged: _onBranchChanged,
          items: [
            const DropdownMenuItem<String?>(value: null, child: Text('All Branches')),
            ..._branches.map((b) => DropdownMenuItem<String?>(value: b.id, child: Text(b.name))),
          ],
        ),
      ),
    );
  }

  Widget _periodDropdown() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _periodValue,
          icon: const Icon(Icons.calendar_month_outlined, size: 18, color: kInkMuted),
          style: sans(13.5, weight: FontWeight.w500, color: kInk),
          onChanged: (v) {
            if (v != null) _pickPeriod(v);
          },
          items: [
            for (final (v, label) in _periodItems)
              DropdownMenuItem<String>(value: v, child: Text(label)),
          ],
        ),
      ),
    );
  }

  Widget _filterBar(bool wide) {
    if (wide) {
      return Row(
        children: [
          _branchDropdown(),
          const SizedBox(width: 10),
          _periodDropdown(),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: kPrimaryTint,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(_period.describe(), style: sans(12.5, weight: FontWeight.w600, color: kPrimary)),
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: kBorder),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('$_scopeName · ${_period.label()}',
                style: sans(12.5, weight: FontWeight.w600, color: kInk),
                overflow: TextOverflow.ellipsis),
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton.icon(
          onPressed: () async {
            final res = await showAdaptiveSheet<_ReportFilterResult>(
              context,
              builder: (_) => _ReportFiltersSheet(
                branches: _branches,
                branchId: _branchId,
                periodValue: _periodValue,
              ),
            );
            if (res == null || !mounted) return;
            var needReload = false;
            if (res.branchId != _branchId) {
              _branchId = res.branchId;
              needReload = true;
            }
            if (res.periodAction != null) {
              // Period pickers need a live context — run after the sheet closes.
              WidgetsBinding.instance.addPostFrameCallback((_) => _pickPeriod(res.periodAction!));
              return;
            }
            if (needReload) await _load();
          },
          style: outlineButtonStyle(height: 46),
          icon: const Icon(Icons.tune_outlined, size: 18),
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
        _summaryCards(wide),
        const SizedBox(height: 16),
        _tabChips(),
        const SizedBox(height: 14),
        _tabContent(wide),
      ],
    );
  }

  Widget _summaryCards(bool wide) {
    final cards = [
      _SummaryCard(label: 'Revenue', value: 'MK ${_fmtMk(_revenue)}', sub: '${_bundle.sales.length} sales', icon: Icons.payments_outlined),
      _SummaryCard(label: 'Gross profit', value: 'MK ${_fmtMk(_gross)}', sub: 'sales minus cost', icon: Icons.trending_up_outlined),
      _SummaryCard(label: 'Expenses', value: 'MK ${_fmtMk(_expenses)}', sub: '${_bundle.expenses.length} records', icon: Icons.receipt_long_outlined),
      _SummaryCard(
        label: 'Net profit',
        value: 'MK ${_fmtMk(_net)}',
        sub: 'gross minus expenses',
        icon: Icons.account_balance_outlined,
        highlight: true,
        alert: _net < 0,
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
        itemBuilder: (_, i) => SizedBox(width: 172, child: cards[i]),
      ),
    );
  }

  Widget _tabChips() {
    const labels = ['Sales', 'Profit', 'Best sellers', 'Expenses', 'Debts'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < labels.length; i++) ...[
            FilterPill(label: labels[i], selected: _tab == i, onTap: () => setState(() => _tab = i)),
            if (i != labels.length - 1) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }

  Widget _tabContent(bool wide) {
    switch (_tab) {
      case 0:
        return _SalesTab(bundle: _bundle, period: _period, wide: wide);
      case 1:
        return _ProfitTab(
          bundle: _bundle,
          branchNames: _branchNamesForProfit(),
          wide: wide,
          showBranchCol: _branchId == null,
        );
      case 2:
        return _BestTab(
          items: _rankedBest(),
          wide: wide,
          rankBy: _rankBy,
          onRank: (r) => setState(() => _rankBy = r),
        );
      case 3:
        return _ExpensesTab(bundle: _bundle, wide: wide, showBranch: _branchId == null);
      default:
        return _DebtsTab(
          customers: _filteredCustomers(),
          suppliers: _suppliers,
          branchFiltered: _branchId != null,
          searchCtrl: _debtSearchCtrl,
          onSearch: (v) => setState(() => _debtSearch = v),
          onCustomerTap: _openCustomer,
          onSupplierTap: _openSupplier,
        );
    }
  }

  List<CustomerDebt> _filteredCustomers() {
    final q = _debtSearch.trim().toLowerCase();
    if (q.isEmpty) return _customers;
    return _customers.where((c) => c.name.toLowerCase().contains(q)).toList();
  }

  Future<void> _openCustomer(CustomerDebt c) async {
    await showAdaptiveSheet<void>(
      context,
      builder: (_) => _DebtHistorySheet(
        title: c.name,
        subtitle: '${c.branchName} · owes MK ${_fmtMk(c.balance)}',
        loader: () => _repo.fetchCustomerHistory(c.customerId),
      ),
    );
  }

  Future<void> _openSupplier(SupplierDebt s) async {
    await showAdaptiveSheet<void>(
      context,
      builder: (_) => _DebtHistorySheet(
        title: s.supplierName,
        subtitle: 'Owed MK ${_fmtMk(s.amountOwed)}',
        loader: () => _repo.fetchSupplierHistory(s.supplierId),
      ),
    );
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
  final bool highlight;
  final bool alert;
  const _SummaryCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.icon,
    this.highlight = false,
    this.alert = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: highlight ? kPrimary : Colors.white,
        border: Border.all(color: highlight ? kPrimary : kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: highlight ? Colors.white24 : kPrimaryTint,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: highlight ? Colors.white : kPrimary),
          ),
          const SizedBox(height: 10),
          Text(value,
              style: mono(17,
                  weight: FontWeight.w700,
                  color: highlight ? Colors.white : (alert ? kDanger : kInk))),
          const SizedBox(height: 2),
          Text(label,
              style: sans(11.5,
                  weight: FontWeight.w600, color: highlight ? Colors.white70 : kInkMuted)),
          Text(sub, style: sans(10.5, color: highlight ? Colors.white70 : kInkMuted)),
        ],
      ),
    );
  }
}

// ============================================================================
// CHARTS
// ============================================================================

class _TrendChart extends StatelessWidget {
  final List<TrendPoint> points;
  const _TrendChart({required this.points});

  @override
  Widget build(BuildContext context) {
    final maxY = points.fold(0.0, (m, p) => p.value > m ? p.value : m);
    final double interval = (points.length / 6).ceilToDouble().clamp(1, 1000).toDouble();
    return SizedBox(
      height: 230,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY <= 0 ? 10.0 : maxY * 1.15,
          gridData: FlGridData(show: true, drawVerticalLine: false),
          borderData: FlBorderData(show: true, border: Border.all(color: kBorder)),
          lineTouchData: const LineTouchData(enabled: true),
          titlesData: FlTitlesData(
            show: true,
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 46,
                getTitlesWidget: (v, _) => Text(_compact(v),
                    style: sans(10, color: kInkMuted), textAlign: TextAlign.right),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 30,
                interval: interval,
                getTitlesWidget: (v, _) {
                  final i = v.round();
                  if (i < 0 || i >= points.length) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(points[i].label, style: sans(10, color: kInkMuted)),
                  );
                },
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: [for (int i = 0; i < points.length; i++) FlSpot(i.toDouble(), points[i].value)],
              isCurved: true,
              color: kPrimary,
              barWidth: 3,
              isStrokeCapRound: true,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: true, color: kPrimary.withValues(alpha: 0.12)),
            ),
          ],
        ),
      ),
    );
  }
}

class _BranchBars extends StatelessWidget {
  final List<BranchSales> branches;
  const _BranchBars({required this.branches});

  @override
  Widget build(BuildContext context) {
    final shown = branches.take(10).toList();
    final maxY = shown.fold(0.0, (m, b) => b.revenue > m ? b.revenue : m);
    final chartWidth = (shown.length * 64.0).clamp(320.0, 1200.0);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: chartWidth,
        height: 230,
        child: BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            maxY: maxY <= 0 ? 10.0 : maxY * 1.15,
            barTouchData: BarTouchData(enabled: true),
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              show: true,
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 46,
                  getTitlesWidget: (v, _) => Text(_compact(v),
                      style: sans(10, color: kInkMuted), textAlign: TextAlign.right),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 36,
                  getTitlesWidget: (v, _) {
                    final i = v.round();
                    if (i < 0 || i >= shown.length) return const SizedBox.shrink();
                    final name = shown[i].branchName.split(' ').first;
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        name.length > 9 ? '${name.substring(0, 9)}…' : name,
                        style: sans(10, color: kInkMuted),
                        textAlign: TextAlign.center,
                      ),
                    );
                  },
                ),
              ),
            ),
            barGroups: [
              for (int i = 0; i < shown.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: shown[i].revenue,
                      color: i == 0 ? const Color(0xFFC9A227) : kPrimary,
                      width: 22,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// TAB 0 — SALES
// ============================================================================

class _SalesTab extends StatelessWidget {
  final PeriodBundle bundle;
  final ReportPeriod period;
  final bool wide;
  const _SalesTab({required this.bundle, required this.period, required this.wide});

  @override
  Widget build(BuildContext context) {
    final branchSales = aggregateBranchSales(bundle.sales);
    final trend = buildTrend(bundle.sales, period);
    final hasTrend = trend.any((p) => p.value > 0);
    final chartCard = (String title, Widget child) => Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: kBorder),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: sans(13.5, weight: FontWeight.w700, color: kInk)),
              const SizedBox(height: 12),
              child,
            ],
          ),
        );

    final children = <Widget>[
      chartCard('Sales trend · ${period.describe()}',
          hasTrend ? _TrendChart(points: trend) : _chartEmpty('No sales in this period.')),
      chartCard(
          'Revenue by branch',
          branchSales.isEmpty
              ? _chartEmpty('No sales in this period.')
              : _BranchBars(branches: branchSales)),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wide)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: children[0]),
                const SizedBox(width: 12),
                Expanded(child: children[1]),
              ],
            ),
          )
        else ...[
          children[0],
          const SizedBox(height: 12),
          children[1],
        ],
        const SizedBox(height: 16),
        Text('Branches · highest first', style: sans(13, weight: FontWeight.w600, color: kInkMuted)),
        const SizedBox(height: 8),
        if (branchSales.isEmpty)
          const EmptyState(
            icon: Icons.point_of_sale_outlined,
            title: 'No sales yet',
            message: 'Sales recorded in this period will appear here.',
          )
        else
          for (final b in branchSales) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: kBorder),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(b.branchName, style: sans(13.5, weight: FontWeight.w600, color: kInk)),
                        Text('${b.transactions} ${b.transactions == 1 ? 'sale' : 'sales'}',
                            style: sans(11.5, color: kInkMuted)),
                      ],
                    ),
                  ),
                  Text('MK ${_fmtMk(b.revenue)}', style: mono(14, weight: FontWeight.w700, color: kInk)),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }

  Widget _chartEmpty(String msg) {
    return SizedBox(
      height: 120,
      child: Center(child: Text(msg, style: sans(12.5, color: kInkMuted))),
    );
  }
}

// ============================================================================
// TAB 1 — PROFIT (ranked by net, stock profit beside realised)
// ============================================================================

class _ProfitTab extends StatelessWidget {
  final PeriodBundle bundle;
  final Map<String, String> branchNames;
  final bool wide;
  final bool showBranchCol;
  const _ProfitTab({
    required this.bundle,
    required this.branchNames,
    required this.wide,
    required this.showBranchCol,
  });

  @override
  Widget build(BuildContext context) {
    final rows = buildProfit(bundle.saleItems, bundle.expenses, branchNames, bundle.stockProfitByBranch);
    if (rows.isEmpty) {
      return const EmptyState(
        icon: Icons.account_balance_outlined,
        title: 'No profit data',
        message: 'Sales or expenses in this period will appear here.',
      );
    }
    if (wide) return _table(rows);
    return Column(
      children: [
        for (final p in rows) ...[
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
                    Expanded(child: Text(p.branchName, style: sans(14, weight: FontWeight.w700, color: kInk))),
                    Text('MK ${_fmtMk(p.net)}',
                        style: mono(14, weight: FontWeight.w700, color: p.net < 0 ? kDanger : kSuccess)),
                  ],
                ),
                Text('net profit', style: sans(11, color: kInkMuted)),
                const SizedBox(height: 10),
                _kv('Revenue', 'MK ${_fmtMk(p.revenue)}'),
                _kv('Cost of goods', 'MK ${_fmtMk(p.cogs)}'),
                _kv('Gross profit', 'MK ${_fmtMk(p.gross)}'),
                _kv('Expenses', 'MK ${_fmtMk(p.expenses)}'),
                const Divider(height: 16, color: kBorder),
                _kv('Profit still in stock', 'MK ${_fmtMk(p.stockProfit)}', highlight: true),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _kv(String k, String v, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(child: Text(k, style: sans(12, color: kInkMuted))),
          Text(v,
              style: highlight
                  ? sans(12, weight: FontWeight.w700, color: kPrimary)
                  : mono(12.5, weight: FontWeight.w600, color: kInk)),
        ],
      ),
    );
  }

  Widget _table(List<ProfitRow> rows) {
    TextStyle head = sans(11, weight: FontWeight.w700, color: kInkMuted);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(kSurface),
          columns: [
            DataColumn(label: Text('BRANCH', style: head)),
            DataColumn(label: Text('REVENUE', style: head), numeric: true),
            DataColumn(label: Text('COGS', style: head), numeric: true),
            DataColumn(label: Text('GROSS', style: head), numeric: true),
            DataColumn(label: Text('EXPENSES', style: head), numeric: true),
            DataColumn(label: Text('NET', style: head), numeric: true),
            DataColumn(label: Text('IN STOCK', style: head), numeric: true),
          ],
          rows: [
            for (int i = 0; i < rows.length; i++)
              DataRow(cells: [
                DataCell(Row(
                  children: [
                    if (i == 0)
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Icon(Icons.emoji_events_outlined, size: 16, color: Color(0xFFC9A227)),
                      ),
                    Text(rows[i].branchName, style: sans(13, weight: FontWeight.w600, color: kInk)),
                  ],
                )),
                DataCell(Text('MK ${_fmtMk(rows[i].revenue)}', style: mono(12.5, color: kInk))),
                DataCell(Text('MK ${_fmtMk(rows[i].cogs)}', style: mono(12.5, color: kInk))),
                DataCell(Text('MK ${_fmtMk(rows[i].gross)}', style: mono(12.5, color: kInk))),
                DataCell(Text('MK ${_fmtMk(rows[i].expenses)}', style: mono(12.5, color: kInk))),
                DataCell(Text('MK ${_fmtMk(rows[i].net)}',
                    style: mono(12.5,
                        weight: FontWeight.w700, color: rows[i].net < 0 ? kDanger : kSuccess))),
                DataCell(Text('MK ${_fmtMk(rows[i].stockProfit)}',
                    style: sans(12.5, weight: FontWeight.w600, color: kPrimary))),
              ]),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// TAB 2 — BEST SELLERS
// ============================================================================

class _BestTab extends StatelessWidget {
  final List<BestRow> items;
  final bool wide;
  final _BestRank rankBy;
  final ValueChanged<_BestRank> onRank;
  const _BestTab({required this.items, required this.wide, required this.rankBy, required this.onRank});

  @override
  Widget build(BuildContext context) {
    String metric(BestRow b) {
      switch (rankBy) {
        case _BestRank.qty:
          return '${_fmtQty(b.qty)} sold';
        case _BestRank.revenue:
          return 'MK ${_fmtMk(b.revenue)}';
        case _BestRank.profit:
          return 'MK ${_fmtMk(b.profit)}';
        case _BestRank.times:
          return '${b.times}× sold';
      }
    }

    String sub(BestRow b) {
      switch (rankBy) {
        case _BestRank.qty:
          return 'MK ${_fmtMk(b.revenue)} revenue · ${b.times}× sold';
        case _BestRank.revenue:
          return '${_fmtQty(b.qty)} sold · ${b.times}× sold';
        case _BestRank.profit:
          return '${_fmtQty(b.qty)} sold · MK ${_fmtMk(b.revenue)} revenue';
        case _BestRank.times:
          return '${_fmtQty(b.qty)} sold · MK ${_fmtMk(b.revenue)} revenue';
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final r in _BestRank.values) ...[
                FilterPill(
                  label: _ReportsScreenState._rankLabel(r),
                  selected: rankBy == r,
                  onTap: () => onRank(r),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          const EmptyState(
            icon: Icons.star_outline,
            title: 'Nothing sold yet',
            message: 'Sales in this period will rank the best sellers here.',
          )
        else
          for (int i = 0; i < items.length; i++) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: i == 0 ? const Color(0xFFC9A227) : kBorder, width: i == 0 ? 1.5 : 1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text('${i + 1}',
                        style: mono(14,
                            weight: FontWeight.w700,
                            color: i == 0 ? const Color(0xFFC9A227) : kInkMuted)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(items[i].itemName, style: sans(13.5, weight: FontWeight.w600, color: kInk)),
                        const SizedBox(height: 2),
                        Text(sub(items[i]), style: sans(11.5, color: kInkMuted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(metric(items[i]), style: mono(13.5, weight: FontWeight.w700, color: kPrimary)),
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
// TAB 3 — EXPENSES (by category + branch, then the records)
// ============================================================================

class _ExpensesTab extends StatelessWidget {
  final PeriodBundle bundle;
  final bool wide;
  final bool showBranch;
  const _ExpensesTab({required this.bundle, required this.wide, required this.showBranch});

  @override
  Widget build(BuildContext context) {
    final cats = buildCategoryTotals(bundle.expenses);
    final total = bundle.expenses.fold(0.0, (s, e) => s + e.amount);
    final byBranch = <String, double>{};
    final branchName = <String, String>{};
    for (final e in bundle.expenses) {
      byBranch[e.branchId] = (byBranch[e.branchId] ?? 0) + e.amount;
      branchName[e.branchId] = e.branchName;
    }
    final branchList = byBranch.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    if (bundle.expenses.isEmpty) {
      return const EmptyState(
        icon: Icons.receipt_long_outlined,
        title: 'No expenses recorded',
        message: 'Operating costs in this period will appear here.',
      );
    }

    final categoryCard = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('By category · MK ${_fmtMk(total)}', style: sans(13.5, weight: FontWeight.w700, color: kInk)),
          const SizedBox(height: 12),
          for (final c in cats) ...[
            Row(
              children: [
                Expanded(child: Text('${c.category} (${c.count})', style: sans(12.5, color: kInk))),
                Text('MK ${_fmtMk(c.amount)}', style: mono(12.5, weight: FontWeight.w600, color: kInk)),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: total <= 0 ? 0 : (c.amount / total).clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: kSurface,
                valueColor: const AlwaysStoppedAnimation<Color>(kPrimary),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );

    final branchCard = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('By branch', style: sans(13.5, weight: FontWeight.w700, color: kInk)),
          const SizedBox(height: 12),
          for (final e in branchList) ...[
            Row(
              children: [
                Expanded(child: Text(branchName[e.key] ?? '—', style: sans(12.5, color: kInk))),
                Text('MK ${_fmtMk(e.value)}', style: mono(12.5, weight: FontWeight.w600, color: kInk)),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: total <= 0 ? 0 : (e.value / total).clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: kSurface,
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFC9A227)),
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (wide)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: categoryCard),
                const SizedBox(width: 12),
                Expanded(child: branchCard),
              ],
            ),
          )
        else ...[
          categoryCard,
          const SizedBox(height: 12),
          if (showBranch) ...[branchCard, const SizedBox(height: 12)],
        ],
        const SizedBox(height: 4),
        Text('Records (${bundle.expenses.length})', style: sans(13, weight: FontWeight.w600, color: kInkMuted)),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: kBorder),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: List.generate(bundle.expenses.length, (i) {
              final e = bundle.expenses[i];
              final title = e.description.trim().isNotEmpty ? e.description.trim() : e.category;
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                decoration: BoxDecoration(
                  border: i == bundle.expenses.length - 1
                      ? null
                      : const Border(bottom: BorderSide(color: kBorder)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: sans(13, weight: FontWeight.w600, color: kInk)),
                          const SizedBox(height: 2),
                          Text('${e.category} · ${showBranch ? '${e.branchName} · ' : ''}${_fmtDate(e.expenseDate)}',
                              style: sans(11.5, color: kInkMuted)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text('MK ${_fmtMk(e.amount)}', style: mono(12.5, weight: FontWeight.w600, color: kInk)),
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
// TAB 4 — DEBTS (current balances; period-independent)
// ============================================================================

class _DebtsTab extends StatelessWidget {
  final List<CustomerDebt> customers;
  final List<SupplierDebt> suppliers;
  final bool branchFiltered;
  final TextEditingController searchCtrl;
  final ValueChanged<String> onSearch;
  final ValueChanged<CustomerDebt> onCustomerTap;
  final ValueChanged<SupplierDebt> onSupplierTap;
  const _DebtsTab({
    required this.customers,
    required this.suppliers,
    required this.branchFiltered,
    required this.searchCtrl,
    required this.onSearch,
    required this.onCustomerTap,
    required this.onSupplierTap,
  });

  @override
  Widget build(BuildContext context) {
    final custTotal = customers.fold(0.0, (s, c) => s + c.balance);
    final supTotal = suppliers.fold(0.0, (s, x) => s + x.amountOwed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: kPrimaryTint, borderRadius: BorderRadius.circular(10)),
          child: Text('Balances are current — they don’t change with the period selector.',
              style: sans(12, weight: FontWeight.w500, color: kPrimary)),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
                child: _DebtTotalCard(
                    label: 'Customers owe', value: 'MK ${_fmtMk(custTotal)}', icon: Icons.people_outline)),
            const SizedBox(width: 10),
            Expanded(
                child: _DebtTotalCard(
                    label: 'We owe suppliers', value: 'MK ${_fmtMk(supTotal)}', icon: Icons.local_shipping_outlined)),
          ],
        ),
        const SizedBox(height: 16),
        SearchField(hint: 'Search customers…', controller: searchCtrl, onChanged: onSearch),
        const SizedBox(height: 14),
        Text('Customer debts (${customers.length})', style: sans(13, weight: FontWeight.w600, color: kInkMuted)),
        const SizedBox(height: 8),
        if (customers.isEmpty)
          const EmptyState(
            icon: Icons.people_outline,
            title: 'No customer debts',
            message: 'Nobody owes money right now.',
          )
        else
          for (final c in customers) ...[
            _DebtRow(
              title: c.name,
              sub: branchFiltered ? 'owes' : c.branchName,
              amount: 'MK ${_fmtMk(c.balance)}',
              onTap: () => onCustomerTap(c),
            ),
            const SizedBox(height: 8),
          ],
        const SizedBox(height: 16),
        Text('Supplier balances (${suppliers.length})', style: sans(13, weight: FontWeight.w600, color: kInkMuted)),
        if (branchFiltered) ...[
          const SizedBox(height: 4),
          Text('Suppliers serve all branches — shown across the business.',
              style: sans(11.5, color: kInkMuted)),
        ],
        const SizedBox(height: 8),
        if (suppliers.isEmpty)
          const EmptyState(
            icon: Icons.local_shipping_outlined,
            title: 'Nothing owed',
            message: 'All supplier invoices are settled.',
          )
        else
          for (final s in suppliers) ...[
            _DebtRow(
              title: s.supplierName,
              sub: 'we owe',
              amount: 'MK ${_fmtMk(s.amountOwed)}',
              danger: true,
              onTap: () => onSupplierTap(s),
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _DebtTotalCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _DebtTotalCard({required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: kPrimary),
          const SizedBox(height: 8),
          Text(value, style: mono(16, weight: FontWeight.w700, color: kInk)),
          const SizedBox(height: 2),
          Text(label, style: sans(11.5, color: kInkMuted)),
        ],
      ),
    );
  }
}

class _DebtRow extends StatelessWidget {
  final String title;
  final String sub;
  final String amount;
  final bool danger;
  final VoidCallback onTap;
  const _DebtRow({
    required this.title,
    required this.sub,
    required this.amount,
    this.danger = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            border: Border.all(color: kBorder),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: sans(13.5, weight: FontWeight.w600, color: kInk)),
                    Text(sub, style: sans(11.5, color: kInkMuted)),
                  ],
                ),
              ),
              Text(amount,
                  style: mono(13.5, weight: FontWeight.w700, color: danger ? kDanger : kPrimary)),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, size: 18, color: kInkMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _DebtHistorySheet extends StatelessWidget {
  final String title;
  final String subtitle;
  final Future<List<DebtPayment>> Function() loader;
  const _DebtHistorySheet({required this.title, required this.subtitle, required this.loader});

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: title,
      subtitle: subtitle,
      child: FutureBuilder<List<DebtPayment>>(
        future: loader(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator(color: kPrimary)),
            );
          }
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text('Couldn’t load history: ${snap.error}', style: sans(13, color: kDanger)),
            );
          }
          final rows = snap.data ?? [];
          if (rows.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No payments recorded yet.', style: sans(13.5, color: kInkMuted))),
            );
          }
          return ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: rows.length,
              separatorBuilder: (_, _) => const Divider(height: 1, color: kBorder),
              itemBuilder: (_, i) {
                final p = rows[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('MK ${_fmtMk(p.amount)}',
                                style: mono(13.5, weight: FontWeight.w700, color: kSuccess)),
                            const SizedBox(height: 2),
                            Text(
                              '${_fmtDate(p.date)}${p.method.isNotEmpty ? ' · ${p.method}' : ''}${p.note != null ? ' · ${p.note}' : ''}',
                              style: sans(11.5, color: kInkMuted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

// ============================================================================
// MOBILE FILTERS SHEET (branch + period)
// ============================================================================

class _ReportFilterResult {
  final String? branchId;
  final String? periodAction; // null = keep current period
  const _ReportFilterResult({required this.branchId, required this.periodAction});
}

class _ReportFiltersSheet extends StatefulWidget {
  final List<ReportBranch> branches;
  final String? branchId;
  final String periodValue;
  const _ReportFiltersSheet({required this.branches, required this.branchId, required this.periodValue});

  @override
  State<_ReportFiltersSheet> createState() => _ReportFiltersSheetState();
}

class _ReportFiltersSheetState extends State<_ReportFiltersSheet> {
  late String? _branchId = widget.branchId;
  late String _periodValue = widget.periodValue;

  static const _periodLabels = {
    'today': 'Today',
    'week': 'This week',
    'month': 'This month',
    'year': 'This year',
    'day': 'Specific date…',
    'custom': 'Custom range…',
    'y2': 'Last 2 years',
    'y3': 'Last 3 years',
    'y5': 'Last 5 years',
    'y7': 'Last 7 years',
    'yCustom': 'Custom years…',
  };

  @override
  Widget build(BuildContext context) {
    final needsPicker = _periodValue == 'day' || _periodValue == 'custom' || _periodValue == 'yCustom';
    return SheetFrame(
      title: 'Filters',
      subtitle: 'Scope every report tab.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Branch', style: sans(13, weight: FontWeight.w600, color: kInkMuted)),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(10)),
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
          Text('Period', style: sans(13, weight: FontWeight.w600, color: kInkMuted)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in _periodLabels.entries)
                FilterPill(
                  label: e.value,
                  selected: _periodValue == e.key,
                  onTap: () => setState(() => _periodValue = e.key),
                ),
            ],
          ),
          if (needsPicker) ...[
            const SizedBox(height: 8),
            Text('A date picker opens after you tap Apply.', style: sans(12, color: kInkMuted)),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => setState(() {
                    _branchId = null;
                    _periodValue = 'month';
                  }),
                  style: outlineButtonStyle(),
                  child: const Text('Reset'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_ReportFilterResult(
                    branchId: _branchId,
                    periodAction: _periodValue == widget.periodValue ? null : _periodValue,
                  )),
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
