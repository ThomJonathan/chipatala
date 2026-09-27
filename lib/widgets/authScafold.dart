import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'branding.dart';

/// Shared frame for every auth screen (login, signup, forgot password).
///
/// Wide screens (>= 900px — desktop/web) get a two-pane layout: a dark
/// teal brand panel on the left carrying the icon, wordmark and footer
/// credit, and the form on the right. Narrow screens (phones) collapse to
/// a single scrollable column with a compact icon up top and the same
/// footer pinned below the form.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.form,
    this.footerLink,
  });

  final String title;
  final String subtitle;
  final Widget form;
  final Widget? footerLink;

  static const _desktopBreakpoint = 840.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.bg,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final isDesktop = constraints.maxWidth >= _desktopBreakpoint;
          return isDesktop ? _buildDesktop() : _buildMobile(context);
        },
      ),
    );
  }

  Widget _buildDesktop() {
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: Container(
            color: AppPalette.primaryDeep,
            child: SafeArea(
              right: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const AppIcon(size: 56),
                              const Spacer(),
                              const SizedBox(height: 32),
                              Text(
                                'Tumaini Investments',
                                style: GoogleFonts.ibmPlexSans(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Point of sale & inventory management',
                                style: GoogleFonts.ibmPlexSans(fontSize: 14, color: Colors.white70),
                              ),
                              const SizedBox(height: 32),
                              const Spacer(),
                              const DevelopedByFooter(onDark: true),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        Expanded(
          flex: 6,
          child: SafeArea(
            left: false,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: _FormColumn(
                    title: title,
                    subtitle: subtitle,
                    form: form,
                    footerLink: footerLink,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMobile(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final minHeight = constraints.maxHeight > 48 ? constraints.maxHeight - 48 : 0.0;
          return SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: minHeight,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: IntrinsicHeight(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 8),
                            const Center(child: AppIcon(size: 56)),
                            const SizedBox(height: 28),
                            _FormColumn(
                              title: title,
                              subtitle: subtitle,
                              form: form,
                              footerLink: footerLink,
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        const DevelopedByFooter(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FormColumn extends StatelessWidget {
  const _FormColumn({
    required this.title,
    required this.subtitle,
    required this.form,
    this.footerLink,
  });

  final String title;
  final String subtitle;
  final Widget form;
  final Widget? footerLink;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: AppPalette.ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: GoogleFonts.ibmPlexSans(fontSize: 14, color: AppPalette.inkMuted),
        ),
        const SizedBox(height: 28),
        form,
        if (footerLink != null) ...[
          const SizedBox(height: 20),
          footerLink!,
        ],
      ],
    );
  }
}