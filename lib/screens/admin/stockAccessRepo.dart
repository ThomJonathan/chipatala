import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================================================
// STOCK ACCESS — admin side of cashier stock permissions.
//   Reads the v_stock_access_requests view (effective_status reports expired
//   on its own — the table row stays 'approved', so never read raw status).
//   All writes go through the DB functions: decide_stock_access,
//   revoke_stock_access. Only admins can approve/deny/remove; the view's RLS
//   already limits cashiers to their own rows.
// ============================================================================

class StockAccessException implements Exception {
  final String message;
  const StockAccessException(this.message);
  @override
  String toString() => message;
}

/// Told to the Inventory screen when the admin taps "View activity".
class StockActivityFilter {
  final String userId;
  final String userName;
  final DateTime from;
  final DateTime to;
  const StockActivityFilter({
    required this.userId,
    required this.userName,
    required this.from,
    required this.to,
  });
}

// ---- Shared state ------------------------------------------------------------
// Pending count drives the Users nav badge + Home card. Initial tab lets the
// Home card deep-link into Pending. Activity filter carries the View-activity
// jump into Inventory's Movements tab.

final stockAccessPendingCount = ValueNotifier<int>(0);
// -1 = no deep-link pending. Home card sets 0/1/2 to jump straight in.
final stockAccessInitialTab = ValueNotifier<int>(-1);
final stockActivityFilter = ValueNotifier<StockActivityFilter?>(null);

// ---- Model ---------------------------------------------------------------------

class StockAccessRequest {
  final String id;
  final String userId;
  final String userName;
  final String branchId;
  final String branchName;
  final String reason;
  final DateTime requestedAt;
  final DateTime? decidedAt;
  final DateTime? expiresAt;
  final DateTime? revokedAt;
  final String? decidedByName;
  final String? revokedByName;
  final String effectiveStatus; // pending | approved | denied | revoked | expired
  final bool endedByCashier;

  const StockAccessRequest({
    required this.id,
    required this.userId,
    required this.userName,
    required this.branchId,
    required this.branchName,
    required this.reason,
    required this.requestedAt,
    required this.decidedAt,
    required this.expiresAt,
    required this.revokedAt,
    required this.decidedByName,
    required this.revokedByName,
    required this.effectiveStatus,
    required this.endedByCashier,
  });

  factory StockAccessRequest.fromMap(Map r) {
    DateTime? dt(Object? v) {
      if (v == null) return null;
      try {
        return DateTime.parse(v as String);
      } catch (_) {
        return null;
      }
    }

    final revokedBy = r['revoked_by_name'] as String?;
    return StockAccessRequest(
      id: r['id'] as String,
      userId: r['user_id'] as String,
      userName: (r['full_name'] as String?) ?? 'Unknown cashier',
      branchId: r['branch_id'] as String,
      branchName: (r['branch_name'] as String?) ?? 'Unknown branch',
      reason: (r['reason'] as String?)?.trim() ?? '',
      requestedAt: dt(r['requested_at']) ?? DateTime.now(),
      decidedAt: dt(r['decided_at']),
      expiresAt: dt(r['expires_at']),
      revokedAt: dt(r['revoked_at']),
      decidedByName: (r['decided_by_name'] as String?)?.trim().isNotEmpty == true
          ? (r['decided_by_name'] as String).trim()
          : null,
      revokedByName: revokedBy?.trim().isNotEmpty == true ? revokedBy!.trim() : null,
      effectiveStatus: (r['effective_status'] as String?) ?? 'pending',
      // Revoked rows carry no explicit flag; compare IDs (not names) to tell
      // the cashier ending their own access ("I'm done") from an admin removal.
      endedByCashier: (r['revoked_by_id'] as String?) != null &&
          r['revoked_by_id'] == r['user_id'],
    );
  }

  bool get isPending => effectiveStatus == 'pending';
  bool get isActive => effectiveStatus == 'approved';

  /// Unlimited access running for more than a day — nudge the admin.
  bool get isStaleUnlimited {
    if (!isActive || expiresAt != null) return false;
    final since = decidedAt ?? requestedAt;
    return DateTime.now().difference(since) > const Duration(hours: 24);
  }

  Duration? get remaining {
    if (!isActive || expiresAt == null) return null;
    return expiresAt!.difference(DateTime.now());
  }

  /// "Ends in 2h 15m" / "Ends in 40m" / "Ends in 3d 2h".
  String countdownLabel() {
    final left = remaining;
    if (left == null) return 'Until removed';
    if (left.isNegative) return 'Expired';
    if (left.inDays >= 1) return 'Ends in ${left.inDays}d ${left.inHours % 24}h';
    if (left.inHours >= 1) return 'Ends in ${left.inHours}h ${left.inMinutes % 60}m';
    return 'Ends in ${left.inMinutes}m';
  }

  /// History outcome label.
  String outcomeLabel() {
    switch (effectiveStatus) {
      case 'denied':
        return 'Denied';
      case 'revoked':
        return endedByCashier ? 'Ended by cashier' : 'Removed';
      case 'expired':
        return 'Expired';
      case 'approved':
        return 'Active';
      default:
        return 'Pending';
    }
  }

  /// Period the cashier could act in — for the View-activity link.
  ({DateTime from, DateTime to}) activityWindow() {
    final from = decidedAt ?? requestedAt;
    final to = revokedAt ??
        (expiresAt != null && expiresAt!.isBefore(DateTime.now()) ? expiresAt! : DateTime.now());
    return (from: from, to: to);
  }
}

// ---- Repository ------------------------------------------------------------------

class StockAccessRepository {
  final SupabaseClient _client = Supabase.instance.client;

  Future<List<StockAccessRequest>> fetchAll() async {
    final rows = await _client.from('v_stock_access_requests').select().limit(400) as List;
    return rows.map((r) => StockAccessRequest.fromMap(r as Map)).toList();
  }

  Future<void> decide({required String requestId, required bool approve, int? hours}) async {
    try {
      await _client.rpc('decide_stock_access', params: {
        'p_request_id': requestId,
        'p_approve': approve,
        'p_hours': ?hours,
      });
    } on PostgrestException catch (e) {
      throw StockAccessException(e.message);
    }
  }

  Future<void> revoke({required String requestId}) async {
    try {
      await _client.rpc('revoke_stock_access', params: {'p_request_id': requestId});
    } on PostgrestException catch (e) {
      throw StockAccessException(e.message);
    }
  }
}
