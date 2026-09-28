import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================================================
// ADMIN MANAGEMENT — REPOSITORY
//   Branches: list, create, edit, activate/deactivate, delete
//   Users:    list, assign to branch (activates), remove from branch
//             (deactivates), delete completely
//
// Requires admin_management.sql to have been run (adds the two RPCs
// admin_delete_branch and admin_delete_user).
// ============================================================================

class ManagementException implements Exception {
  final String message;
  const ManagementException(this.message);
  @override
  String toString() => message;
}

enum StaffRole { admin, manager, cashier, stockController }

extension StaffRoleX on StaffRole {
  String get dbValue {
    switch (this) {
      case StaffRole.admin:
        return 'admin';
      case StaffRole.manager:
        return 'manager';
      case StaffRole.cashier:
        return 'cashier';
      case StaffRole.stockController:
        return 'stock_controller';
    }
  }

  String get label {
    switch (this) {
      case StaffRole.admin:
        return 'Admin';
      case StaffRole.manager:
        return 'Manager';
      case StaffRole.cashier:
        return 'Cashier';
      case StaffRole.stockController:
        return 'Stock controller';
    }
  }
}

StaffRole staffRoleFromDb(String? v) {
  switch (v) {
    case 'admin':
      return StaffRole.admin;
    case 'manager':
      return StaffRole.manager;
    case 'stock_controller':
      return StaffRole.stockController;
    default:
      return StaffRole.cashier;
  }
}

/// Roles an admin may hand out from the assign screen. Admin needs no
/// branch; cashier and stock controller do.
const List<StaffRole> kAssignableRoles = [
  StaffRole.admin,
  StaffRole.cashier,
  StaffRole.stockController,
];

class BranchInfo {
  final String id;
  final String name;
  final String? location;
  final String? phone;
  final bool isActive;
  final int staffCount;

  const BranchInfo({
    required this.id,
    required this.name,
    this.location,
    this.phone,
    required this.isActive,
    required this.staffCount,
  });
}

class StaffMember {
  final String id;
  final String fullName;
  final String username;
  final String email;
  final String? phone;
  final StaffRole role;
  final bool isActive;
  final String? branchId;
  final String? branchName;

  const StaffMember({
    required this.id,
    required this.fullName,
    required this.username,
    required this.email,
    this.phone,
    required this.role,
    required this.isActive,
    this.branchId,
    this.branchName,
  });

  String get displayName {
    if (fullName.trim().isNotEmpty) return fullName.trim();
    if (username.trim().isNotEmpty) return username.trim();
    return email;
  }

  /// New sign-up waiting for an admin to give them a branch.
  bool get isPending => !isActive && branchId == null && role != StaffRole.admin;

  factory StaffMember.fromRow(Map<String, dynamic> r) {
    final branch = r['branches'];
    return StaffMember(
      id: r['id'] as String,
      fullName: (r['full_name'] as String?) ?? '',
      username: (r['username'] as String?) ?? '',
      email: (r['email'] as String?) ?? '',
      phone: r['phone'] as String?,
      role: staffRoleFromDb(r['role'] as String?),
      isActive: (r['is_active'] as bool?) ?? false,
      branchId: r['branch_id'] as String?,
      branchName: branch is Map ? branch['name'] as String? : null,
    );
  }
}

