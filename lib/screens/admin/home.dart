import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../appUser.dart';
import '../../auth-repository.dart';
import '../../widgets/adminShell.dart';
import 'adminhomeRepo.dart';
import 'adminui.dart';
import 'branch.dart';
import 'inventory.dart';
import 'reports.dart';
import 'settings.dart';
import 'stockAccessRepo.dart';
import 'user.dart';

/// Top-level route for '/admin-home'.
/// Loads the signed-in [AppUser] and wraps [AdminHomeScreen] inside [AdminShell].
class AdminHomeRoute extends StatefulWidget {
  const AdminHomeRoute({super.key});

  @override
  State<AdminHomeRoute> createState() => _AdminHomeRouteState();
}

class _AdminHomeRouteState extends State<AdminHomeRoute> {
  late final Future<AppUser> _future = _load();

  Future<AppUser> _load() async {
    final user = await AuthRepository().currentUser;
    if (user == null) {
      throw Exception('No signed-in user.');
    }
    return user;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppUser>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(context)
                .pushNamedAndRemoveUntil('/login', (route) => false);
          });
          return const Scaffold(body: SizedBox.shrink());
        }

        final user = snapshot.data!;
        return AdminShell(
          userName: user.fullName,
          pages: [
            const AdminHomeScreen(),
            const InventoryScreen(),
            const BranchesScreen(embedded: true),
            const UsersScreen(embedded: true),
            const ReportsScreen(),
            AdminSettingsScreen(userName: user.fullName),
          ],
        );
      },
    );
  }
}

// ============================================================================
// ADMIN HOME (Business Overview) — live Supabase data
//   - phone widths   -> stacked cards, "things need attention" is a single
//                        clickable summary row that pushes a full detail page
//   - desktop widths -> two-column layout, attention list shown inline since
//                        there's room, with a "View all" link to the same
//                        detail page
//
// Deliberately does NOT show profit — profit depends on more than
// sell price minus buy price (e.g. staff payments), and this system isn't
// the source of truth for that, so it's left out entirely rather than
// shown half-right.
//
// HOW TO WIRE THIS IN:
//   1. Drop this file AND admin_home_repository.dart into
//      lib/screens/admin/
//   2. Use as the first entry in AdminShell.pages:
//        AdminShell(pages: [AdminHomeScreen(), ...])
//   3. Make sure Supabase.initialize(...) has already run in main.dart
//      (it has, per your setup) — the repository reads
//      Supabase.instance.client directly.
// ============================================================================

const double _kDesktopBreakpoint = 760;
const Color _kBg = Colors.white;
const Color _kBorder = Color(0xFFD9E2F5);
const Color _kInkMuted = Color(0xFF5B6B8C);
const Color _kInk = Color(0xFF0F2038);
const Color _kPrimary = Color(0xFF143D9E);
const Color _kDebtColor = Color(0xFFB4544A);
const Color _kWarnColor = Color(0xFFB07A28);

TextStyle _sans(double size, {FontWeight? weight, Color? color}) =>
    GoogleFonts.ibmPlexSans(fontSize: size, fontWeight: weight, color: color);

TextStyle _mono(double size, {FontWeight? weight, Color? color}) =>
    GoogleFonts.ibmPlexMono(fontSize: size, fontWeight: weight, color: color);

