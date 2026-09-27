class AppUser {
  const AppUser({
    required this.id,
    required this.email,
    required this.fullName,
    required this.username,
    required this.role,
    required this.isActive,
    this.branchId,
  });

  final String id;
  final String email;
  final String fullName;
  final String username;
  final String role; // 'admin' | 'manager' | 'cashier' | 'stock_controller'
  final bool isActive; // false until an admin approves + assigns role/branch
  final String? branchId; // null for admin, or while pending approval

  factory AppUser.fromMap(Map<String, dynamic> map) => AppUser(
    id: map['id'] as String,
    email: map['email'] as String,
    fullName: map['full_name'] as String,
    username: map['username'] as String,
    role: map['role'] as String,
    isActive: map['is_active'] as bool,
    branchId: map['branch_id'] as String?,
  );

  bool get isAdmin => role == 'admin';
}