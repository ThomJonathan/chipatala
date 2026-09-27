import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================================================
// ADMIN SHELL — one self-contained file: the admin navigation UI.
//   - phone widths  -> floating bottom nav bar
//   - desktop widths -> fixed side nav rail
// Destinations: Home, Branches, Users, Reports, Settings — since an admin
// oversees branches/staff/company numbers rather than ringing up sales.
//
// HOW TO WIRE THIS IN:
//   1. Drop this file at lib/widgets/admin_shell.dart
//   2. In main.dart:
//        import './widgets/admin_shell.dart';
//        ...
//        '/admin-home': (context) => AdminShell(
//              pages: const [
//                AdminHomeScreen(),   // your real screens, in this order
//                BranchesScreen(),
//                UsersScreen(),       // staff list + pending approvals
//                ReportsScreen(),     // company-wide, across branches
//                SettingsScreen(),
//              ],
//              userName: currentUser.fullName,
//            ),
//   3. Sign-out needs no wiring — tapping it (icon on mobile, user card on
//      desktop) confirms, then signs out of Supabase directly and returns
//      to '/login'. Pass onSignOut only if you want it routed through
//      AuthRepository instead.
// ============================================================================

const double _kDesktopBreakpoint = 760;
const Color _kBorder = Color(0xFFD9DCD9);
const Color _kInkMuted = Color(0xFF616A66);
const Color _kSidebarBg = Color(0xFFFBFCFB);

class _NavDestination {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final int pageIndex;
  const _NavDestination({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.pageIndex,
  });
}

// Home, Inventory, Users, Reports, Settings — in this order for desktop sidebar.
const List<_NavDestination> _kDesktopDestinations = [
  _NavDestination(icon: Icons.home_outlined, activeIcon: Icons.home, label: 'Home', pageIndex: 0),
  _NavDestination(icon: Icons.inventory_outlined, activeIcon: Icons.inventory, label: 'Inventory', pageIndex: 1),
  _NavDestination(icon: Icons.people_outline, activeIcon: Icons.people, label: 'Users', pageIndex: 2),
  _NavDestination(icon: Icons.bar_chart_outlined, activeIcon: Icons.bar_chart, label: 'Reports', pageIndex: 3),
  _NavDestination(icon: Icons.settings_outlined, activeIcon: Icons.settings, label: 'Settings', pageIndex: 4),
];

// Mobile bottom bar destinations: Home, Inventory, Reports, Settings (Users omitted for mobile nav bar).
const List<_NavDestination> _kMobileDestinations = [
  _NavDestination(icon: Icons.home_outlined, activeIcon: Icons.home, label: 'Home', pageIndex: 0),
  _NavDestination(icon: Icons.inventory_outlined, activeIcon: Icons.inventory, label: 'Inventory', pageIndex: 1),
  _NavDestination(icon: Icons.bar_chart_outlined, activeIcon: Icons.bar_chart, label: 'Reports', pageIndex: 3),
  _NavDestination(icon: Icons.settings_outlined, activeIcon: Icons.settings, label: 'Settings', pageIndex: 4),
];

Future<void> _confirmAndSignOut(BuildContext context, VoidCallback? onSignOut) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Sign out?'),
      content: const Text('You will need to sign in again to continue.'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Sign out')),
      ],
    ),
  );
  if (confirmed != true) return;

  if (onSignOut != null) {
    onSignOut();
    return;
  }

  await Supabase.instance.client.auth.signOut();
  if (context.mounted) {
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }
}

class AdminShell extends StatefulWidget {
  /// Your five real screens, same order as the nav: Home, Branches, Users,
  /// Reports, Settings.
  final List<Widget> pages;

  final String userName;
  final VoidCallback? onSignOut;

  AdminShell({
    super.key,
    required this.pages,
    this.userName = '',
    this.onSignOut,
  }) : assert(
  pages.length == _kDesktopDestinations.length,
  'AdminShell.pages must have exactly ${_kDesktopDestinations.length} entries '
      '(Home, Inventory, Users, Reports, Settings) — got ${pages.length}.',
  );

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _index = 0;

