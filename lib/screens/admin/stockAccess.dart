import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../widgets/adminShell.dart';
import 'adminui.dart';
import 'stockAccessRepo.dart';

// ============================================================================
// STOCK ACCESS — admin side of cashier stock permissions. Lives in the Users
// tab next to the staff list (a different queue from account approvals).
//   Pending: newest first, Approve (duration dialog) / Deny (confirm).
//   Active: countdown or "Until removed", Remove access (confirm), amber
//     highlight when unlimited access runs past a day.
//   History: every outcome + who decided, branch/cashier/status/date filters.
// Detail + View-activity open in sheets (dialog on desktop). View-activity
// jumps to Inventory's Movements tab filtered to that cashier + period.
// ============================================================================

String _fmtWhen(DateTime dt) => DateFormat('d MMM yyyy, HH:mm').format(dt.toLocal());
String _fmtDay(DateTime dt) => DateFormat('d MMM yyyy').format(dt.toLocal());

class StockAccessSection extends StatefulWidget {
  final int initialTab;
  const StockAccessSection({super.key, this.initialTab = 0});

  @override
  State<StockAccessSection> createState() => _StockAccessSectionState();
}

class _StockAccessSectionState extends State<StockAccessSection> {
  final _repo = StockAccessRepository();
  List<StockAccessRequest> _all = [];
  bool _loading = true;
  String? _error;
  int _tab = 0;