String _formatMk(double amount) {
  final s = amount.round().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

String _formatDate(String raw) {
  try {
    final d = DateTime.parse(raw);
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
    final m = months[d.month - 1];
    return '${d.day} $m ${d.year}';
  } catch (_) {
    return raw;
  }
}

IconData _expenseIcon(String category) {
  switch (category.trim().toLowerCase()) {
    case 'transport':
      return Icons.directions_car_outlined;
    case 'electricity':
      return Icons.bolt_outlined;
    case 'rent':
      return Icons.home_outlined;
    case 'salaries':
      return Icons.payments_outlined;
    case 'internet':
      return Icons.wifi_outlined;
    case 'repairs':
      return Icons.build_outlined;
    default:
      return Icons.receipt_long_outlined;
  }
}

// ============================================================================
// ADMIN HOME SCREEN
// ============================================================================

class AdminHomeScreen extends StatefulWidget {
  const AdminHomeScreen({super.key});

  @override
  State<AdminHomeScreen> createState() => _AdminHomeScreenState();
}

class _AdminHomeScreenState extends State<AdminHomeScreen> {
  final _repo = AdminHomeRepository();

  List<Branch> _branches = [];
  String? _selectedBranchId; // null = All Branches
  late Future<AdminHomeData> _dataFuture;

  @override
  void initState() {
    super.initState();
    _dataFuture = _repo.fetchAdminHomeData();
    _loadBranches();
  }

  Future<void> _loadBranches() async {
    final branches = await _repo.fetchBranches();
    if (mounted) setState(() => _branches = branches);
  }

  void _onBranchChanged(String? branchId) {
    setState(() {
      _selectedBranchId = branchId;
      _dataFuture = _repo.fetchAdminHomeData(branchId: branchId);
    });
  }

  Future<void> _refresh() async {
    setState(() {
      _dataFuture = _repo.fetchAdminHomeData(branchId: _selectedBranchId);
    });
    await _dataFuture;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= _kDesktopBreakpoint;
        return Container(
          color: _kBg,
          constraints: BoxConstraints(
            minWidth: constraints.maxWidth,
            minHeight: constraints.maxHeight,
          ),
          child: SafeArea(
            child: RefreshIndicator(
              onRefresh: _refresh,
              color: _kPrimary,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(
                  horizontal: isDesktop ? 32 : 18,
                  vertical: isDesktop ? 28 : 18,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: isDesktop ? 1080 : double.infinity,
                      ),
                      child: FutureBuilder<AdminHomeData>(
                        future: _dataFuture,
                        builder: (context, snapshot) {
                          final header = _Header(
                            branches: _branches,
                            selectedBranchId: _selectedBranchId,
                            onBranchChanged: _onBranchChanged,
                          );

                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                header,
                                const SizedBox(height: 60),
                                const Center(
                                  child: Padding(
                                    padding: EdgeInsets.only(top: 40),
                                    child: CircularProgressIndicator(
                                      color: _kPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            );
                          }

                          if (snapshot.hasError) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                header,
                                const SizedBox(height: 40),
                                _ErrorState(
                                  message: '${snapshot.error}',
                                  onRetry: _refresh,
                                ),
                              ],
                            );
                          }

                          final data = snapshot.data ?? AdminHomeData.empty;
                          return isDesktop
                              ? _DesktopLayout(data: data, header: header)
                              : _MobileLayout(data: data, header: header);
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Couldn\'t load the dashboard',
            style: _sans(14, weight: FontWeight.w600, color: _kInk),
          ),
          const SizedBox(height: 6),
          Text(message, style: _sans(12.5, color: _kInkMuted)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

// ============================================================================
// HEADER + BRANCH FILTER
// ============================================================================

class _Header extends StatelessWidget {
  final List<Branch> branches;
  final String? selectedBranchId;
  final ValueChanged<String?> onBranchChanged;
  const _Header({
    required this.branches,
    required this.selectedBranchId,
    required this.onBranchChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          'Business Overview',
          style: _sans(22, weight: FontWeight.w700, color: _kInk),
        ),
        const Spacer(),
        _BranchDropdown(
          branches: branches,
          selectedId: selectedBranchId,
          onChanged: onBranchChanged,
        ),
      ],
    );
  }
}

class _BranchDropdown extends StatelessWidget {
  final List<Branch> branches;
  final String? selectedId;
  final ValueChanged<String?> onChanged;
  const _BranchDropdown({
    required this.branches,
    required this.selectedId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(9),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: selectedId,
          icon: const Icon(
            Icons.keyboard_arrow_down,
            size: 18,
            color: _kInkMuted,
          ),
          style: _sans(13.5, weight: FontWeight.w500, color: _kInk),
          hint: Text(
            'All Branches',
            style: _sans(13.5, weight: FontWeight.w500, color: _kInk),
          ),
          onChanged: onChanged,
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('All Branches'),
            ),
            ...branches.map(
              (b) =>
                  DropdownMenuItem<String?>(value: b.id, child: Text(b.name)),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// MOBILE LAYOUT
// ============================================================================

class _MobileLayout extends StatelessWidget {
  final AdminHomeData data;
  final Widget header;
  const _MobileLayout({required this.data, required this.header});

  @override
  Widget build(BuildContext context) {
    return Column(
      // stretch (not start) — makes every child, including the branch
      // sales card and the attention card, take the full column width.
      // Without this each card's width is only as wide as its own content
      // happens to lay out to, which is why they could end up mismatched.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Sales today',
                value: 'MK ${_formatMk(data.salesToday)}',
                sub: '${data.salesTransactionsToday} transactions',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                label: 'Credit given today',
                value: 'MK ${_formatMk(data.creditToday)}',
                sub: '${data.creditSalesToday} credit sales',
                valueColor: _kDebtColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _StatCard(
          label: 'Expenses today',
          value: 'MK ${_formatMk(data.expensesToday)}',
          sub:
              '${data.expensesCountToday} ${data.expensesCountToday == 1 ? 'expense' : 'expenses'} recorded',
        ),
        const SizedBox(height: 22),
        _SectionLabel('Sales by branch'),
        const SizedBox(height: 10),
        _BranchSalesList(branches: data.branchSales),
        const SizedBox(height: 22),
        _ExpensesSection(
          expenses: data.recentExpenses,
          expensesToday: data.expensesToday,
        ),
        const SizedBox(height: 22),
        _AttentionButton(
          count: data.attentionItems.length,
          onTap: () => _openAttentionPage(context),
        ),
        const SizedBox(height: 12),
        const _StockAccessCard(),
        const SizedBox(height: 24),
      ],
    );
  }
}

// ============================================================================
// DESKTOP LAYOUT
// ============================================================================

class _DesktopLayout extends StatelessWidget {
  final AdminHomeData data;
  final Widget header;
  const _DesktopLayout({required this.data, required this.header});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Sales today',
                value: 'MK ${_formatMk(data.salesToday)}',
                sub: '${data.salesTransactionsToday} transactions',
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _StatCard(
                label: 'Credit given today',
                value: 'MK ${_formatMk(data.creditToday)}',
                sub: '${data.creditSalesToday} credit sales',
                valueColor: _kDebtColor,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _StatCard(
                label: 'Expenses today',
                value: 'MK ${_formatMk(data.expensesToday)}',
                sub:
                    '${data.expensesCountToday} ${data.expensesCountToday == 1 ? 'expense' : 'expenses'} recorded',
              ),
            ),
          ],
        ),
        const SizedBox(height: 28),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionLabel('Sales by branch'),
                    const SizedBox(height: 10),
                    _BranchSalesList(branches: data.branchSales),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                flex: 6,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _SectionLabel(
                          'Needs attention (${data.attentionItems.length})',
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => _openAttentionPage(context),
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            'View all',
                            style: _sans(
                              12.5,
                              weight: FontWeight.w600,
                              color: _kPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _AttentionInlineList(
                      items: data.attentionItems.take(4).toList(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        _ExpensesSection(
          expenses: data.recentExpenses,
          expensesToday: data.expensesToday,
        ),
        const SizedBox(height: 12),
        const _StockAccessCard(),
      ],
    );
  }
}

void _openAttentionPage(BuildContext context) {
  inventoryAttentionRequest.value = true;
  AdminShell.switchTo(context, 1);
}

// ============================================================================
// SHARED PIECES
// ============================================================================

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: _sans(13, weight: FontWeight.w600, color: _kInkMuted),
  );
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final Color? valueColor;
  const _StatCard({
    required this.label,
    required this.value,
    required this.sub,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: _sans(12.5, color: _kInkMuted)),
          const SizedBox(height: 8),
          Text(
            value,
            style: _mono(
              21,
              weight: FontWeight.w600,
              color: valueColor ?? _kInk,
            ),
          ),
          const SizedBox(height: 4),
          Text(sub, style: _sans(11.5, color: _kInkMuted)),
        ],
      ),
    );
  }
}