  void _onSelect(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= _kDesktopBreakpoint;

        if (isDesktop) {
          return Scaffold(
            body: Row(
              children: [
                _SideNav(
                  selectedIndex: _index,
                  onSelect: _onSelect,
                  userName: widget.userName,
                  onSignOut: widget.onSignOut,
                ),
                const VerticalDivider(width: 1, thickness: 1, color: _kBorder),
                Expanded(
                  child: IndexedStack(index: _index, children: widget.pages),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Column(
              children: [
                _MobileTopBar(userName: widget.userName, onSignOut: widget.onSignOut),
                Expanded(child: IndexedStack(index: _index, children: widget.pages)),
              ],
            ),
          ),
          bottomNavigationBar: SafeArea(
            top: false,
            child: _BottomNav(selectedIndex: _index, onSelect: _onSelect),
          ),
        );
      },
    );
  }
}

// ============================================================================
// MOBILE — floating bottom nav bar
// ============================================================================

class _BottomNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const _BottomNav({required this.selectedIndex, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kBorder),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: _kMobileDestinations.map((d) {
            final active = d.pageIndex == selectedIndex;
            final color = active ? primary : _kInkMuted;
            return Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onSelect(d.pageIndex),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(active ? d.activeIcon : d.icon, size: 20, color: color),
                      const SizedBox(height: 3),
                      Text(
                        d.label,
                        style: GoogleFonts.ibmPlexSans(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          color: color,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ============================================================================
// MOBILE — current-user header
// ============================================================================

class _MobileTopBar extends StatelessWidget {
  final String userName;
  final VoidCallback? onSignOut;

  const _MobileTopBar({required this.userName, this.onSignOut});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final initial = userName.trim().isNotEmpty ? userName.trim()[0].toUpperCase() : '?';

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: primary,
            child: Text(
              initial,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  userName.trim().isNotEmpty ? userName : 'Signed in',
                  style: GoogleFonts.ibmPlexSans(fontSize: 13.5, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Admin',
                  style: GoogleFonts.ibmPlexSans(fontSize: 11.5, color: _kInkMuted),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout, size: 19, color: _kInkMuted),
            onPressed: () => _confirmAndSignOut(context, onSignOut),
            splashRadius: 20,
            tooltip: 'Sign out',
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// DESKTOP — fixed side nav rail
// ============================================================================

class _SideNav extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final String userName;
  final VoidCallback? onSignOut;

  const _SideNav({
    required this.selectedIndex,
    required this.onSelect,
    required this.userName,
    this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final initial = userName.trim().isNotEmpty ? userName.trim()[0].toUpperCase() : '?';

    return Container(
      width: 220,
      color: _kSidebarBg,
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 24),
            child: Text(
              'TUMAINI INVESTMENTS',
              style: GoogleFonts.ibmPlexSans(fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.3),
            ),
          ),
          ..._kDesktopDestinations.map((d) {
            final active = d.pageIndex == selectedIndex;
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Material(
                color: active ? primary : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () => onSelect(d.pageIndex),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    child: Row(
                      children: [
                        Icon(active ? d.activeIcon : d.icon, size: 17, color: active ? Colors.white : _kInkMuted),
                        const SizedBox(width: 10),
                        Text(
                          d.label,
                          style: GoogleFonts.ibmPlexSans(
                            fontSize: 13.5,
                            fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                            color: active ? Colors.white : _kInkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
          const Spacer(),
          Container(
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: _kBorder))),
            padding: const EdgeInsets.only(top: 10),
            child: Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _confirmAndSignOut(context, onSignOut),
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: primary,
                        child: Text(
                          initial,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              userName.trim().isNotEmpty ? userName : 'Signed in',
                              style: GoogleFonts.ibmPlexSans(fontSize: 13, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text('Admin', style: GoogleFonts.ibmPlexSans(fontSize: 11, color: _kInkMuted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}