String? _clean(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

class AdminManagementRepository {
  final SupabaseClient _client = Supabase.instance.client;

  String? get currentUserId => _client.auth.currentUser?.id;

  Future<T> _guard<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on PostgrestException catch (e) {
      throw ManagementException(e.message);
    }
  }

  // --------------------------------------------------------------------------
  // BRANCHES
  // --------------------------------------------------------------------------

  Future<List<BranchInfo>> fetchBranches() => _guard(() async {
    final rows = (await _client
        .from('branches')
        .select('id, name, location, phone, is_active')
        .order('name')) as List;

    final staffRows = (await _client
        .from('users')
        .select('branch_id')
        .eq('is_active', true)
        .not('branch_id', 'is', null)) as List;

    final counts = <String, int>{};
    for (final r in staffRows) {
      final id = r['branch_id'] as String;
      counts[id] = (counts[id] ?? 0) + 1;
    }

    return rows
        .map((r) => BranchInfo(
      id: r['id'] as String,
      name: r['name'] as String,
      location: r['location'] as String?,
      phone: r['phone'] as String?,
      isActive: (r['is_active'] as bool?) ?? true,
      staffCount: counts[r['id'] as String] ?? 0,
    ))
        .toList();
  });

  Future<void> createBranch({required String name, String? location, String? phone}) =>
      _guard(() async {
        await _client.from('branches').insert({
          'name': name.trim(),
          'location': _clean(location),
          'phone': _clean(phone),
        });
      });

  Future<void> updateBranch(String id,
      {required String name, String? location, String? phone}) =>
      _guard(() async {
        final res = (await _client
            .from('branches')
            .update({
          'name': name.trim(),
          'location': _clean(location),
          'phone': _clean(phone),
        })
            .eq('id', id)
            .select('id')) as List;
        if (res.isEmpty) {
          throw const ManagementException('Branch was not updated. Check admin permissions.');
        }
      });

  Future<void> setBranchActive(String id, bool active) => _guard(() async {
    final res = (await _client
        .from('branches')
        .update({'is_active': active})
        .eq('id', id)
        .select('id')) as List;
    if (res.isEmpty) {
      throw const ManagementException('Branch was not updated. Check admin permissions.');
    }
  });

  /// Unassigns + deactivates the branch's staff, then deletes the branch.
  /// Fails (with a readable message) if the branch has stock/sales history.
  Future<void> deleteBranch(String id) => _guard(() async {
    await _client.rpc('admin_delete_branch', params: {'p_branch_id': id});
  });

  // --------------------------------------------------------------------------
  // USERS
  // --------------------------------------------------------------------------

  Future<List<StaffMember>> fetchUsers() => _guard(() async {
    final rows = (await _client
        .from('users')
        .select('id, full_name, username, email, phone, role, is_active, branch_id, created_at, branches(name)')
        .order('created_at', ascending: false)) as List;
    return rows
        .map((r) => StaffMember.fromRow(Map<String, dynamic>.from(r as Map)))
        .toList();
  });

  /// Sets the user's role and marks the account active.
  /// Admins get no branch (branchId is ignored and cleared); every other
  /// role requires one.
  Future<void> assignUser({
    required String userId,
    String? branchId,
    required StaffRole role,
  }) =>
      _guard(() async {
        if (role != StaffRole.admin && branchId == null) {
          throw const ManagementException('Choose a branch for this role.');
        }
        final res = (await _client
            .from('users')
            .update({
          'branch_id': role == StaffRole.admin ? null : branchId,
          'role': role.dbValue,
          'is_active': true,
        })
            .eq('id', userId)
            .select('id')) as List;
        if (res.isEmpty) {
          throw const ManagementException('User was not updated. Check admin permissions.');
        }
      });

  /// Clears the branch and deactivates the account (the schema requires a
  /// branch for any active non-admin user). Can be re-assigned later.
  Future<void> removeFromBranch(String userId) => _guard(() async {
    final res = (await _client
        .from('users')
        .update({'branch_id': null, 'is_active': false})
        .eq('id', userId)
        .select('id')) as List;
    if (res.isEmpty) {
      throw const ManagementException('User was not updated. Check admin permissions.');
    }
  });

  /// Deletes the sign-in account and profile. Fails (with a readable
  /// message) if the user has sales/stock/payment history.
  Future<void> deleteUser(String userId) => _guard(() async {
    await _client.rpc('admin_delete_user', params: {'p_user_id': userId});
  });
}
