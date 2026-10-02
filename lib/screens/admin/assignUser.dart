import 'package:flutter/material.dart';

import 'adminhomeRepo.dart';
import 'adminui.dart';

// ============================================================================
// ASSIGN USER SHEET
//   Two entry points, one widget:
//     - from the Users screen:    [user] is fixed, admin picks branch + role
//     - from a branch's staff list: [branch] is fixed, admin picks user + role
//   Assigning always marks the account active.
//   Pops with a success message (String) so the caller can toast it.
// ============================================================================

class AssignUserSheet extends StatefulWidget {
  final AdminManagementRepository repo;
  final StaffMember? user;
  final BranchInfo? branch;
  final List<BranchInfo> branches; // active branches (used when [branch] is null)
  final List<StaffMember> candidates; // assignable users (used when [user] is null)

  const AssignUserSheet({
    super.key,
    required this.repo,
    this.user,
    this.branch,
    this.branches = const [],
    this.candidates = const [],
  }) : assert(user != null || branch != null, 'Provide a fixed user or a fixed branch.');

  @override
  State<AssignUserSheet> createState() => _AssignUserSheetState();
}

class _AssignUserSheetState extends State<AssignUserSheet> {
  final _formKey = GlobalKey<FormState>();
  String? _userId;
  String? _branchId;
  late StaffRole _role;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    _userId = u?.id;
    _branchId = widget.branch?.id ??
        (u?.branchId != null && widget.branches.any((b) => b.id == u!.branchId) ? u!.branchId : null);
    _role = (u != null &&
        (u.role == StaffRole.admin || (u.branchId != null && kAssignableRoles.contains(u.role))))
        ? u.role
        : StaffRole.cashier;
  }

  String get _title {
    if (widget.branch != null) return 'Add staff to ${widget.branch!.name}';
    if (widget.user!.role == StaffRole.admin) return 'Change role';
    return widget.user!.branchId != null ? 'Change branch or role' : 'Assign role';
  }

  bool get _isAdminRole => _role == StaffRole.admin;

  /// A branch can only hold cashiers and stock controllers.
  List<StaffRole> get _roles => widget.branch != null
      ? kAssignableRoles.where((r) => r != StaffRole.admin).toList()
      : kAssignableRoles;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repo.assignUser(
        userId: _userId!,
        branchId: _isAdminRole ? null : _branchId,
        role: _role,
      );

      final userName = widget.user?.displayName ??
          widget.candidates.firstWhere((c) => c.id == _userId).displayName;
      String message;
      if (_isAdminRole) {
        message = '$userName is now an admin with access to every branch.';
      } else {
        final branchName = widget.branch?.name ??
            widget.branches.firstWhere((b) => b.id == _branchId).name;
        message = '$userName is now a ${_role.label.toLowerCase()} at $branchName.';
      }
      if (mounted) Navigator.of(context).pop(message);
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
    final fixedUser = widget.user;
    final fixedBranch = widget.branch;

    return SheetFrame(
      title: _title,
      subtitle: fixedUser != null ? null : 'Pick who joins this branch and what they can do.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (fixedUser != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: kSurface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Avatar(name: fixedUser.displayName),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(fixedUser.displayName,
                              style: sans(14, weight: FontWeight.w600, color: kInk),
                              overflow: TextOverflow.ellipsis),
                          Text(fixedUser.email,
                              style: sans(12.5, color: kInkMuted), overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ] else ...[
              DropdownButtonFormField<String>(
                initialValue: _userId,
                isExpanded: true,
                decoration: fieldDecoration('User'),
                style: sans(14, color: kInk),
                dropdownColor: Colors.white,
                items: widget.candidates
                    .map((u) => DropdownMenuItem(
                  value: u.id,
                  child: Text(
                    u.branchName != null
                        ? '${u.displayName} · now at ${u.branchName}'
                        : '${u.displayName} · ${u.email}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ))
                    .toList(),
                onChanged: (v) => setState(() => _userId = v),
                validator: (v) => v == null ? 'Choose a user' : null,
              ),
              const SizedBox(height: 16),
            ],
            if (fixedBranch == null && !_isAdminRole) ...[
              DropdownButtonFormField<String>(
                initialValue: _branchId,
                isExpanded: true,
                decoration: fieldDecoration('Branch'),
                style: sans(14, color: kInk),
                dropdownColor: Colors.white,
                items: widget.branches
                    .map((b) => DropdownMenuItem(value: b.id, child: Text(b.name)))
                    .toList(),
                onChanged: (v) => setState(() => _branchId = v),
                validator: (v) => v == null
                    ? (widget.branches.isEmpty ? 'Add a branch first' : 'Choose a branch')
                    : null,
              ),
              const SizedBox(height: 16),
            ],
            Text('Role', style: sans(13, weight: FontWeight.w600, color: kInk)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _roles.map((r) {
                final selected = r == _role;
                return ChoiceChip(
                  label: Text(r.label),
                  selected: selected,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _role = r),
                  selectedColor: kPrimary,
                  backgroundColor: Colors.white,
                  side: BorderSide(color: selected ? kPrimary : kBorder),
                  labelStyle: sans(13, weight: FontWeight.w600, color: selected ? Colors.white : kInkMuted),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: kPrimaryTint, borderRadius: BorderRadius.circular(10)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_isAdminRole ? Icons.shield_outlined : Icons.check_circle_outline,
                      size: 18, color: kPrimary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _isAdminRole
                          ? 'Admins don\'t belong to a branch. They get full access to every branch, users and settings.'
                          : 'Assigning activates the account, so they can sign in straight away.',
                      style: sans(12.5, color: kPrimary, height: 1.4),
                    ),
                  ),
                ],
              ),
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
                    onPressed: _saving ? null : _submit,
                    style: primaryButtonStyle(),
                    child: _saving
                        ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                        : Text(_isAdminRole
                        ? 'Make admin'
                        : (fixedUser?.branchId != null || fixedUser?.role == StaffRole.admin)
                        ? 'Save changes'
                        : 'Assign and activate'),
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