// Ascending order — smallest-selling branch first, as requested.
class _BranchSalesList extends StatelessWidget {
  final List<BranchSalesSummary> branches;
  const _BranchSalesList({required this.branches});

  @override
  Widget build(BuildContext context) {
    if (branches.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(16),
        child: Text('No branches found.', style: _sans(13, color: _kInkMuted)),
      );
    }
    final sorted = [...branches]
      ..sort((a, b) => a.salesToday.compareTo(b.salesToday));
    final maxVal = sorted.last.salesToday <= 0 ? 1.0 : sorted.last.salesToday;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: List.generate(sorted.length, (i) {
          final b = sorted[i];
          final ratio = (b.salesToday / maxVal).clamp(0.0, 1.0);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            decoration: BoxDecoration(
              border: i == sorted.length - 1
                  ? null
                  : const Border(bottom: BorderSide(color: _kBorder)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        b.branchName,
                        style: _sans(
                          13.5,
                          weight: FontWeight.w500,
                          color: _kInk,
                        ),
                      ),
                    ),
                    Text(
                      'MK ${_formatMk(b.salesToday)}',
                      style: _mono(13.5, weight: FontWeight.w600, color: _kInk),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: ratio,
                    minHeight: 5,
                    backgroundColor: const Color(0xFFE4EAFB),
                    valueColor: const AlwaysStoppedAnimation<Color>(_kPrimary),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

// ============================================================================
// EXPENSES
// ============================================================================

void _openExpensesSheet(BuildContext context, List<ExpenseRecord> expenses) {
  showAdaptiveSheet(
    context,
    builder: (_) => SheetFrame(
      title: 'All expenses',
      subtitle:
          '${expenses.length} ${expenses.length == 1 ? 'record' : 'records'} · latest first',
      child: ExpensesSheetContent(expenses: expenses),
    ),
  );
}

class _ExpensesSection extends StatelessWidget {
  final List<ExpenseRecord> expenses;
  final double expensesToday;
  const _ExpensesSection({required this.expenses, required this.expensesToday});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _SectionLabel(
                'Expenses · MK ${_formatMk(expensesToday)} today',
              ),
            ),
            const SizedBox(width: 12),
            if (expenses.length > 5)
              TextButton(
                onPressed: () => _openExpensesSheet(context, expenses),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'View all',
                  style: _sans(12.5, weight: FontWeight.w600, color: _kPrimary),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _ExpenseList(
          expenses: expenses.take(5).toList(),
          showViewAll: expenses.length > 5,
        ),
      ],
    );
  }
}

class _ExpenseList extends StatelessWidget {
  final List<ExpenseRecord> expenses;
  final bool showViewAll;
  const _ExpenseList({required this.expenses, this.showViewAll = false});

