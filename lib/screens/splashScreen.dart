import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth-repository.dart';

/// Design tokens — matching the web splash screen 1:1.
class AppPalette {
  static const bg = Color(0xFFF6F8F5);
  static const ink = Color(0xFF17221D);
  static const inkMuted = Color(0xFF5C6B63);
  static const primary = Color(0xFF0B4A43);
  static const primaryDeep = Color(0xFF0E5C54);
  static const primaryTint = Color(0xFFE3EEEB);
  static const accent = Color(0xFFC68A3D);
  static const border = Color(0xFFDDE5DE);
}

/// First screen of the app. Shows itself for [holdDuration], then checks
/// whether a session already exists and routes accordingly:
///   - no session                -> /login
///   - session but not approved  -> signed out, then /login
///   - session, role == admin    -> /admin-home
///   - session, any other role   -> /home
class SplashScreen extends StatefulWidget {
  const SplashScreen({
    super.key,
    this.holdDuration = const Duration(seconds: 4),
  });

  final Duration holdDuration;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dotsController;
  final _authRepository = AuthRepository();
  Timer? _navTimer;

  @override
  void initState() {
    super.initState();
    _dotsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _navTimer = Timer(widget.holdDuration, _redirect);
  }

  Future<void> _redirect() async {
    String targetRoute = '/login';
    try {
      final user = await _authRepository.currentUser;
      if (user == null) {
        targetRoute = '/login';
      } else if (!user.isActive) {
        // Shouldn't normally happen (signIn already blocks this), but if a
        // stale/edge-case session exists, don't let it through silently.
        await _authRepository.signOut();
        targetRoute = '/login';
      } else {
        targetRoute = user.isAdmin ? '/admin-home' : '/home';
      }
    } catch (_) {
      targetRoute = '/login';
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacementNamed(targetRoute);
  }

  @override
  void dispose() {
    _navTimer?.cancel();
    _dotsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.bg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight,
                ),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 24,
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 480),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const _AppIcon(),
                                  const SizedBox(height: 28),
                                  const _Wordmark(),
                                  const SizedBox(height: 28),
                                  _PulsingDots(animation: _dotsController),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        const _Footer(),
                      ],
                    ),
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

class _AppIcon extends StatelessWidget {
  const _AppIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppPalette.primary, AppPalette.primaryDeep],
        ),
        boxShadow: [
          BoxShadow(
            color: AppPalette.primary.withOpacity(0.45),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: const Center(
        child: SizedBox(
          width: 38,
          height: 38,
          child: CustomPaint(painter: _CapsuleIconPainter()),
        ),
      ),
    );
  }
}

/// Redraws the pill-bottle mark from the web splash screen (24x24 viewBox)
/// so the two stay visually identical without shipping an SVG package.
class _CapsuleIconPainter extends CustomPainter {
  const _CapsuleIconPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final s = size.width / 24; // scale from the original 24x24 viewBox

    final body = RRect.fromLTRBR(
      3 * s, 9.5 * s, 21 * s, 19 * s, Radius.circular(4.5 * s),
    );
    canvas.drawRRect(body, paint);

    canvas.drawLine(Offset(12 * s, 9.5 * s), Offset(12 * s, 19 * s), paint);

    final neck = Path()
      ..moveTo(7 * s, 9.5 * s)
      ..lineTo(7 * s, 5.5 * s)
      ..arcToPoint(Offset(10 * s, 2.5 * s), radius: Radius.circular(3 * s))
      ..lineTo(14 * s, 2.5 * s)
      ..arcToPoint(Offset(17 * s, 5.5 * s), radius: Radius.circular(3 * s))
      ..lineTo(17 * s, 9.5 * s);
    canvas.drawPath(neck, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          'Pharmacy management system',
          textAlign: TextAlign.center,
          style: GoogleFonts.ibmPlexMono(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppPalette.inkMuted,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Tumaini Investments',
          textAlign: TextAlign.center,
          style: GoogleFonts.ibmPlexSans(
            fontSize: 25,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
            color: AppPalette.ink,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: 40,
          height: 3,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(3),
            gradient: const LinearGradient(
              colors: [AppPalette.primary, AppPalette.accent],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Point of sale & inventory management',
          textAlign: TextAlign.center,
          style: GoogleFonts.ibmPlexSans(fontSize: 13, color: AppPalette.inkMuted),
        ),
      ],
    );
  }
}

class _PulsingDots extends StatelessWidget {
  const _PulsingDots({required this.animation});
  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(3, (i) {
        return Padding(
          padding: EdgeInsets.only(right: i == 2 ? 0 : 6),
          child: AnimatedBuilder(
            animation: animation,
            builder: (context, _) {
              final t = ((animation.value - i * 0.15) % 1.0 + 1.0) % 1.0;
              final lit = t < 0.4;
              return Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: lit ? AppPalette.accent : AppPalette.border,
                ),
              );
            },
          ),
        );
      }),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 176, height: 1, color: AppPalette.border),
        const SizedBox(height: 12),
        Text(
          'Developed by',
          style: GoogleFonts.ibmPlexMono(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppPalette.inkMuted,
          ),
        ),
        const SizedBox(height: 12),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircleAvatar(
                radius: 11,
                backgroundImage: AssetImage('assets/images/jaytech_logo.png'),
              ),
              const SizedBox(width: 7),
              Text(
                'JayTech Solutions',
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.ink,
                ),
              ),
              const SizedBox(width: 14),
              Container(width: 1, height: 16, color: AppPalette.border),
              const SizedBox(width: 14),
              CircleAvatar(
                radius: 11,
                backgroundColor: AppPalette.primaryTint,
                child: Text(
                  'MS',
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: AppPalette.primary,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                'Mable Sinkhonde',
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.ink,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'v1.0.0',
          style: GoogleFonts.ibmPlexMono(fontSize: 10, color: AppPalette.inkMuted),
        ),
      ],
    );
  }
}