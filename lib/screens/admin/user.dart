import 'package:flutter/material.dart';

import 'adminhomeRepo.dart';
import 'adminui.dart';
import 'assignUser.dart';

// ============================================================================
// USERS SCREEN
//   - embedded: true  (desktop shell page)  -> page title, table layout
//   - embedded: false (pushed from Settings on phones) -> AppBar, card layout
//   Layout follows the available width, so it also adapts if the window is
//   resized or the phone is rotated.
//
//   Actions per user (none on your own account):
//     Assign role / change branch or role       -> marks the account active
//       (cashier or stock controller need a branch; admin needs none)
//     Remove from branch                         -> clears branch, deactivates
//     Delete user                                -> removes the account
// ============================================================================

enum _Filter { all, pending, active }

class UsersScreen extends StatefulWidget {
  final bool embedded;
  const UsersScreen({super.key, this.embedded = true});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  final _repo = AdminManagementRepository();
  List<StaffMember> _users = [];
  List<BranchInfo> _branches = [];
  bool _loading = true;
  String? _error;
  _Filter _filter = _Filter.all;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load(silent: true);
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait([_repo.fetchUsers(), _repo.fetchBranches()]);
      if (!mounted) return;
      setState(() {
        _users = results[0] as List<StaffMember>;
        _branches = results[1] as List<BranchInfo>;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<StaffMember> get _visible {
    final q = _query.trim().toLowerCase();
    return _users.where((u) {
      switch (_filter) {
        case _Filter.pending:
          if (!u.isPending) return false;
          break;
        case _Filter.active:
          if (!u.isActive) return false;
          break;
        case _Filter.all:
          break;
      }
      if (q.isEmpty) return true;
      return u.displayName.toLowerCase().contains(q) ||
          u.email.toLowerCase().contains(q) ||
          u.username.toLowerCase().contains(q) ||
          (u.branchName ?? '').toLowerCase().contains(q);
    }).toList();
  }

  // ---- actions --------------------------------------------------------------

  Future<void> _assign(StaffMember u) async {
    final activeBranches = _branches.where((b) => b.isActive).toList();
    final message = await showAdaptiveSheet<String>(
      context,
      builder: (_) => AssignUserSheet(repo: _repo, user: u, branches: activeBranches),
    );
    if (message == null) return;
    await _load(silent: true);
    if (mounted) showToast(context, message);
  }

  Future<void> _remove(StaffMember u) async {
    final ok = await showConfirm(
      context,
      title: 'Remove ${u.displayName}?',
      message:
      'They\'ll be taken off ${u.branchName ?? 'their branch'} and their account deactivated until you assign them to a branch again.',
      confirmLabel: 'Remove from branch',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _repo.removeFromBranch(u.id);
      await _load(silent: true);
      if (mounted) showToast(context, '${u.displayName} removed from ${u.branchName ?? 'branch'}.');
    } on ManagementException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  Future<void> _delete(StaffMember u) async {
    final ok = await showConfirm(
      context,
      title: 'Delete ${u.displayName}?',
      message:
      'This permanently deletes their account and sign-in. It can\'t be undone. '
          'If they have recorded sales or stock activity, the account is kept — remove them from their branch instead.',
      confirmLabel: 'Delete user',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _repo.deleteUser(u.id);
      await _load(silent: true);
      if (mounted) showToast(context, '${u.displayName} deleted.');
    } on ManagementException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  bool _isSelf(StaffMember u) => u.id == _repo.currentUserId;

  void _onMenu(String value, StaffMember u) {
    switch (value) {
      case 'assign':
        _assign(u);
        break;
      case 'remove':
        _remove(u);
        break;
      case 'delete':
        _delete(u);
        break;
    }
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final pending = _users.where((u) => u.isPending).length;
    final active = _users.where((u) => u.isActive).length;

    return Scaffold(
      backgroundColor: kBg,
      appBar: widget.embedded
          ? null
          : AppBar(
        backgroundColor: kBg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: kInk,
        title: Text('Users', style: sans(17, weight: FontWeight.w700, color: kInk)),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: kPrimary,
          onRefresh: () => _load(silent: true),
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= kWideContentBreakpoint;
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(wide ? 32 : 18, wide ? 28 : 12, wide ? 32 : 18, 32),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.embedded) ...[
                          PageTitle(
                            title: 'Users',
                            subtitle: _loading
                                ? 'Loading…'
                                : '${_users.length} accounts · $pending awaiting approval',
                          ),
                          const SizedBox(height: 20),
                        ],
                        SearchField(
                          hint: 'Search by name, email or branch',
                          onChanged: (v) => setState(() => _query = v),
                        ),
                        const SizedBox(height: 12),
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              FilterPill(
                                label: 'All (${_users.length})',
                                selected: _filter == _Filter.all,
                                onTap: () => setState(() => _filter = _Filter.all),
                              ),
                              const SizedBox(width: 8),
                              FilterPill(
                                label: 'Pending ($pending)',
                                selected: _filter == _Filter.pending,
                                onTap: () => setState(() => _filter = _Filter.pending),
                              ),
                              const SizedBox(width: 8),
                              FilterPill(
                                label: 'Active ($active)',
                                selected: _filter == _Filter.active,
                                onTap: () => setState(() => _filter = _Filter.active),
                              ),
                            ],
                          ),
                        ),
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

  Widget _body(bool wide) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: Center(child: CircularProgressIndicator(color: kPrimary)),
      );
    }
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);

