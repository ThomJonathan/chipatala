import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ============================================================================
// EMPLOYEE UI — shared tokens + small widgets for branch-staff screens.
// Mirrors the brand (blue/gold/white) used on the admin side. Colour is used
// only for meaning: amber = low stock, red = expiry/danger, blue = actions.
// ============================================================================

const double empWideBreakpoint = 760;
const double empTabletBreakpoint = 600;

const Color empBg = Color(0xFFF7F9FF);
const Color empSurface = Color(0xFFFFFFFF);
const Color empBorder = Color(0xFFD9E2F5);
const Color empInk = Color(0xFF0F2038);
const Color empMuted = Color(0xFF5B6B8C);
const Color empPrimary = Color(0xFF143D9E);
const Color empPrimaryTint = Color(0xFFE4EAFB);
const Color empGold = Color(0xFFC9A227);
const Color empWarn = Color(0xFFB07A28);
const Color empWarnTint = Color(0xFFFEF6E8);
const Color empDanger = Color(0xFFB4544A);
const Color empDangerTint = Color(0xFFFBEBEA);
const Color empSuccess = Color(0xFF2E7D32);
const Color empSuccessTint = Color(0xFFE8F5E9);

TextStyle empSans(double size, {FontWeight? weight, Color? color, double? height}) =>
    GoogleFonts.ibmPlexSans(fontSize: size, fontWeight: weight, color: color, height: height);

TextStyle empMono(double size, {FontWeight? weight, Color? color}) =>
    GoogleFonts.ibmPlexMono(fontSize: size, fontWeight: weight, color: color);

String empMk(double amount) {
  final neg = amount < 0;
  final s = amount.abs().round().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return 'MK ${neg ? '-' : ''}$buf';
}

String empQty(double q) => q.toStringAsFixed(q.truncateToDouble() == q ? 0 : 2);

void empToast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message, style: empSans(13.5, weight: FontWeight.w500, color: Colors.white)),
      backgroundColor: error ? empDanger : empPrimary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 4),
    ),
  );
}

/// Plain white card used for every Home block.
class EmpCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const EmpCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: empSurface,
        border: Border.all(color: empBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}

class EmpEmpty extends StatelessWidget {
  final IconData icon;
  final String message;
  const EmpEmpty({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return EmpCard(
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: empPrimaryTint, borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 19, color: empPrimary),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(message, style: empSans(13, color: empMuted, height: 1.4))),
        ],
      ),
    );
  }
}

/// Bottom sheet frame (mobile) / dialog content (desktop via showDialog).
class EmpSheetFrame extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const EmpSheetFrame({super.key, required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.fromLTRB(24, 12, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: empBorder, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: empSans(18, weight: FontWeight.w700, color: empInk)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(subtitle!, style: empSans(13, color: empMuted)),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20, color: empMuted),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

InputDecoration empField(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: empSans(13.5, color: empMuted),
      hintStyle: empSans(13.5, color: empMuted),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: empBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: empBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: empPrimary, width: 1.5),
      ),
    );

ButtonStyle empPrimaryButton({double height = 48}) => FilledButton.styleFrom(
      backgroundColor: empPrimary,
      foregroundColor: Colors.white,
      minimumSize: Size(0, height),
      textStyle: empSans(15, weight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
    );
