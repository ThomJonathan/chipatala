import 'package:flutter/material.dart';

import 'adminui.dart';
import 'branch.dart';
import 'user.dart';

// ============================================================================
// ADMIN SETTINGS
//   Phones: this is where Branches and Users live (the bottom bar only has
//   Home, Inventory, Reports, Settings). Each row pushes the full screen.
//   Desktop: same page, harmless duplicate of the sidebar links.
// ============================================================================

class AdminSettingsScreen extends StatelessWidget {
  final String userName;
  const AdminSettingsScreen({super.key, this.userName = ''});

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: kBg,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= kWideContentBreakpoint;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(wide ? 32 : 18, wide ? 28 : 18, wide ? 32 : 18, 32),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Settings', style: sans(24, weight: FontWeight.w700, color: kInk)),
                      const SizedBox(height: 3),
                      Text('Manage your shops and the people who work in them.',
                          style: sans(13.5, color: kInkMuted)),
                      const SizedBox(height: 22),
                      Text('Management', style: sans(13, weight: FontWeight.w600, color: kInkMuted)),
                      const SizedBox(height: 8),
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: kBorder),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            _SettingsTile(
                              icon: Icons.storefront_outlined,
                              title: 'Branches',
                              subtitle: 'Add shops, edit details, deactivate or delete',
                              showDivider: true,
                              onTap: () => _open(context, const BranchesScreen(embedded: false)),
                            ),
                            _SettingsTile(
                              icon: Icons.people_outline,
                              title: 'Users',
                              subtitle: 'Approve sign-ups, assign branches, remove accounts',
                              onTap: () => _open(context, const UsersScreen(embedded: false)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text('Account', style: sans(13, weight: FontWeight.w600, color: kInkMuted)),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          border: Border.all(color: kBorder),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Avatar(name: userName),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(userName.trim().isNotEmpty ? userName : 'Signed in',
                                      overflow: TextOverflow.ellipsis,
                                      style: sans(14.5, weight: FontWeight.w600, color: kInk)),
                                  Text('Admin', style: sans(12.5, color: kInkMuted)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool showDivider;
  final VoidCallback onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.showDivider = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            border: showDivider ? const Border(bottom: BorderSide(color: kBorder)) : null,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: kPrimaryTint, borderRadius: BorderRadius.circular(10)),
                child: Icon(icon, size: 21, color: kPrimary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: sans(14.5, weight: FontWeight.w600, color: kInk)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: sans(12.5, color: kInkMuted, height: 1.35)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 20, color: kInkMuted),
            ],
          ),
        ),
      ),
    );
  }
}