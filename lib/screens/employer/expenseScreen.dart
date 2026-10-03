import 'package:flutter/material.dart';

import '../../appUser.dart';
import '../../widgets/employeeShell.dart';
import 'employeeUi.dart';
import 'expenseRepo.dart';

// ============================================================================
// BRANCH EXPENSES — own-branch spending, recorded by branch staff.
//   Amount + category + reason + date (today by default). Everything is
//   limited to the user's own branch_id; RLS enforces the same server-side.
//
//   Desktop: reached from the side rail (below Stock). Mobile: no tab —
//   staff record from the Home "New expense" button instead, which opens
//   the same sheet below.
// ============================================================================

/// Opens the record-expense form (sheet on mobile, dialog on desktop).
/// Returns true when an expense was saved.
Future<bool?> showRecordExpenseSheet(
  BuildContext context, {
  required String branchId,
}) {
  final wide = MediaQuery.of(context).size.width >= empWideBreakpoint;
  if (wide) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            child: _ExpenseForm(branchId: branchId),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ExpenseForm(branchId: branchId),
  );
}

String _dayLabel(String iso) {
  try {
    final d = DateTime.parse(iso);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  } catch (_) {
    return iso;
  }
}

String _todayStr() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

IconData _categoryIcon(String category) {
  switch (category.trim().toLowerCase()) {
    case 'transport':
      return Icons.directions_car_outlined;
    case 'electricity':
      return Icons.bolt_outlined;
    case 'rent':
      return Icons.home_outlined;
    case 'salaries':
      return Icons.payments_outlined;
    case 'airtime & internet':
    case 'internet':
      return Icons.wifi_outlined;
    case 'repairs':
      return Icons.build_outlined;
    default:
      return Icons.receipt_long_outlined;
  }
}

class ExpenseScreen extends StatefulWidget {
  final AppUser user;
  final String branchName;
  const ExpenseScreen({super.key, required this.user, required this.branchName});

  @override
  State<ExpenseScreen> createState() => _ExpenseScreenState();
}

class _ExpenseScreenState extends State<ExpenseScreen> {
  final _repo = ExpenseRepository();

  bool _loading = true;
  String? _error;
  List<ExpenseEntry> _rows = [];

  bool _loadedOnce = false;
  bool _wasSelected = false;

