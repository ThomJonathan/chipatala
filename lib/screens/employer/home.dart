import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../appUser.dart';
import '../../auth-repository.dart';
import '../../widgets/employeeShell.dart';
import 'employeeHome.dart';

/// What '/home' should point to in main.dart, instead of EmployeeHomePage:
///
///   '/home': (context) => const EmployeeHomeRoute(),
///
/// Loads the signed-in AppUser (AuthRepository already has this) plus their
/// branch name (one extra lookup, since AppUser only carries branchId), then
/// renders EmployeeShell with the real name / role / branch instead of the
/// placeholder strings from before. Sign-out needs no wiring here —
/// AuthRepository.signOut() and the shell's built-in default both just call
/// _client.auth.signOut(), so they already agree.
class EmployeeHomeRoute extends StatefulWidget {
  const EmployeeHomeRoute({super.key});

  @override
  State<EmployeeHomeRoute> createState() => _EmployeeHomeRouteState();
}

class _EmployeeHomeRouteState extends State<EmployeeHomeRoute> {
  late final Future<_HomeData> _future = _load();

  Future<_HomeData> _load() async {
    final user = await AuthRepository().currentUser;
    if (user == null) {
      throw Exception('No signed-in user.');
    }

    var branchName = '';
    if (user.branchId != null) {
      final row = await Supabase.instance.client
          .from('branches')
          .select('name')
          .eq('id', user.branchId!)
          .single();
      branchName = row['name'] as String? ?? '';
    }

    return _HomeData(user: user, branchName: branchName);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_HomeData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }

        if (snapshot.hasError || !snapshot.hasData) {
          // Session must have gone stale between routes — back to login
          // rather than showing a broken shell.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
          });
          return const Scaffold(body: SizedBox.shrink());
        }

        final data = snapshot.data!;
        return EmployeeShell(
          userName: data.user.fullName,
          userRole: _roleLabel(data.user.role),
          branchName: data.branchName,
          pages: [
            EmployeeHomeScreen(user: data.user, branchName: data.branchName),
            // TODO: swap each of these for the real screen as you build it.
            // Order matches the nav: Home, Sale, Stock, Reports, Settings.
            const Center(child: Text('New Sale')),
            const Center(child: Text('Stock')),
            const Center(child: Text('Reports')),
            const Center(child: Text('Settings')),
          ],
        );
      },
    );
  }
}

String _roleLabel(String role) {
  switch (role) {
    case 'stock_controller':
      return 'Stock controller';
    case 'cashier':
      return 'Cashier';
    case 'manager':
      return 'Manager';
    case 'admin':
      return 'Admin';
    default:
      return role;
  }
}

class _HomeData {
  final AppUser user;
  final String branchName;
  const _HomeData({required this.user, required this.branchName});
}