  @override
  Widget build(BuildContext context) {
    if (expenses.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(16),
        child: Text(
          'No expenses recorded for this filter.',
          style: _sans(13, color: _kInkMuted),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: List.generate(expenses.length, (i) {
          final last = i == expenses.length - 1 && !showViewAll;
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: last
                  ? null
                  : const Border(bottom: BorderSide(color: _kBorder)),
            ),
            child: _ExpenseRow(expense: expenses[i]),
          );
        }),
      ),
    );
  }
}

class _ExpenseRow extends StatelessWidget {
  final ExpenseRecord expense;
  const _ExpenseRow({required this.expense});

  @override
  Widget build(BuildContext context) {
    final title = expense.description.trim().isNotEmpty
        ? expense.description.trim()
        : expense.category;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: const Color(0xFFF0F4FD),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            _expenseIcon(expense.category),
            size: 18,
            color: _kPrimary,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: _sans(13.5, weight: FontWeight.w500, color: _kInk),
              ),
              const SizedBox(height: 2),
              Text(
                '${expense.branchName} · ${expense.category} · ${_formatDate(expense.expenseDate)}',
                style: _sans(12, color: _kInkMuted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(
          'MK ${_formatMk(expense.amount)}',
          style: _mono(13.5, weight: FontWeight.w600, color: _kInk),
        ),
      ],
    );
  }
}

class ExpensesSheetContent extends StatelessWidget {
  final List<ExpenseRecord> expenses;
  const ExpensesSheetContent({super.key, required this.expenses});

  @override
  Widget build(BuildContext context) {
    if (expenses.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'No expenses here.',
            style: _sans(13.5, color: _kInkMuted),
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: expenses.length,
        separatorBuilder: (ctx, index) =>
            const Divider(height: 1, color: _kBorder),
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: _ExpenseRow(expense: expenses[i]),
        ),
      ),
    );
  }
}

// Mobile: single collapsed summary button that opens the full list elsewhere.
class _AttentionButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _AttentionButton({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: _kBorder),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: const Color(0xFFFBF0E2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.warning_amber_rounded,
                  size: 18,
                  color: _kWarnColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$count things need attention',
                      style: _sans(14, weight: FontWeight.w600, color: _kInk),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Low stock and expiring batches',
                      style: _sans(12, color: _kInkMuted),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 20, color: _kInkMuted),
            ],
          ),
        ),
      ),
    );
  }
}

