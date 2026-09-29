import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ============================================================================
// ADMIN UI — Design tokens, common widgets and dialog helpers
// ============================================================================

const double kWideContentBreakpoint = 760;
const Color kBg = Color(0xFFF7F9FF);
const Color kSurface = Color(0xFFF0F4FD);
const Color kBorder = Color(0xFFD9E2F5);
const Color kInk = Color(0xFF0F2038);
const Color kInkMuted = Color(0xFF5B6B8C);
const Color kPrimary = Color(0xFF143D9E);
const Color kPrimaryTint = Color(0xFFE4EAFB);
const Color kDanger = Color(0xFFB4544A);
const Color kDangerTint = Color(0xFFFBEBEA);
const Color kSuccess = Color(0xFF2E7D32);
const Color kSuccessTint = Color(0xFFE8F5E9);
const Color kWarn = Color(0xFFB07A28);
const Color kWarnTint = Color(0xFFFEF6E8);

TextStyle sans(double size, {FontWeight? weight, Color? color, double? height}) =>
    GoogleFonts.ibmPlexSans(fontSize: size, fontWeight: weight, color: color, height: height);

TextStyle mono(double size, {FontWeight? weight, Color? color, double? height}) =>
    GoogleFonts.ibmPlexMono(fontSize: size, fontWeight: weight, color: color, height: height);

InputDecoration fieldDecoration(String label, {String? hint}) => InputDecoration(
      labelText: label,
      hintText: hint,
      labelStyle: sans(13.5, color: kInkMuted),
      hintStyle: sans(13.5, color: kInkMuted),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kPrimary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDanger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: kDanger, width: 1.5),
      ),
    );

ButtonStyle primaryButtonStyle({double height = 44}) => FilledButton.styleFrom(
      backgroundColor: kPrimary,
      foregroundColor: Colors.white,
      minimumSize: Size(0, height),
      textStyle: sans(14, weight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      elevation: 0,
    );

ButtonStyle outlineButtonStyle({double height = 44}) => OutlinedButton.styleFrom(
      foregroundColor: kInk,
      minimumSize: Size(0, height),
      textStyle: sans(14, weight: FontWeight.w600),
      side: const BorderSide(color: kBorder),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    );

class Avatar extends StatelessWidget {
  final String name;
  final double radius;
  final bool muted;

  const Avatar({
    super.key,
    required this.name,
    this.radius = 18,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final initial = trimmed.isNotEmpty ? trimmed[0].toUpperCase() : '?';
    return CircleAvatar(
      radius: radius,
      backgroundColor: muted ? kSurface : kPrimaryTint,
      child: Text(
        initial,
        style: sans(
          radius * 0.8,
          weight: FontWeight.w700,
          color: muted ? kInkMuted : kPrimary,
        ),
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  final IconData? icon;

  const StatusPill({
    super.key,
    required this.label,
    required this.bg,
    required this.fg,
    this.icon,
  });

  factory StatusPill.active([String label = 'Active']) => StatusPill(
        label: label,
        bg: kSuccessTint,
        fg: kSuccess,
        icon: Icons.check_circle_outline,
      );

  factory StatusPill.inactive([String label = 'Inactive']) => StatusPill(
        label: label,
        bg: kSurface,
        fg: kInkMuted,
        icon: Icons.pause_circle_outline,
      );

  factory StatusPill.pending([String label = 'Pending approval']) => StatusPill(
        label: label,
        bg: kWarnTint,
        fg: kWarn,
        icon: Icons.hourglass_top_outlined,
      );

  factory StatusPill.neutral(String label, {IconData? icon}) => StatusPill(
        label: label,
        bg: kSurface,
        fg: kInkMuted,
        icon: icon,
      );

  factory StatusPill.warning(String label, {IconData? icon}) => StatusPill(
        label: label,
        bg: kWarnTint,
        fg: kWarn,
        icon: icon,
      );

  factory StatusPill.danger(String label, {IconData? icon}) => StatusPill(
        label: label,
        bg: kDangerTint,
        fg: kDanger,
        icon: icon,
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: sans(11.5, weight: FontWeight.w600, color: fg),
          ),
        ],
      ),
    );
  }
}

class FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const FilterPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? kPrimary : Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? kPrimary : kBorder),
          ),
          child: Text(
            label,
            style: sans(
              12.5,
              weight: FontWeight.w600,
              color: selected ? Colors.white : kInkMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class SearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  final TextEditingController? controller;

  const SearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.controller,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      style: sans(14, color: kInk),
      cursorColor: kPrimary,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: sans(13.5, color: kInkMuted),
        prefixIcon: const Icon(Icons.search, size: 20, color: kInkMuted),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: kBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: kPrimary, width: 1.5),
        ),
      ),
    );
  }
}

class PageTitle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const PageTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: sans(24, weight: FontWeight.w700, color: kInk)),
              if (subtitle != null) ...[
                const SizedBox(height: 3),
                Text(subtitle!, style: sans(13.5, color: kInkMuted)),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 16),
          trailing!,
        ],
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: kSurface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: kBorder),
              ),
              child: Icon(icon, size: 28, color: kInkMuted),
            ),
            const SizedBox(height: 16),
            Text(title, style: sans(16, weight: FontWeight.w600, color: kInk)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: sans(13.5, color: kInkMuted, height: 1.4),
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const ErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: kDangerTint,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.error_outline, size: 28, color: kDanger),
            ),
            const SizedBox(height: 16),
            Text('Something went wrong', style: sans(16, weight: FontWeight.w600, color: kInk)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: sans(13.5, color: kInkMuted, height: 1.4),
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: onRetry,
              style: outlineButtonStyle(),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class SheetFrame extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const SheetFrame({
    super.key,
    required this.title,
    this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.fromLTRB(
        24,
        20,
        24,
        MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: sans(18, weight: FontWeight.w700, color: kInk)),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(subtitle!, style: sans(13, color: kInkMuted)),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20, color: kInkMuted),
                  onPressed: () => Navigator.of(context).pop(),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 20),
            child,
          ],
        ),
      ),
    );
  }
}

Future<T?> showAdaptiveSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final isDesktop = MediaQuery.of(context).size.width >= kWideContentBreakpoint;
  if (isDesktop) {
    return showDialog<T>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: builder(ctx),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: builder,
  );
}

Future<bool> showConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Confirm',
  bool destructive = false,
}) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      title: Text(title, style: sans(17, weight: FontWeight.w700, color: kInk)),
      content: Text(message, style: sans(13.5, color: kInkMuted, height: 1.4)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text('Cancel', style: sans(13.5, weight: FontWeight.w600, color: kInkMuted)),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: destructive ? kDanger : kPrimary,
            foregroundColor: Colors.white,
            textStyle: sans(13.5, weight: FontWeight.w600),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return res ?? false;
}

void showToast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).hideCurrentSnackBar();
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        message,
        style: sans(13.5, weight: FontWeight.w500, color: Colors.white),
      ),
      backgroundColor: error ? kDanger : kPrimary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      margin: const EdgeInsets.all(16),
      duration: const Duration(seconds: 4),
    ),
  );
}
