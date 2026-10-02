import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ============================================================================
// EMPLOYEE NAVIGATION SHELL — nav chrome only.
//
// This is just the responsive navigation: a floating bottom nav bar on
// phone widths, a fixed side rail on desktop widths. It owns none of the
// screen content — you pass in your five real screens and this just
// decides which one is visible and draws the nav around it.
//
// The currently signed-in user is shown on both: a slim top bar above the
// content on phone widths, and a user card at the bottom of the side rail
// on desktop widths. Pass userName / userRole / branchName and both take
// care of themselves — nothing else to wire up.
//
// Tapping sign out (the icon on mobile, the user card on desktop) always
// asks for confirmation first. By default it then signs out of Supabase
// directly and returns to '/login' — no wiring needed. Pass onSignOut only
// if you want different behavior (e.g. routing it through AuthRepository).
//
// HOW TO WIRE THIS IN:
//   1. Drop this file at lib/widgets/employee_shell.dart
//   2. In main.dart:
//        import './widgets/employee_shell.dart';
//        ...
//        '/home': (context) => EmployeeShell(
//              pages: const [
//                HomeScreen(),        // your real screens, in this order
//                NewSaleScreen(),
//                StockScreen(),
//                ReportsScreen(),
//                SettingsScreen(),
//              ],
//            ),
//      (delete or keep the old EmployeeHomePage placeholder, your call)
//   3. That's it for sign-out — it defaults to Supabase directly. Only pass
//      userName / userRole / branchName once you have the signed-in user,
//      and onSignOut only if you want it routed through AuthRepository
//      instead of the default:
//        EmployeeShell(
//          pages: [...],
//          userName: currentUser.fullName,
//          userRole: currentUser.role,
//          branchName: currentUser.branchName,
//        )
// ============================================================================

const double _kDesktopBreakpoint =
    760; // below this -> bottom nav, at/above -> side nav
const Color _kBorder = Color(0xFFD9E2F5);
const Color _kInkMuted = Color(0xFF5B6B8C);
const Color _kSidebarBg = Color(0xFFFFFFFF);

class _NavDestination {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _NavDestination({
    required this.icon,
    required this.activeIcon,
    required this.label,
  });
}

// Home, Sale, Stock, Reports, Settings — in this order. Whatever you pass
// into EmployeeShell.pages must be in this same order.
const List<_NavDestination> _kDestinations = [
  _NavDestination(
    icon: Icons.home_outlined,
    activeIcon: Icons.home,
    label: 'Home',
  ),
  _NavDestination(
    icon: Icons.point_of_sale_outlined,
    activeIcon: Icons.point_of_sale,
    label: 'Sale',
  ),
  _NavDestination(
    icon: Icons.inventory_2_outlined,
    activeIcon: Icons.inventory_2,
    label: 'Stock',
  ),
  _NavDestination(
    icon: Icons.bar_chart_outlined,
    activeIcon: Icons.bar_chart,
    label: 'Reports',
  ),
  _NavDestination(
    icon: Icons.settings_outlined,
    activeIcon: Icons.settings,
    label: 'Settings',
  ),
];

/// Confirms with the user, then signs out. If [onSignOut] is given, that
/// runs instead of the default (use this if sign-out needs to go through
/// your own AuthRepository rather than straight to Supabase).
Future<void> _confirmAndSignOut(
  BuildContext context,
  VoidCallback? onSignOut,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Sign out?'),
      content: const Text('You will need to sign in again to continue.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Sign out'),
        ),
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

class EmployeeShellScope extends InheritedWidget {
  final int selectedIndex;
  final ValueChanged<int> selectTab;

  const EmployeeShellScope({
    super.key,
    required this.selectedIndex,
    required this.selectTab,
    required super.child,
  });

  static EmployeeShellScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EmployeeShellScope>();

  @override
  bool updateShouldNotify(EmployeeShellScope oldWidget) =>
      selectedIndex != oldWidget.selectedIndex;
}

class EmployeeShell extends StatefulWidget {
  /// Your five real screens, in the same order as _kDestinations above
  /// (Home, Sale, Stock, Reports, Settings).
  final List<Widget> pages;

  final String userName;
  final String userRole;
  final String branchName;
  final VoidCallback? onSignOut;