// Home "Stock access" card: waiting + active counts, opens the Pending tab.
class _StockAccessCard extends StatelessWidget {
  const _StockAccessCard();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<StockAccessRequest>>(
      future: StockAccessRepository().fetchAll(),
      builder: (context, snap) {
        final rows = snap.data ?? [];
        final waiting = rows.where((r) => r.isPending).length;
        final active = rows.where((r) => r.isActive).length;
        // Keep the Users nav badge fresh even if the Users tab never opens.
        if (snap.hasData) stockAccessPendingCount.value = waiting;
        final title = snap.hasError
            ? 'Stock access'
            : waiting == 0 && active == 0
            ? 'No stock access requests'
            : '$waiting waiting · $active active';
        return Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              stockAccessInitialTab.value = 0; // Pending tab
              AdminShell.switchTo(context, 3); // Users tab
            },
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: _kBorder),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: waiting > 0
                          ? const Color(0xFFFBF0E2)
                          : const Color(0xFFE4EAFB),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.key_outlined,
                      size: 18,
                      color: waiting > 0 ? _kWarnColor : _kPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: _sans(
                            14,
                            weight: FontWeight.w600,
                            color: _kInk,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Cashier stock permissions',
                          style: _sans(12, color: _kInkMuted),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right, size: 20, color: _kInkMuted),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// Desktop: a short inline preview list (rest reachable via "View all").
class _AttentionInlineList extends StatelessWidget {
  final List<AttentionItem> items;
  const _AttentionInlineList({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.all(16),
        child: Text(
          'Nothing needs attention right now.',
          style: _sans(13, color: _kInkMuted),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: List.generate(items.length, (i) {
          final item = items[i];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              border: i == items.length - 1
                  ? null
                  : const Border(bottom: BorderSide(color: _kBorder)),
            ),
            child: _AttentionRow(item: item),
          );
        }),
      ),
    );
  }
}

class _AttentionRow extends StatelessWidget {
  final AttentionItem item;
  const _AttentionRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final isLow = item.type == AttentionType.lowStock;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(top: 3),
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isLow ? _kWarnColor : _kDebtColor,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.itemName,
                style: _sans(13.5, weight: FontWeight.w500, color: _kInk),
              ),
              const SizedBox(height: 2),
              Text(
                '${item.branchName} · ${item.detail}',
                style: _sans(12, color: _kInkMuted),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: isLow ? const Color(0xFFFBF0E2) : const Color(0xFFF7E8E6),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            isLow ? 'Low stock' : 'Expiring',
            style: _sans(
              10.5,
              weight: FontWeight.w600,
              color: isLow ? _kWarnColor : _kDebtColor,
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// ATTENTION DETAIL (ADAPTIVE SHEET & DETAIL PAGE)
// ============================================================================

class AttentionDetailContent extends StatefulWidget {
  final List<AttentionItem> items;
  const AttentionDetailContent({super.key, required this.items});

  @override
  State<AttentionDetailContent> createState() => _AttentionDetailContentState();
}

class _AttentionDetailContentState extends State<AttentionDetailContent> {
  AttentionType? _filter;

  @override
  Widget build(BuildContext context) {
    final filtered = _filter == null
        ? widget.items
        : widget.items.where((i) => i.type == _filter).toList();
    final lowCount = widget.items
        .where((i) => i.type == AttentionType.lowStock)
        .length;
    final expCount = widget.items
        .where((i) => i.type == AttentionType.expiring)
        .length;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _FilterChip(
                label: 'All (${widget.items.length})',
                selected: _filter == null,
                onTap: () => setState(() => _filter = null),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: 'Low stock ($lowCount)',
                selected: _filter == AttentionType.lowStock,
                onTap: () => setState(() => _filter = AttentionType.lowStock),
              ),
              const SizedBox(width: 8),
              _FilterChip(
                label: 'Expiring ($expCount)',
                selected: _filter == AttentionType.expiring,
                onTap: () => setState(() => _filter = AttentionType.expiring),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'Nothing here.',
                style: _sans(13.5, color: _kInkMuted),
              ),
            ),
          )
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 420),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: filtered.length,
              separatorBuilder: (ctx, index) =>
                  const Divider(height: 1, color: _kBorder),
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: _AttentionRow(item: filtered[i]),
              ),
            ),
          ),
      ],
    );
  }
}

class AttentionDetailScreen extends StatefulWidget {
  final List<AttentionItem> items;
  const AttentionDetailScreen({super.key, required this.items});

  @override
  State<AttentionDetailScreen> createState() => _AttentionDetailScreenState();
}

class _AttentionDetailScreenState extends State<AttentionDetailScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: _kInk,
        title: Text(
          'Needs attention',
          style: _sans(16, weight: FontWeight.w700, color: _kInk),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: AttentionDetailContent(items: widget.items),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? _kPrimary : Colors.transparent,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: selected ? _kPrimary : _kBorder),
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
          child: Text(
            label,
            style: _sans(
              12,
              weight: FontWeight.w600,
              color: selected ? Colors.white : _kInkMuted,
            ),
          ),
        ),
      ),
    );
  }
}
