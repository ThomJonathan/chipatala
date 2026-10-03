import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================================================
// BRANCH EXPENSES — REPOSITORY (branch-scoped)
//   Cashiers / stock controllers / managers record their own branch's
//   expenses. RLS backs this up (own-branch policies on expenses); the app
//   always writes the staff member's own branch_id so branches can never
//   see or record each other's spending.
// ============================================================================

class ExpenseException implements Exception {
  final String message;
  const ExpenseException(this.message);
  @override
  String toString() => message;
}

class ExpenseEntry {
  final String id;
  final String category;
  final double amount;
  final String? description;
  final String date; // YYYY-MM-DD
  final String recordedBy;
  const ExpenseEntry({
    required this.id,
    required this.category,
    required this.amount,
    required this.description,
    required this.date,
    required this.recordedBy,
  });
}

/// Suggested categories (matches the examples in schema.sql). 'Other' covers
/// everything else — the reason field then explains what it was.
const expenseCategories = [
  'Transport',
  'Electricity',
  'Rent',
  'Salaries',
  'Airtime & Internet',
  'Repairs',
  'Other',
];

class ExpenseRepository {
  final SupabaseClient _client = Supabase.instance.client;

  /// Most recent expenses for [branchId], newest first.
  Future<List<ExpenseEntry>> fetchExpenses({required String branchId}) async {
    try {
      final rows = await _client
          .from('expenses')
          .select(
            'id, category, amount, description, expense_date, recorded_by, users(full_name)',
          )
          .eq('branch_id', branchId)
          .order('expense_date', ascending: false)
          .order('created_at', ascending: false)
          .limit(200) as List;
      return rows.map((r) {
        final user = r['users'];
        return ExpenseEntry(
          id: (r['id'] as String?) ?? '',
          category: (r['category'] as String?) ?? 'Other',
          amount: ((r['amount'] as num?) ?? 0).toDouble(),
          description: r['description'] as String?,
          date: (r['expense_date'] as String?) ?? '',
          recordedBy: (user is Map ? user['full_name'] as String? : null) ?? '',
        );
      }).toList();
    } on PostgrestException catch (e) {
      throw ExpenseException(e.message);
    }
  }

  /// Records one branch expense. [date] is YYYY-MM-DD (defaults to today).
  Future<void> recordExpense({
    required String branchId,
    required double amount,
    required String category,
    required String description,
    required String date,
  }) async {
    if (amount <= 0) throw const ExpenseException('Enter an amount above zero.');
    if (category.trim().isEmpty) {
      throw const ExpenseException('Pick a category.');
    }
    if (description.trim().isEmpty) {
      throw const ExpenseException('Add a short reason for this expense.');
    }
    try {
      await _client.from('expenses').insert({
        'branch_id': branchId,
        'category': category.trim(),
        'amount': amount,
        'description': description.trim(),
        'expense_date': date,
        'recorded_by': _client.auth.currentUser?.id,
      });
    } on PostgrestException catch (e) {
      throw ExpenseException(e.message);
    }
  }
}
