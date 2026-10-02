import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Shared design tokens — the same ones used on the splash screen.
class AppPalette {
  static const bg = Color(0xFFF7F9FF);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF0F2038);
  static const inkMuted = Color(0xFF5B6B8C);
  static const primary = Color(0xFF143D9E);
  static const primaryDeep = Color(0xFF0B2A72);
  static const primaryTint = Color(0xFFE4EAFB);
  static const accent = Color(0xFFC9A227);
  static const border = Color(0xFFD9E2F5);
  static const error = Color(0xFFB3413B);
}

/// The capsule/vial mark used on the splash screen and the auth brand panel.
class AppIcon extends StatelessWidget {
  const AppIcon({super.key, this.size = 64, this.iconColor = Colors.white});

  final double size;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.31),
        color: AppPalette.primary,
        boxShadow: [
          BoxShadow(
            color: AppPalette.primary.withValues(alpha: 0.4),
            blurRadius: size * 0.3,
            offset: Offset(0, size * 0.12),
          ),
        ],
      ),
      child: Center(
        child: SizedBox(
          width: size * 0.45,
          height: size * 0.45,
          child: CustomPaint(painter: _CapsuleIconPainter(color: iconColor)),
        ),
      ),
    );
  }
}

class _CapsuleIconPainter extends CustomPainter {
  const _CapsuleIconPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.075
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final s = size.width / 24; // scale from the original 24x24 viewBox

    final body = RRect.fromLTRBR(3 * s, 9.5 * s, 21 * s, 19 * s, Radius.circular(4.5 * s));
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
  bool shouldRepaint(covariant _CapsuleIconPainter oldDelegate) => oldDelegate.color != color;
}

/// The "Developed by — JayTech Solutions · Mable Sinkhonde" credit block.
/// Set [onDark] to true when placing it on the teal brand panel.
class DevelopedByFooter extends StatelessWidget {
  const DevelopedByFooter({super.key, this.onDark = false});

  final bool onDark;

  @override
  Widget build(BuildContext context) {
    final muted = onDark ? Colors.white70 : AppPalette.inkMuted;
    final ink = onDark ? Colors.white : AppPalette.ink;
    final dividerColor = onDark ? Colors.white24 : AppPalette.border;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(width: 176, height: 1, color: dividerColor),
        const SizedBox(height: 12),
        Text(
          'Developed by',
          style: GoogleFonts.ibmPlexMono(fontSize: 11, fontWeight: FontWeight.w500, color: muted),
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
                style: GoogleFonts.ibmPlexSans(fontSize: 13, fontWeight: FontWeight.w600, color: ink),
              ),
              const SizedBox(width: 14),
              Container(width: 1, height: 16, color: dividerColor),
              const SizedBox(width: 14),
              CircleAvatar(
                radius: 11,
                backgroundColor: onDark ? Colors.white24 : AppPalette.primaryTint,
                child: Text(
                  'MS',
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: onDark ? Colors.white : AppPalette.primary,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                'Mable Sinkhonde',
                style: GoogleFonts.ibmPlexSans(fontSize: 13, fontWeight: FontWeight.w600, color: ink),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A labeled text field styled to match the brand — used by every auth form.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.label,
    required this.controller,
    this.obscureText = false,
    this.keyboardType,
    this.validator,
    this.suffixIcon,
  });

  final String label;
  final TextEditingController controller;
  final bool obscureText;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final Widget? suffixIcon;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      validator: validator,
      style: GoogleFonts.ibmPlexSans(fontSize: 14, color: AppPalette.ink),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: GoogleFonts.ibmPlexSans(fontSize: 13, color: AppPalette.inkMuted),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: AppPalette.surface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppPalette.error, width: 1.5),
        ),
      ),
    );
  }
}

/// The single filled action button shared by every auth screen — deliberately
/// the only saturated, filled element on the form side.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.isLoading = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: isLoading ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppPalette.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppPalette.primary.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 0,
        ),
        child: isLoading
            ? const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        )
            : Text(
          label,
          style: GoogleFonts.ibmPlexSans(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

/// "Don't have an account? Create one" style link at the bottom of a form.
class SwitchAuthLink extends StatelessWidget {
  const SwitchAuthLink({
    super.key,
    required this.question,
    required this.actionLabel,
    required this.onTap,
  });

  final String question;
  final String actionLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: RichText(
        text: TextSpan(
          style: GoogleFonts.ibmPlexSans(fontSize: 13, color: AppPalette.inkMuted),
          children: [
            TextSpan(text: '$question '),
            TextSpan(
              text: actionLabel,
              style: const TextStyle(color: AppPalette.primary, fontWeight: FontWeight.w600),
              recognizer: TapGestureRecognizer()..onTap = onTap,
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline error banner shown above a form after a failed submit.
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppPalette.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.error.withValues(alpha: 0.25)),
      ),
      child: Text(
        message,
        style: GoogleFonts.ibmPlexSans(fontSize: 12.5, color: AppPalette.error),
      ),
    );
  }
}