  const EmployeeShell({
    super.key,
    required this.pages,
    this.userName = '',
    this.userRole = '',
    this.branchName = '',
    this.onSignOut,
  }) : assert(
         pages.length == _kDestinations.length,
         'EmployeeShell.pages must have exactly ${_kDestinations.length} entries '
         '(Home, Sale, Stock, Reports, Settings) — got ${pages.length}.',
       );

  static void switchTo(BuildContext context, int index) {
    final scope =
        context.findAncestorWidgetOfExactType<EmployeeShellScope>() ??
        context.dependOnInheritedWidgetOfExactType<EmployeeShellScope>();
    if (scope != null) {
      scope.selectTab(index);
    }
  }

  @override
  State<EmployeeShell> createState() => _EmployeeShellState();
}

class _EmployeeShellState extends State<EmployeeShell> {
  int _index = 0;

  void _onSelect(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    return EmployeeShellScope(
      selectedIndex: _index,
      selectTab: _onSelect,
      child: LayoutBuilder(
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
                    userRole: widget.userRole,
                    branchName: widget.branchName,
                    onSignOut: widget.onSignOut,
                  ),
                  const VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: _kBorder,
                  ),
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
                  _MobileTopBar(
                    userName: widget.userName,
                    userRole: widget.userRole,
                    branchName: widget.branchName,
                    onSignOut: widget.onSignOut,
                  ),
                  Expanded(
                    child: IndexedStack(index: _index, children: widget.pages),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: SafeArea(
              top: false,
              child: _BottomNav(selectedIndex: _index, onSelect: _onSelect),
            ),
          );
        },
      ),
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
          children: List.generate(_kDestinations.length, (i) {
            final d = _kDestinations[i];
            final active = i == selectedIndex;
            final color = active ? primary : _kInkMuted;
            return Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => onSelect(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        active ? d.activeIcon : d.icon,
                        size: 20,
                        color: color,
                      ),
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
          }),
        ),
      ),
    );
  }
}

// ============================================================================
// MOBILE — current-user header (desktop shows the same info in the side
// rail's own user card at the bottom, so it doesn't need this bar too)
// ============================================================================

class _MobileTopBar extends StatelessWidget {
  final String userName;
  final String userRole;
  final String branchName;
  final VoidCallback? onSignOut;

  const _MobileTopBar({
    required this.userName,
    required this.userRole,
    required this.branchName,
    this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final initial = userName.trim().isNotEmpty
        ? userName.trim()[0].toUpperCase()
        : '?';
    final roleLine = [
      userRole,
      branchName,
    ].where((s) => s.trim().isNotEmpty).join(' · ');

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
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
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
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (roleLine.isNotEmpty)
                  Text(
                    roleLine,
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 11.5,
                      color: _kInkMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
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
  final String userRole;
  final String branchName;
  final VoidCallback? onSignOut;

  const _SideNav({
    required this.selectedIndex,
    required this.onSelect,
    required this.userName,
    required this.userRole,
    required this.branchName,
    this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final initial = userName.trim().isNotEmpty
        ? userName.trim()[0].toUpperCase()
        : '?';
    final roleLine = [
      userRole,
      branchName,
    ].where((s) => s.trim().isNotEmpty).join(' · ');

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
              style: GoogleFonts.ibmPlexSans(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
          ...List.generate(_kDestinations.length, (i) {
            final d = _kDestinations[i];
            final active = i == selectedIndex;
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Material(
                color: active ? primary : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () => onSelect(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          active ? d.activeIcon : d.icon,
                          size: 17,
                          color: active ? Colors.white : _kInkMuted,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          d.label,
                          style: GoogleFonts.ibmPlexSans(
                            fontSize: 13.5,
                            fontWeight: active
                                ? FontWeight.w600
                                : FontWeight.w500,
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
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _kBorder)),
            ),
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
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              userName.trim().isNotEmpty
                                  ? userName
                                  : 'Signed in',
                              style: GoogleFonts.ibmPlexSans(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (roleLine.isNotEmpty)
                              Text(
                                roleLine,
                                style: GoogleFonts.ibmPlexSans(
                                  fontSize: 11,
                                  color: _kInkMuted,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.logout,
                          size: 18,
                          color: _kInkMuted,
                        ),
                        onPressed: () => _confirmAndSignOut(context, onSignOut),
                        tooltip: 'Sign out',
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
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