  String? get _branchId => widget.user.branchId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Desktop expenses tab lives at page index 5 — reload when opened.
    final selected = EmployeeShellScope.of(context)?.selectedIndex == 5;
    if (selected && !_wasSelected && _loadedOnce) _load(silent: true);
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
      final rows = await _repo.fetchExpenses(branchId: bid);
      if (!mounted) return;
      setState(() {
        _rows = rows;
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

  Future<void> _record() async {
    final bid = _branchId;
    if (bid == null) return;
    final saved = await showRecordExpenseSheet(context, branchId: bid);
    if (saved == true && mounted) {
      await _load(silent: true);
      if (mounted) empToast(context, 'Expense recorded.');
    }
  }

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
                padding: EdgeInsets.fromLTRB(
                  wide ? 32 : 18,
                  wide ? 28 : 14,
                  wide ? 32 : 18,
                  24,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
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
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 60),
        child: EmpCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Couldn’t load expenses',
                style: empSans(15, weight: FontWeight.w700, color: empInk),
              ),
              const SizedBox(height: 6),
              Text(_error!, style: empSans(13, color: empMuted)),
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

    final today = _todayStr();
    final todayTotal = _rows
        .where((e) => e.date == today)
        .fold(0.0, (s, e) => s + e.amount);
    final monthPrefix = today.substring(0, 7);
    final monthTotal = _rows
        .where((e) => e.date.startsWith(monthPrefix))
        .fold(0.0, (s, e) => s + e.amount);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Expenses',
          style: empSans(22, weight: FontWeight.w700, color: empInk),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            const Icon(Icons.storefront_outlined, size: 14, color: empMuted),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                widget.branchName.isEmpty
                    ? 'This branch only'
                    : '${widget.branchName} · this branch only',
                style: empSans(12.5, color: empMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            onPressed: _record,
            style: empPrimaryButton(height: 54),
            icon: const Icon(Icons.add, size: 20),
            label: const Text('Record expense'),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _TotalCard(label: 'Spent today', value: empMk(todayTotal)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _TotalCard(label: 'Spent this month', value: empMk(monthTotal)),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'Recent expenses',
          style: empSans(13.5, weight: FontWeight.w700, color: empInk),
        ),
        const SizedBox(height: 8),
        if (_rows.isEmpty)
          const EmpEmpty(
            icon: Icons.receipt_long_outlined,
            message: 'No expenses recorded yet.',
          )
        else
          EmpCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: List.generate(_rows.length, (i) {
                final e = _rows[i];
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 11,
                  ),
                  decoration: BoxDecoration(
                    border: i == _rows.length - 1
                        ? null
                        : const Border(bottom: BorderSide(color: empBorder)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: empPrimaryTint,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Icon(
                          _categoryIcon(e.category),
                          size: 18,
                          color: empPrimary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              e.category,
                              style: empSans(
                                13,
                                weight: FontWeight.w600,
                                color: empInk,
                              ),
                            ),
                            if ((e.description ?? '').isNotEmpty)
                              Text(
                                e.description!,
                                style: empSans(12, color: empMuted),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                _dayLabel(e.date),
                                if (e.recordedBy.isNotEmpty) e.recordedBy,
                              ].join(' · '),
                              style: empSans(11.5, color: empMuted),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        empMk(e.amount),
                        style: empMono(
                          13,
                          weight: FontWeight.w700,
                          color: empInk,
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

class _TotalCard extends StatelessWidget {
  final String label;
  final String value;
  const _TotalCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.payments_outlined, size: 18, color: empPrimary),
          const SizedBox(height: 8),
          Text(
            value,
            style: empMono(17, weight: FontWeight.w700, color: empInk),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: empSans(12, weight: FontWeight.w600, color: empMuted),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// RECORD-EXPENSE FORM (shared by the Expenses tab and the Home button)
// ============================================================================

class _ExpenseForm extends StatefulWidget {
  final String branchId;
  const _ExpenseForm({required this.branchId});

  @override
  State<_ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends State<_ExpenseForm> {
  final _repo = ExpenseRepository();
  final _amountCtrl = TextEditingController();
  final _reasonCtrl = TextEditingController();
  String? _category;
  String _date = _todayStr();
  bool _saving = false;
  String? _formError;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final initial = DateTime.tryParse(_date) ?? today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(today) ? today : initial,
      firstDate: DateTime(today.year - 2),
      // No future dates — an expense must already have happened.
      lastDate: DateTime(today.year, today.month, today.day),
    );
    if (picked == null) return;
    setState(() {
      _date =
          '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    });
  }

  Future<void> _submit() async {
    final amount = double.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _formError = 'Enter an amount above zero.');
      return;
    }
    if (_category == null) {
      setState(() => _formError = 'Pick a category.');
      return;
    }
    if (_reasonCtrl.text.trim().isEmpty) {
      setState(() => _formError = 'Add a short reason for this expense.');
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    try {
      await _repo.recordExpense(
        branchId: widget.branchId,
        amount: amount,
        category: _category!,
        description: _reasonCtrl.text,
        date: _date,
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
      title: 'Record expense',
      subtitle: 'Spending from this branch.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: empSans(15, color: empInk),
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
                value: _category,
                hint: Text('Category', style: empSans(14, color: empMuted)),
                isExpanded: true,
                style: empSans(14, color: empInk),
                items: [
                  for (final c in expenseCategories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => setState(() => _category = v),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reasonCtrl,
            style: empSans(14, color: empInk),
            maxLines: 2,
            decoration: empField(
              'Reason',
              hint: 'e.g. Transport for stock pickup',
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickDate,
            style: OutlinedButton.styleFrom(
              foregroundColor: empInk,
              minimumSize: const Size(0, 48),
              side: const BorderSide(color: empBorder),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              alignment: Alignment.centerLeft,
            ),
            icon: const Icon(
              Icons.calendar_today_outlined,
              size: 18,
              color: empMuted,
            ),
            label: Text(
              _dayLabel(_date),
              style: empSans(14, color: empInk),
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
                : const Text('Save expense'),
          ),
        ],
      ),
    );
  }
}