    final list = _visible;
    if (list.isEmpty) {
      final searching = _query.trim().isNotEmpty || _filter != _Filter.all;
      return EmptyState(
        icon: Icons.people_outline,
        title: searching ? 'No matching users' : 'No users yet',
        message: searching
            ? 'Try a different search or filter.'
            : 'People who sign up will appear here so you can assign them to a branch.',
      );
    }

    if (wide) {
      return Container(
        decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            const _TableHeader(),
            ...List.generate(list.length, (i) {
              final u = list[i];
              return _UserRow(
                user: u,
                isLast: i == list.length - 1,
                isSelf: _isSelf(u),
                onAssign: () => _assign(u),
                onMenu: (v) => _onMenu(v, u),
              );
            }),
          ],
        ),
      );
    }

    return Column(
      children: list
          .map((u) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _UserCard(
          user: u,
          isSelf: _isSelf(u),
          onAssign: () => _assign(u),
          onMenu: (v) => _onMenu(v, u),
        ),
      ))
          .toList(),
    );
  }
}

// ============================================================================
// SHARED PIECES
// ============================================================================

Widget _statusPillFor(StaffMember u) {
  if (u.isPending) return StatusPill.pending();
  return u.isActive ? StatusPill.active() : StatusPill.inactive();
}

/// Row menu. You can't act on your own account. Other admins can be given a
/// different role or deleted.
Widget _userMenu(StaffMember u, bool isSelf, ValueChanged<String> onSelected) {
  if (isSelf) return const SizedBox(width: 40);
  final isAdmin = u.role == StaffRole.admin;
  final hasBranch = u.branchId != null;
  return PopupMenuButton<String>(
    icon: const Icon(Icons.more_vert, size: 20, color: kInkMuted),
    tooltip: 'User options',
    color: Colors.white,
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    onSelected: onSelected,
    itemBuilder: (_) => [
      _menuItem(
        'assign',
        isAdmin ? Icons.admin_panel_settings_outlined : (hasBranch ? Icons.swap_horiz : Icons.add_business_outlined),
        isAdmin ? 'Change role' : (hasBranch ? 'Change branch or role' : 'Assign role'),
      ),
      if (hasBranch && !isAdmin) _menuItem('remove', Icons.person_remove_outlined, 'Remove from branch'),
      const PopupMenuDivider(),
      _menuItem('delete', Icons.delete_outline, 'Delete user', danger: true),
    ],
  );
}

