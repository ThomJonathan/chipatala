import 'package:flutter/material.dart';

import 'adminhomeRepo.dart';
import 'adminui.dart';
import 'assignUser.dart';

// ============================================================================
// BRANCHES SCREEN
//   - embedded: true  (desktop shell page)  -> page title + "Add branch" button
//   - embedded: false (pushed from Settings on phones) -> AppBar + floating
//     "Add branch" button
//   Cards flow into 1 column on phones and 2-3 columns on desktop.
//   Tap a card to manage its staff; the ⋮ menu edits, deactivates or deletes.
// ============================================================================

class BranchesScreen extends StatefulWidget {
  final bool embedded;
  const BranchesScreen({super.key, this.embedded = true});

  @override
  State<BranchesScreen> createState() => _BranchesScreenState();
}

class _BranchesScreenState extends State<BranchesScreen> {
  final _repo = AdminManagementRepository();
  List<BranchInfo> _branches = [];
  bool _loading = true;
  String? _error;

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
      final b = await _repo.fetchBranches();
      if (!mounted) return;
      setState(() {
        _branches = b;
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

  Future<void> _addOrEdit([BranchInfo? branch]) async {
    final message = await showAdaptiveSheet<String>(
      context,
      builder: (_) => _BranchForm(repo: _repo, branch: branch),
    );
    if (message == null) return;
    await _load(silent: true);
    if (mounted) showToast(context, message);
  }

  Future<void> _toggleActive(BranchInfo b) async {
    if (b.isActive) {
      final ok = await showConfirm(
        context,
        title: 'Deactivate ${b.name}?',
        message:
        'The branch stops appearing in dashboards and filters. Its stock and sales history stay safe, and you can reactivate it any time.',
        confirmLabel: 'Deactivate',
      );
      if (!ok) return;
    }
    try {
      await _repo.setBranchActive(b.id, !b.isActive);
      await _load(silent: true);
      if (mounted) showToast(context, b.isActive ? '${b.name} deactivated.' : '${b.name} is active again.');
    } on ManagementException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  Future<void> _delete(BranchInfo b) async {
    final ok = await showConfirm(
      context,
      title: 'Delete ${b.name}?',
      message:
      'This permanently removes the branch. Its staff are unassigned and deactivated until you assign them elsewhere. '
          'Branches with stock or sales records can\'t be deleted — deactivate those instead.',
      confirmLabel: 'Delete branch',
      destructive: true,
    );
    if (!ok) return;
    try {
      await _repo.deleteBranch(b.id);
      await _load(silent: true);
      if (mounted) showToast(context, '${b.name} deleted.');
    } on ManagementException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  Future<void> _openStaff(BranchInfo b) async {
    await showAdaptiveSheet<void>(
      context,
      builder: (_) => _BranchStaffSheet(repo: _repo, branch: b),
    );
    if (mounted) _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final addButton = FilledButton.icon(
      onPressed: () => _addOrEdit(),
      style: primaryButtonStyle(height: 44),
      icon: const Icon(Icons.add, size: 19),
      label: const Text('Add branch'),
    );

    return Scaffold(
      backgroundColor: kBg,
      appBar: widget.embedded
          ? null
          : AppBar(
        backgroundColor: kBg,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: kInk,
        title: Text('Branches', style: sans(17, weight: FontWeight.w700, color: kInk)),
      ),
      floatingActionButton: widget.embedded
          ? null
          : FloatingActionButton.extended(
        onPressed: () => _addOrEdit(),
        backgroundColor: kPrimary,
        foregroundColor: Colors.white,
        elevation: 2,
        icon: const Icon(Icons.add),
        label: Text('Add branch', style: sans(14, weight: FontWeight.w600, color: Colors.white)),
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
                padding: EdgeInsets.fromLTRB(wide ? 32 : 18, wide ? 28 : 12, wide ? 32 : 18, 96),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1080),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (widget.embedded) ...[
                          PageTitle(
                            title: 'Branches',
                            subtitle: _loading
                                ? 'Loading…'
                                : '${_branches.length} ${_branches.length == 1 ? 'shop' : 'shops'} · '
                                '${_branches.where((b) => b.isActive).length} active',
                            trailing: addButton,
                          ),
                          const SizedBox(height: 22),
                        ] else if (!_loading && _error == null) ...[
                          Text(
                            '${_branches.length} ${_branches.length == 1 ? 'shop' : 'shops'} · '
                                '${_branches.where((b) => b.isActive).length} active',
                            style: sans(13.5, color: kInkMuted),
                          ),
                          const SizedBox(height: 14),
                        ],
                        _body(addButton),
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

  Widget _body(Widget addButton) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: Center(child: CircularProgressIndicator(color: kPrimary)),
      );
    }
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    if (_branches.isEmpty) {
      return EmptyState(
        icon: Icons.storefront_outlined,
        title: 'No branches yet',
        message: 'Add your first shop to start assigning staff and tracking stock.',
        action: addButton,
      );
    }
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _branches.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 380,
        mainAxisExtent: 152,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemBuilder: (_, i) {
        final b = _branches[i];
        return _BranchCard(
          branch: b,
          onTap: () => _openStaff(b),
          onEdit: () => _addOrEdit(b),
          onToggle: () => _toggleActive(b),
          onDelete: () => _delete(b),
        );
      },
    );
  }
}

// ============================================================================
// BRANCH CARD
// ============================================================================

class _BranchCard extends StatelessWidget {
  final BranchInfo branch;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _BranchCard({
    required this.branch,
    required this.onTap,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final b = branch;
    final dimmed = !b.isActive;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 6, 14),
          decoration: BoxDecoration(
            border: Border.all(color: kBorder),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: dimmed ? kSurface : kPrimaryTint,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.storefront_outlined, size: 21, color: dimmed ? kInkMuted : kPrimary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          b.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sans(15, weight: FontWeight.w600, color: dimmed ? kInkMuted : kInk),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          (b.location?.isNotEmpty ?? false) ? b.location! : 'No location set',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sans(12.5, color: kInkMuted),
                        ),
                        if (b.phone?.isNotEmpty ?? false)
                          Text(b.phone!,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(12.5, color: kInkMuted)),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 20, color: kInkMuted),
                    tooltip: 'Branch options',
                    color: Colors.white,
                    surfaceTintColor: Colors.transparent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    onSelected: (v) {
                      switch (v) {
                        case 'staff':
                          onTap();
                          break;
                        case 'edit':
                          onEdit();
                          break;
                        case 'toggle':
                          onToggle();
                          break;
                        case 'delete':
                          onDelete();
                          break;
                      }
                    },
                    itemBuilder: (_) => [
                      _menuItem('staff', Icons.groups_outlined, 'Manage staff'),
                      _menuItem('edit', Icons.edit_outlined, 'Edit details'),
                      _menuItem(
                        'toggle',
                        b.isActive ? Icons.pause_circle_outline : Icons.play_circle_outline,
                        b.isActive ? 'Deactivate' : 'Reactivate',
                      ),
                      const PopupMenuDivider(),
                      _menuItem('delete', Icons.delete_outline, 'Delete branch', danger: true),
                    ],
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Row(
                  children: [
                    StatusPill.neutral(
                      '${b.staffCount} ${b.staffCount == 1 ? 'staff member' : 'staff'}',
                      icon: Icons.people_outline,
                    ),
                    const Spacer(),
                    b.isActive ? StatusPill.active() : StatusPill.inactive(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

PopupMenuItem<String> _menuItem(String value, IconData icon, String label, {bool danger = false}) {
  final color = danger ? kDanger : kInk;
  return PopupMenuItem<String>(
    value: value,
    height: 42,
    child: Row(
      children: [
        Icon(icon, size: 18, color: danger ? kDanger : kInkMuted),
        const SizedBox(width: 10),
        Text(label, style: sans(13.5, weight: FontWeight.w500, color: color)),
      ],
    ),
  );
}

// ============================================================================
// ADD / EDIT BRANCH FORM
// ============================================================================

class _BranchForm extends StatefulWidget {
  final AdminManagementRepository repo;
  final BranchInfo? branch;
  const _BranchForm({required this.repo, this.branch});

  @override
  State<_BranchForm> createState() => _BranchFormState();
}

class _BranchFormState extends State<_BranchForm> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.branch?.name ?? '');
  late final _location = TextEditingController(text: widget.branch?.location ?? '');
  late final _phone = TextEditingController(text: widget.branch?.phone ?? '');
  bool _saving = false;
  String? _error;

  bool get _isEdit => widget.branch != null;

  @override
  void dispose() {
    _name.dispose();
    _location.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isEdit) {
        await widget.repo.updateBranch(widget.branch!.id,
            name: _name.text, location: _location.text, phone: _phone.text);
      } else {
        await widget.repo.createBranch(name: _name.text, location: _location.text, phone: _phone.text);
      }
      if (mounted) {
        Navigator.of(context).pop(_isEdit ? 'Branch updated.' : '${_name.text.trim()} added.');
      }
    } on ManagementException catch (e) {
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
    return SheetFrame(
      title: _isEdit ? 'Edit branch' : 'Add a branch',
      subtitle: _isEdit ? null : 'Add a shop you own so you can assign staff and track its stock.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              style: sans(14, color: kInk),
              cursorColor: kPrimary,
              decoration: fieldDecoration('Branch name', hint: 'e.g. Mzuzu Branch'),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a branch name' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _location,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              style: sans(14, color: kInk),
              cursorColor: kPrimary,
              decoration: fieldDecoration('Location (optional)', hint: 'e.g. Area 4, Lilongwe'),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              style: sans(14, color: kInk),
              cursorColor: kPrimary,
              decoration: fieldDecoration('Phone (optional)'),
              onFieldSubmitted: (_) => _save(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: sans(13, color: kDanger)),
            ],
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    style: outlineButtonStyle(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    style: primaryButtonStyle(),
                    child: _saving
                        ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                        : Text(_isEdit ? 'Save changes' : 'Add branch'),
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
// BRANCH STAFF SHEET — who works here; add or remove people
// ============================================================================

class _BranchStaffSheet extends StatefulWidget {
  final AdminManagementRepository repo;
  final BranchInfo branch;
  const _BranchStaffSheet({required this.repo, required this.branch});

  @override
  State<_BranchStaffSheet> createState() => _BranchStaffSheetState();
}

class _BranchStaffSheetState extends State<_BranchStaffSheet> {
  List<StaffMember> _all = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final users = await widget.repo.fetchUsers();
      if (!mounted) return;
      setState(() {
        _all = users;
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

  List<StaffMember> get _staff =>
      _all.where((u) => u.branchId == widget.branch.id && u.role != StaffRole.admin).toList();

  Future<void> _remove(StaffMember u) async {
    final ok = await showConfirm(
      context,
      title: 'Remove ${u.displayName}?',
      message:
      'They\'ll be taken off ${widget.branch.name} and their account deactivated until you assign them to a branch again.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!ok) return;
    try {
      await widget.repo.removeFromBranch(u.id);
      await _load();
      if (mounted) showToast(context, '${u.displayName} removed from ${widget.branch.name}.');
    } on ManagementException catch (e) {
      if (mounted) showToast(context, e.message, error: true);
    }
  }

  Future<void> _add() async {
    final candidates = _all
        .where((u) => u.role != StaffRole.admin && u.branchId != widget.branch.id)
        .toList()
      ..sort((a, b) {
        if (a.isPending != b.isPending) return a.isPending ? -1 : 1; // pending first
        return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
      });

    if (candidates.isEmpty) {
      showToast(context, 'No other users to add. New sign-ups will show up here.');
      return;
    }

    final message = await showAdaptiveSheet<String>(
      context,
      builder: (_) => AssignUserSheet(repo: widget.repo, branch: widget.branch, candidates: candidates),
    );
    if (message != null) {
      await _load();
      if (mounted) showToast(context, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final staff = _staff;

    return SheetFrame(
      title: widget.branch.name,
      subtitle: _loading ? 'Loading staff…' : '${staff.length} ${staff.length == 1 ? 'person' : 'people'} assigned',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator(color: kPrimary)),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(_error!, style: sans(13, color: kDanger)),
            )
          else if (staff.isEmpty)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(color: kSurface, borderRadius: BorderRadius.circular(10)),
                child: Text(
                  'Nobody is assigned to this branch yet.',
                  textAlign: TextAlign.center,
                  style: sans(13.5, color: kInkMuted),
                ),
              )
            else
              Container(
                decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
                child: Column(
                  children: List.generate(staff.length, (i) {
                    final u = staff[i];
                    return Container(
                      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                      decoration: BoxDecoration(
                        border: i == staff.length - 1 ? null : const Border(bottom: BorderSide(color: kBorder)),
                      ),
                      child: Row(
                        children: [
                          Avatar(name: u.displayName, radius: 18),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(u.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: sans(14, weight: FontWeight.w600, color: kInk)),
                                Text(u.role.label,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: sans(12.5, color: kInkMuted)),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove from branch',
                            onPressed: () => _remove(u),
                            icon: const Icon(Icons.person_remove_outlined, size: 20, color: kDanger),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _loading ? null : _add,
            style: primaryButtonStyle(),
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 19),
            label: const Text('Add staff'),
          ),
        ],
      ),
    );
  }
}