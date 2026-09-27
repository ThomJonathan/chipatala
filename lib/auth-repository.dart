import 'package:supabase_flutter/supabase_flutter.dart';

import 'appUser.dart';

/// Thrown when credentials are correct but an admin hasn't approved and
/// assigned a role/branch to this account yet.
class PendingApprovalException implements Exception {
  const PendingApprovalException([
    this.message =
    "Your account hasn't been approved yet. An admin needs to assign "
        "your role and branch before you can sign in.",
  ]);

  final String message;

  @override
  String toString() => message;
}

class AuthRepository {
  final _client = Supabase.instance.client;

  Future<AppUser?> get currentUser async {
    final session = _client.auth.currentSession;
    if (session == null) return null;

    final row = await _client.from('users').select().eq('id', session.user.id).single();

    return AppUser.fromMap(row);
  }

  /// Signs in, then checks approval status. Supabase Auth itself has no
  /// concept of "pending admin approval" — that's app-level, so it has to
  /// be checked here, right after authentication succeeds and before the
  /// caller is allowed to treat the user as logged in. An unapproved user
  /// is signed back out immediately rather than left half-authenticated.
  Future<AppUser> signIn({required String email, required String password}) async {
    await _client.auth.signInWithPassword(email: email, password: password);

    final user = await currentUser;
    if (user == null) {
      await _client.auth.signOut();
      throw Exception('Could not load your account. Try again.');
    }

    if (!user.isActive) {
      await _client.auth.signOut();
      throw const PendingApprovalException();
    }

    return user;
  }

  /// Only touches Supabase Auth. The matching `users` row is created
  /// automatically by the `on_auth_user_created` trigger — full_name is
  /// passed through as metadata so the trigger can read it off
  /// `raw_user_meta_data`. New rows start with is_active = false and no
  /// branch; an admin approves them later via [approveUser].
  Future<void> signUp({
    required String fullName,
    required String username,
    required String email,
    required String password,
  }) {
    return _client.auth.signUp(
      email: email,
      password: password,
      data: {'full_name': fullName, 'username': username},
    );
  }

  Future<void> signOut() => _client.auth.signOut();

  // ---------------------------------------------------------------------
  // Password reset — code-based, no deep link.
  //
  // 1. sendPasswordResetCode  -> emails the user a 6-digit code (requires
  //    the "Reset Password" template in the Supabase dashboard to include
  //    {{ .Token }}).
  // 2. verifyPasswordResetCode -> exchanges that code for a real (if
  //    short-lived) recovery session, good only for calling updatePassword.
  // 3. updatePassword -> sets the new password on that recovery session.
  // ---------------------------------------------------------------------

  Future<void> sendPasswordResetCode(String email) =>
      _client.auth.resetPasswordForEmail(email);

  Future<void> verifyPasswordResetCode({
    required String email,
    required String code,
  }) =>
      _client.auth.verifyOTP(email: email, token: code, type: OtpType.recovery);

  Future<void> updatePassword(String newPassword) =>
      _client.auth.updateUser(UserAttributes(password: newPassword));

  // ---------------------------------------------------------------------
  // Admin-only: list pending signups, then approve one by assigning a
  // real role and branch. Relies on the existing "Admins can view all
  // profiles" / "Admins can update any profile" RLS policies — no new
  // policy is needed for this to work.
  // ---------------------------------------------------------------------

  Future<List<AppUser>> pendingUsers() async {
    final rows = await _client.from('users').select().eq('is_active', false);
    return (rows as List).map((r) => AppUser.fromMap(r as Map<String, dynamic>)).toList();
  }

  Future<void> approveUser({
    required String userId,
    required String role,
    required String branchId,
  }) {
    return _client.from('users').update({
      'role': role,
      'branch_id': branchId,
      'is_active': true,
    }).eq('id', userId);
  }
}