  // History filters.
  String? _branch;
  String _cashier = '';
  String _status = 'all';
  DateTime? _day;
  final _cashierCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab.clamp(0, 2);
    _load(silent: true);
  }

  @override
  void dispose() {
    _cashierCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final rows = await _repo.fetchAll();
      if (!mounted) return;
      setState(() {
        _all = rows;
        _loading = false;
        _error = null;
      });
      stockAccessPendingCount.value = rows.where((r) => r.isPending).length;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<StockAccessRequest> get _pending {
    final list = _all.where((r) => r.isPending).toList();
    list.sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
    return list;
  }

  List<StockAccessRequest> get _active {
    final list = _all.where((r) => r.isActive).toList();
    list.sort((a, b) {
      // Timed access first (soonest ending), then unlimited.
      final ae = a.expiresAt;
      final be = b.expiresAt;
      if (ae == null && be == null) return 0;
      if (ae == null) return 1;
      if (be == null) return -1;
      return ae.compareTo(be);
    });
    return list;
  }

  List<StockAccessRequest> get _history {
    final q = _cashier.trim().toLowerCase();
    final list = _all.where((r) {
      if (r.isPending) return false;
      if (_branch != null && r.branchId != _branch) return false;
      if (q.isNotEmpty && !r.userName.toLowerCase().contains(q)) return false;
      switch (_status) {
        case 'active':
          if (!r.isActive) return false;
        case 'denied':
          if (r.effectiveStatus != 'denied') return false;
        case 'removed':
          if (!(r.effectiveStatus == 'revoked' && !r.endedByCashier)) return false;
        case 'ended':
          if (!(r.effectiveStatus == 'revoked' && r.endedByCashier)) return false;
        case 'expired':
          if (r.effectiveStatus != 'expired') return false;
      }
      if (_day != null) {
        final d = r.requestedAt.toLocal();
        if (d.year != _day!.year || d.month != _day!.month || d.day != _day!.day) return false;
      }
      return true;
    }).toList();
    list.sort((a, b) => b.requestedAt.compareTo(a.requestedAt));
    return list;
  }

  // ---- Actions -------------------------------------------------------------------

  Future<void> _approve(StockAccessRequest r) async {
    final hours = await showAdaptiveSheet<int?>(
      context,
      builder: (_) => _DurationSheet(userName: r.userName),
    );
    if (hours == _DurationSheet.cancelled) return;
    try {
      await _repo.decide(requestId: r.id, approve: true, hours: hours);
      await _load(silent: true);
      if (mounted) {
        showToast(context,
            hours == null ? '${r.userName} can change stock until removed.' : '${r.userName} can change stock for $hours hour${hours == 1 ? '' : 's'}.');
      }
    } on StockAccessException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  Future<void> _deny(StockAccessRequest r) async {
    final ok = await showConfirm(
      context,
      title: 'Deny ${r.userName}’s request?',
      message: 'They will stay without stock access. This is recorded in History.',
      confirmLabel: 'Deny request',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _repo.decide(requestId: r.id, approve: false);
      await _load(silent: true);
      if (mounted) showToast(context, 'Request denied.');
    } on StockAccessException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  Future<void> _remove(StockAccessRequest r) async {
    final ok = await showConfirm(
      context,
      title: 'Remove ${r.userName}’s access?',
      message: 'They will immediately lose the ability to change stock at ${r.branchName}. This is recorded in History.',
      confirmLabel: 'Remove access',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _repo.revoke(requestId: r.id);
      await _load(silent: true);
      if (mounted) showToast(context, 'Access removed.');
    } on StockAccessException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  void _openDetail(StockAccessRequest r) {
    showAdaptiveSheet<void>(
      context,
      builder: (_) => SheetFrame(
        title: r.userName,
        subtitle: '${r.branchName} · requested ${_fmtWhen(r.requestedAt)}',
        child: _DetailBody(
          request: r,
          onApprove: r.isPending ? () => _approve(r) : null,
          onDeny: r.isPending ? () => _deny(r) : null,
          onRemove: r.isActive ? () => _remove(r) : null,
          onActivity: (r.isActive || (r.effectiveStatus != 'denied' && r.decidedAt != null))
              ? () => _viewActivity(r, closeSheet: true)
              : null,
        ),
      ),
    ).then((_) {
      if (mounted) _load(silent: true);
    });
  }

  void _viewActivity(StockAccessRequest r, {bool closeSheet = false}) {
    if (closeSheet) Navigator.of(context).pop(); // detail sheet is open
    final w = r.activityWindow();
    stockActivityFilter.value = StockActivityFilter(
      userId: r.userId,
      userName: r.userName,
      from: w.from,
      to: w.to,
    );
    AdminShell.switchTo(context, 1); // Inventory tab
  }

  // ---- Build -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(child: CircularProgressIndicator(color: kPrimary)),
      );
    }
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);

    final pending = _pending;
    final labels = ['Pending (${pending.length})', 'Active (${_active.length})', 'History'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Stock access',
                  style: sans(17, weight: FontWeight.w700, color: kInk)),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 19, color: kInkMuted),
              tooltip: 'Refresh',
              onPressed: () => _load(),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text('Temporary stock permission for cashiers — separate from account approvals.',
            style: sans(12.5, color: kInkMuted)),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (int i = 0; i < 3; i++) ...[
                FilterPill(label: labels[i], selected: _tab == i, onTap: () => setState(() => _tab = i)),
                if (i < 2) const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        if (_tab == 0) _pendingList(pending),
        if (_tab == 1) _activeList(_active),
        if (_tab == 2) _historyList(),
      ],
    );
  }

  Widget _pendingList(List<StockAccessRequest> rows) {
    if (rows.isEmpty) {
      return const EmptyState(
        icon: Icons.key_outlined,
        title: 'No requests waiting',
        message: 'When a cashier asks for stock access, it will appear here.',
      );
    }
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= kWideContentBreakpoint;
      if (wide) {
        return Container(
          decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (int i = 0; i < rows.length; i++)
                _RequestRow(
                  request: rows[i],
                  isLast: i == rows.length - 1,
                  onTap: () => _openDetail(rows[i]),
                  onApprove: () => _approve(rows[i]),
                  onDeny: () => _deny(rows[i]),
                ),
            ],
          ),
        );
      }
      return Column(
        children: [
          for (final r in rows) ...[
            _RequestCard(request: r, onTap: () => _openDetail(r), onApprove: () => _approve(r), onDeny: () => _deny(r)),
            const SizedBox(height: 10),
          ],
        ],
      );
    });
  }

  Widget _activeList(List<StockAccessRequest> rows) {
    if (rows.isEmpty) {
      return const EmptyState(
        icon: Icons.verified_outlined,
        title: 'Nobody has stock access',
        message: 'Approved cashiers will appear here until their access ends.',
      );
    }
    return LayoutBuilder(builder: (context, c) {
      final wide = c.maxWidth >= kWideContentBreakpoint;
      if (wide) {
        return Container(
          decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (int i = 0; i < rows.length; i++)
                _ActiveRow(
                  request: rows[i],
                  isLast: i == rows.length - 1,
                  onTap: () => _openDetail(rows[i]),
                  onRemove: () => _remove(rows[i]),
                  onActivity: () => _viewActivity(rows[i]),
                ),
            ],
          ),
        );
      }
      return Column(
        children: [
          for (final r in rows) ...[
            _ActiveCard(
              request: r,
              onTap: () => _openDetail(r),
              onRemove: () => _remove(r),
              onActivity: () => _viewActivity(r),
            ),
            const SizedBox(height: 10),
          ],
        ],
      );
    });
  }

  Widget _historyList() {
    final branches = <String, String>{};
    for (final r in _all) {
      branches[r.branchId] = r.branchName;
    }
    final rows = _history;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: kBorder),
                borderRadius: BorderRadius.circular(20),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: _branch,
                  style: sans(12.5, weight: FontWeight.w600, color: kInkMuted),
                  hint: Text('All branches', style: sans(12.5, weight: FontWeight.w600, color: kInkMuted)),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('All branches')),
                    for (final e in branches.entries)
                      DropdownMenuItem<String?>(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => _branch = v),
                ),
              ),
            ),
            SizedBox(
              width: 170,
              child: TextField(
                controller: _cashierCtrl,
                onChanged: (v) => setState(() => _cashier = v),
                style: sans(12.5, color: kInk),
                decoration: InputDecoration(
                  hintText: 'Cashier…',
                  hintStyle: sans(12.5, color: kInkMuted),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(color: kBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: const BorderSide(color: kBorder),
                  ),
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final d = await showDatePicker(
                  context: context,
                  initialDate: _day ?? DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now().add(const Duration(days: 1)),
                );
                if (d != null && mounted) setState(() => _day = d);
              },
              style: outlineButtonStyle(height: 36),
              icon: const Icon(Icons.calendar_month_outlined, size: 16),
              label: Text(_day == null ? 'Date' : _fmtDay(_day!)),
            ),
            if (_day != null)
              IconButton(
                icon: const Icon(Icons.clear, size: 16, color: kInkMuted),
                tooltip: 'Clear date',
                onPressed: () => setState(() => _day = null),
              ),
          ],
        ),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final (v, label) in [
                ('all', 'All'),
                ('active', 'Active'),
                ('denied', 'Denied'),
                ('removed', 'Removed'),
                ('ended', 'Ended by cashier'),
                ('expired', 'Expired'),
              ]) ...[
                FilterPill(label: label, selected: _status == v, onTap: () => setState(() => _status = v)),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          const EmptyState(
            icon: Icons.history_outlined,
            title: 'No matching records',
            message: 'Try a different branch, cashier, status or date.',
          )
        else
          Container(
            decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (int i = 0; i < rows.length; i++)
                  _HistoryRow(
                    request: rows[i],
                    isLast: i == rows.length - 1,
                    onTap: () => _openDetail(rows[i]),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ============================================================================
// STATUS PILLS + COUNTDOWN
// ============================================================================

Widget _outcomePill(StockAccessRequest r) {
  switch (r.effectiveStatus) {
    case 'pending':
      return StatusPill.warning('Waiting', icon: Icons.hourglass_top_outlined);
    case 'approved':
      return StatusPill.active('Active');
    case 'denied':
      return StatusPill.danger('Denied');
    case 'revoked':
      return r.endedByCashier
          ? StatusPill.neutral('Ended by cashier', icon: Icons.check_outlined)
          : StatusPill.neutral('Removed', icon: Icons.block_outlined);
    default:
      return StatusPill.neutral('Expired', icon: Icons.schedule_outlined);
  }
}

String _timeAgo(DateTime dt) {
  final d = DateTime.now().difference(dt);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return _fmtDay(dt);
}

// ============================================================================
// PENDING ROWS / CARDS
// ============================================================================

class _RequestRow extends StatelessWidget {
  final StockAccessRequest request;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onApprove;
  final VoidCallback onDeny;
  const _RequestRow({
    required this.request,
    required this.isLast,
    required this.onTap,
    required this.onApprove,
    required this.onDeny,
  });

  @override
  Widget build(BuildContext context) {
    final r = request;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          border: isLast ? null : const Border(bottom: BorderSide(color: kBorder)),
        ),
        child: Row(
          children: [
            Avatar(name: r.userName, radius: 17),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.userName, style: sans(14, weight: FontWeight.w600, color: kInk)),
                  Text('${r.branchName} · asked ${_timeAgo(r.requestedAt)}',
                      style: sans(12, color: kInkMuted)),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Text(
                r.reason.isEmpty ? 'No reason given.' : '“${r.reason}”',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: sans(13, color: kInk, height: 1.35),
              ),
            ),
            const SizedBox(width: 12),
            _outcomePill(r),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: onDeny,
              style: outlineButtonStyle(height: 36),
              child: const Text('Deny'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: onApprove,
              style: primaryButtonStyle(height: 36),
              child: const Text('Approve'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RequestCard extends StatelessWidget {
  final StockAccessRequest request;
  final VoidCallback onTap;
  final VoidCallback onApprove;
  final VoidCallback onDeny;
  const _RequestCard({
    required this.request,
    required this.onTap,
    required this.onApprove,
    required this.onDeny,
  });

  @override
  Widget build(BuildContext context) {
    final r = request;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
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
                Avatar(name: r.userName, radius: 17),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.userName, style: sans(14, weight: FontWeight.w600, color: kInk)),
                      Text('${r.branchName} · ${_timeAgo(r.requestedAt)}',
                          style: sans(12, color: kInkMuted)),
                    ],
                  ),
                ),
                _outcomePill(r),
              ],
            ),
            if (r.reason.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('“${r.reason}”', style: sans(13, color: kInk, height: 1.4)),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onDeny,
                    style: outlineButtonStyle(height: 44),
                    child: const Text('Deny'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: onApprove,
                    style: primaryButtonStyle(height: 44),
                    child: const Text('Approve'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// ACTIVE ROWS / CARDS
// ============================================================================

class _ActiveRow extends StatelessWidget {
  final StockAccessRequest request;
  final bool isLast;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onActivity;
  const _ActiveRow({
    required this.request,
    required this.isLast,
    required this.onTap,
    required this.onRemove,
    required this.onActivity,
  });

  @override
  Widget build(BuildContext context) {
    final r = request;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: r.isStaleUnlimited ? kWarnTint.withValues(alpha: 0.35) : Colors.white,
          border: isLast ? null : const Border(bottom: BorderSide(color: kBorder)),
        ),
        child: Row(
          children: [
            Avatar(name: r.userName, radius: 17),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.userName, style: sans(14, weight: FontWeight.w600, color: kInk)),
                  Text(r.branchName, style: sans(12, color: kInkMuted)),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.countdownLabel(),
                      style: sans(13, weight: FontWeight.w700, color: r.isStaleUnlimited ? kWarn : kSuccess)),
                  Text(
                    'since ${_fmtWhen(r.decidedAt ?? r.requestedAt)}${r.decidedByName != null ? ' · by ${r.decidedByName}' : ''}',
                    style: sans(12, color: kInkMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: onActivity,
              child: Text('View activity', style: sans(13, weight: FontWeight.w600, color: kPrimary)),
            ),
            const SizedBox(width: 4),
            OutlinedButton(
              onPressed: onRemove,
              style: OutlinedButton.styleFrom(
                foregroundColor: kDanger,
                minimumSize: const Size(0, 36),
                side: const BorderSide(color: kBorder),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Remove access'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveCard extends StatelessWidget {
  final StockAccessRequest request;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onActivity;
  const _ActiveCard({
    required this.request,
    required this.onTap,
    required this.onRemove,
    required this.onActivity,
  });

  @override
  Widget build(BuildContext context) {
    final r = request;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: r.isStaleUnlimited ? kWarnTint.withValues(alpha: 0.35) : Colors.white,
          border: Border.all(color: r.isStaleUnlimited ? kWarn : kBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Avatar(name: r.userName, radius: 17),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(r.userName, style: sans(14, weight: FontWeight.w600, color: kInk)),
                      Text(r.branchName, style: sans(12, color: kInkMuted)),
                    ],
                  ),
                ),
                StatusPill.active('Active'),
              ],
            ),
            const SizedBox(height: 8),
            Text(r.countdownLabel(),
                style: sans(14, weight: FontWeight.w700, color: r.isStaleUnlimited ? kWarn : kSuccess)),
            Text(
              'since ${_fmtWhen(r.decidedAt ?? r.requestedAt)}${r.decidedByName != null ? ' · by ${r.decidedByName}' : ''}',
              style: sans(12, color: kInkMuted),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onActivity,
                    style: outlineButtonStyle(height: 44),
                    child: const Text('View activity'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: onRemove,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: kDanger,
                      minimumSize: const Size(0, 44),
                      side: const BorderSide(color: kBorder),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Remove access'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// HISTORY ROW
// ============================================================================

class _HistoryRow extends StatelessWidget {
  final StockAccessRequest request;
  final bool isLast;
  final VoidCallback onTap;
  const _HistoryRow({required this.request, required this.isLast, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final r = request;
    final decided = r.decidedByName != null ? ' · by ${r.decidedByName}' : '';
    final ended = r.revokedByName != null ? ' · ended by ${r.revokedByName}' : '';
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: Colors.white,
          border: isLast ? null : const Border(bottom: BorderSide(color: kBorder)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.userName, style: sans(13.5, weight: FontWeight.w600, color: kInk)),
                  const SizedBox(height: 2),
                  Text('${r.branchName} · asked ${_fmtWhen(r.requestedAt)}$decided$ended',
                      style: sans(12, color: kInkMuted)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _outcomePill(r),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right, size: 18, color: kInkMuted),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// DETAIL BODY (timeline + actions)
// ============================================================================

class _DetailBody extends StatelessWidget {
  final StockAccessRequest request;
  final VoidCallback? onApprove;
  final VoidCallback? onDeny;
  final VoidCallback? onRemove;
  final VoidCallback? onActivity;
  const _DetailBody({
    required this.request,
    required this.onApprove,
    required this.onDeny,
    required this.onRemove,
    required this.onActivity,
  });

  @override
  Widget build(BuildContext context) {
    final r = request;
    final activity = onActivity;
    final approve = onApprove;
    final deny = onDeny;
    final remove = onRemove;
    Widget line(String label, String value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 110, child: Text(label, style: sans(12.5, color: kInkMuted))),
            Expanded(child: Text(value, style: sans(13, weight: FontWeight.w500, color: kInk))),
          ],
        ),
      );
    }

    final endLabel = r.revokedAt != null
        ? _fmtWhen(r.revokedAt!)
        : (r.expiresAt != null ? _fmtWhen(r.expiresAt!) : 'Until removed');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Avatar(name: r.userName, radius: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.userName, style: sans(15, weight: FontWeight.w700, color: kInk)),
                  Text(r.branchName, style: sans(12.5, color: kInkMuted)),
                ],
              ),
            ),
            _outcomePill(r),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(10)),
          child: Text(
            r.reason.isEmpty ? 'No reason given.' : '“${r.reason}”',
            style: sans(13.5, color: kInk, height: 1.45),
          ),
        ),
        const SizedBox(height: 16),
        line('Requested', _fmtWhen(r.requestedAt)),
        if (r.decidedAt != null)
          line('Decided', '${_fmtWhen(r.decidedAt!)}${r.decidedByName != null ? ' · ${r.decidedByName}' : ''}'),
        if (r.isActive) line('Ends', r.countdownLabel()),
        if (!r.isPending && !r.isActive) line('Ended', '$endLabel${r.revokedByName != null ? ' · ${r.revokedByName}' : ''}'),
        const SizedBox(height: 8),
        if (activity != null)
          OutlinedButton.icon(
            onPressed: activity,
            style: outlineButtonStyle(),
            icon: const Icon(Icons.history_outlined, size: 18),
            label: const Text('View activity'),
          ),
        if (approve != null || deny != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              if (deny != null)
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      deny();
                    },
                    style: outlineButtonStyle(),
                    child: const Text('Deny'),
                  ),
                ),
              if (deny != null && approve != null) const SizedBox(width: 10),
              if (approve != null)
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      approve();
                    },
                    style: primaryButtonStyle(),
                    child: const Text('Approve'),
                  ),
                ),
            ],
          ),
        ],
        if (remove != null) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () {
              Navigator.of(context).pop();
              remove();
            },
            style: OutlinedButton.styleFrom(
              foregroundColor: kDanger,
              minimumSize: const Size(0, 44),
              side: const BorderSide(color: kBorder),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('Remove access'),
          ),
        ],
      ],
    );
  }
}

