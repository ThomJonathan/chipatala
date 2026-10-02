import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../screens/admin/stockAccessRepo.dart';

// ============================================================================
// ADMIN SHELL — one self-contained file: the admin navigation UI.
//   - phone widths  -> floating bottom nav bar (Home, Inventory, Reports, Settings)
//   - desktop widths -> fixed side nav rail (all 6 screens)
// Screens: Home, Inventory, Branches, Users, Reports, Settings.
// Desktop keeps all six destinations in the side rail; mobile exposes management
// screens through Settings so the bottom bar stays compact.
// ============================================================================

const double _kDesktopBreakpoint = 760;
const Color _kBorder = Color(0xFFD9E2F5);
const Color _kInkMuted = Color(0xFF5B6B8C);
const Color _kSidebarBg = Color(0xFFFFFFFF);

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

// Desktop destinations: Home, Inventory, Branches, Users, Reports, Settings.
const List<_NavDestination> _kDestinations = [
  _NavDestination(
    icon: Icons.home_outlined,
    activeIcon: Icons.home,
    label: 'Home',
    pageIndex: 0,
  ),
  _NavDestination(
    icon: Icons.inventory_outlined,
    activeIcon: Icons.inventory,
    label: 'Inventory',
    pageIndex: 1,
  ),
  _NavDestination(
    icon: Icons.storefront_outlined,
    activeIcon: Icons.storefront,
    label: 'Branches',
    pageIndex: 2,
  ),
  _NavDestination(
    icon: Icons.people_outline,
    activeIcon: Icons.people,
    label: 'Users',
    pageIndex: 3,
  ),
  _NavDestination(
    icon: Icons.bar_chart_outlined,
    activeIcon: Icons.bar_chart,
    label: 'Reports',
    pageIndex: 4,
  ),
  _NavDestination(
    icon: Icons.settings_outlined,
    activeIcon: Icons.settings,
    label: 'Settings',
    pageIndex: 5,
  ),
];

class AdminShellScope extends InheritedWidget {
  final int selectedIndex;
  final ValueChanged<int> selectTab;

  const AdminShellScope({
    super.key,
    required this.selectedIndex,
    required this.selectTab,
    required super.child,
  });

  static AdminShellScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AdminShellScope>();

  @override
  bool updateShouldNotify(AdminShellScope oldWidget) =>
      selectedIndex != oldWidget.selectedIndex;
}

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

class AdminShell extends StatefulWidget {
  /// Your six real screens, same order as the nav: Home, Inventory,
  /// Branches, Users, Reports, Settings.
  final List<Widget> pages;

  final String userName;
  final VoidCallback? onSignOut;

  const AdminShell({
    super.key,
    required this.pages,
    this.userName = '',
    this.onSignOut,
  }) : assert(
         pages.length == _kDestinations.length,
         'AdminShell.pages must have exactly ${_kDestinations.length} entries '
         '(Home, Inventory, Branches, Users, Reports, Settings) — got ${pages.length}.',
       );

  static void switchTo(BuildContext context, int index) {
    final scope =
        context.findAncestorWidgetOfExactType<AdminShellScope>() ??
        context.dependOnInheritedWidgetOfExactType<AdminShellScope>();
    if (scope != null) {
      scope.selectTab(index);
    }
  }

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _index = 0;

  void _onSelect(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    return AdminShellScope(
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
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: _kDestinations
              .where((d) => d.pageIndex != 2 && d.pageIndex != 3)
              .map((d) {
                // Users and Branches are opened from Settings on mobile.
                final active =
                    d.pageIndex == selectedIndex ||
                    (d.pageIndex == 5 &&
                        (selectedIndex == 2 || selectedIndex == 3));
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
                          Icon(
                            active ? d.activeIcon : d.icon,
                            size: 20,
                            color: color,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            d.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.ibmPlexSans(
                              fontSize: 10,
                              fontWeight: active
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: color,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              })
              .toList(),
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
    final initial = userName.trim().isNotEmpty
        ? userName.trim()[0].toUpperCase()
        : '?';

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
                Text(
                  'Admin',
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 11.5,
                    color: _kInkMuted,
                  ),
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
    final initial = userName.trim().isNotEmpty
        ? userName.trim()[0].toUpperCase()
        : '?';

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
          ..._kDestinations.map((d) {
            final active = d.pageIndex == selectedIndex;
            final isUsers = d.pageIndex == 3;
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Material(
                color: active ? primary : Colors.transparent,
                borderRadius: BorderRadius.circular(7),
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () => onSelect(d.pageIndex),
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
                        if (isUsers)
                          ValueListenableBuilder<int>(
                            valueListenable: stockAccessPendingCount,
                            builder: (_, pending, _) {
                              if (pending <= 0) return const SizedBox.shrink();
                              return Row(
                                children: [
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: active
                                          ? Colors.white
                                          : const Color(0xFFB4544A),
                                      borderRadius: BorderRadius.circular(9),
                                    ),
                                    child: Text(
                                      '$pending',
                                      style: GoogleFonts.ibmPlexSans(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: active ? primary : Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
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
                            Text(
                              'Admin',
                              style: GoogleFonts.ibmPlexSans(
                                fontSize: 11,
                                color: _kInkMuted,
                              ),
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