PopupMenuItem<String> _menuItem(String value, IconData icon, String label, {bool danger = false}) {
  return PopupMenuItem<String>(
    value: value,
    height: 42,
    child: Row(
      children: [
        Icon(icon, size: 18, color: danger ? kDanger : kInkMuted),
        const SizedBox(width: 10),
        Text(label, style: sans(13.5, weight: FontWeight.w500, color: danger ? kDanger : kInk)),
      ],
    ),
  );
}

// ============================================================================
// DESKTOP / WIDE — TABLE
// ============================================================================

class _TableHeader extends StatelessWidget {
  const _TableHeader();

  @override
  Widget build(BuildContext context) {
    final style = sans(12, weight: FontWeight.w600, color: kInkMuted);
    return Container(
      color: kSurface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      child: Row(
        children: [
          Expanded(flex: 5, child: Text('User', style: style)),
          Expanded(flex: 2, child: Text('Role', style: style)),
          Expanded(flex: 3, child: Text('Branch', style: style)),
          SizedBox(width: 132, child: Text('Status', style: style)),
          const SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  final StaffMember user;
  final bool isSelf;
  final bool isLast;
  final VoidCallback onAssign;
  final ValueChanged<String> onMenu;

  const _UserRow({
    required this.user,
    required this.isSelf,
    required this.isLast,
    required this.onAssign,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final u = user;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        border: isLast ? null : const Border(bottom: BorderSide(color: kBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Row(
              children: [
                Avatar(name: u.displayName, radius: 18, muted: !u.isActive),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(u.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sans(14, weight: FontWeight.w600, color: kInk)),
                      Text(u.email,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(12.5, color: kInkMuted)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              u.isPending ? '—' : u.role.label,
              style: sans(13.5, color: u.isPending ? kInkMuted : kInk),
            ),
          ),
          Expanded(
            flex: 3,
            child: u.branchName != null
                ? Text(u.branchName!,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(13.5, color: kInk))
                : u.role == StaffRole.admin
                ? Text('All branches', style: sans(13.5, color: kInkMuted))
                : Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onAssign,
                style: TextButton.styleFrom(
                  foregroundColor: kPrimary,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: const Size(0, 34),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: kBorder),
                  ),
                ),
                icon: const Icon(Icons.add_business_outlined, size: 16),
                label: Text('Assign', style: sans(13, weight: FontWeight.w600, color: kPrimary)),
              ),
            ),
          ),
          SizedBox(width: 132, child: Align(alignment: Alignment.centerLeft, child: _statusPillFor(u))),
          SizedBox(width: 40, child: _userMenu(u, isSelf, onMenu)),
        ],
      ),
    );
  }
}

// ============================================================================
// PHONE / NARROW — CARDS
// ============================================================================

class _UserCard extends StatelessWidget {
  final StaffMember user;
  final bool isSelf;
  final VoidCallback onAssign;
  final ValueChanged<String> onMenu;

  const _UserCard({
    required this.user,
    required this.isSelf,
    required this.onAssign,
    required this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final u = user;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 4, 12),
      decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Avatar(name: u.displayName, muted: !u.isActive),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sans(14.5, weight: FontWeight.w600, color: kInk)),
                    Text(u.email,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(12.5, color: kInkMuted)),
                  ],
                ),
              ),
              _userMenu(u, isSelf, onMenu),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _statusPillFor(u),
                if (!u.isPending) StatusPill.neutral(u.role.label),
                if (u.branchName != null)
                  StatusPill.neutral(u.branchName!, icon: Icons.storefront_outlined)
                else if (u.role == StaffRole.admin)
                  StatusPill.neutral('All branches', icon: Icons.storefront_outlined),
              ],
            ),
          ),
          if (u.branchId == null && u.role != StaffRole.admin) ...[
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onAssign,
                  style: primaryButtonStyle(height: 42),
                  icon: const Icon(Icons.add_business_outlined, size: 18),
                  label: const Text('Assign role'),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}