// ============================================================================
// DURATION SHEET — 1h / 4h / 8h / custom / until removed (4h suggested)
// ============================================================================

class _DurationSheet extends StatefulWidget {
  static const cancelled = -999;
  final String userName;
  const _DurationSheet({required this.userName});

  @override
  State<_DurationSheet> createState() => _DurationSheetState();
}

class _DurationSheetState extends State<_DurationSheet> {
  int? _hours = 4; // suggested default: time-boxed, hard to forget
  final _customCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _customCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_hours == -1) {
      final n = int.tryParse(_customCtrl.text.trim());
      if (n == null || n <= 0) {
        setState(() => _error = 'Enter a number of hours above zero.');
        return;
      }
      Navigator.of(context).pop(n);
      return;
    }
    Navigator.of(context).pop(_hours); // null = until removed
  }

  @override
  Widget build(BuildContext context) {
    Widget option({required String label, required String sub, required int? value}) {
      final active = _hours == value;
      return Material(
        color: active ? kPrimaryTint : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() {
            _hours = value;
            _error = null;
          }),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: active ? kPrimary : kBorder, width: active ? 1.5 : 1),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: sans(14, weight: FontWeight.w600, color: kInk)),
                      Text(sub, style: sans(12, color: kInkMuted)),
                    ],
                  ),
                ),
                if (active) const Icon(Icons.check_circle, size: 20, color: kPrimary),
              ],
            ),
          ),
        ),
      );
    }

    return SheetFrame(
      title: 'Approve access',
      subtitle: '${widget.userName} · how long should it last?',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          option(label: '1 hour', sub: 'Quick job', value: 1),
          const SizedBox(height: 8),
          option(label: '4 hours', sub: 'Suggested — ends by itself', value: 4),
          const SizedBox(height: 8),
          option(label: '8 hours', sub: 'Full shift', value: 8),
          const SizedBox(height: 8),
          option(label: 'Until I remove it', sub: 'No time limit — remember to remove', value: null),
          const SizedBox(height: 8),
          Material(
            color: _hours == -1 ? kPrimaryTint : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _hours = -1),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _hours == -1 ? kPrimary : kBorder, width: _hours == -1 ? 1.5 : 1),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text('Custom hours', style: sans(14, weight: FontWeight.w600, color: kInk)),
                    ),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: _customCtrl,
                        keyboardType: TextInputType.number,
                        onTap: () => setState(() => _hours = -1),
                        onChanged: (_) {
                          if (_hours != -1) setState(() => _hours = -1);
                        },
                        style: sans(14, color: kInk),
                        decoration: InputDecoration(
                          hintText: 'e.g. 6',
                          hintStyle: sans(13, color: kInkMuted),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: kBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: kBorder),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: sans(12.5, weight: FontWeight.w600, color: kDanger)),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(_DurationSheet.cancelled),
                  style: outlineButtonStyle(),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _submit,
                  style: primaryButtonStyle(),
                  child: const Text('Approve'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
