import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================================
// DEVICE PREFERENCES — cashier device settings (paper size, auto-print,
// default sale type, appearance). Saved per device; account data (name,
// phone) lives in the database instead.
// ============================================================================

/// Drives MaterialApp.themeMode. Settings writes it; main.dart listens.
final appThemeMode = ValueNotifier<ThemeMode>(ThemeMode.system);

class EmpPrefs {
  static const _paper = 'receipt_paper'; // roll80 | roll57 | a5
  static const _autoPrint = 'receipt_autoprint';
  static const _saleType = 'default_sale_type'; // retail | wholesale
  static const _theme = 'appearance'; // system | light | dark

  static Future<String> paperSize() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_paper);
    return (v == 'roll57' || v == 'a5') ? v! : 'roll80';
  }

  static Future<void> setPaperSize(String v) async {
    await (await SharedPreferences.getInstance()).setString(_paper, v);
  }

  static Future<bool> autoPrint() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_autoPrint) ?? false;
  }

  static Future<void> setAutoPrint(bool v) async {
    await (await SharedPreferences.getInstance()).setBool(_autoPrint, v);
  }

  static Future<String> defaultSaleType() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_saleType);
    return v == 'wholesale' ? 'wholesale' : 'retail';
  }

  static Future<void> setDefaultSaleType(String v) async {
    await (await SharedPreferences.getInstance()).setString(_saleType, v);
  }

  static Future<String> appearance() async {
    final p = await SharedPreferences.getInstance();
    final v = p.getString(_theme);
    return (v == 'light' || v == 'dark') ? v! : 'system';
  }

  static Future<void> setAppearance(String v) async {
    (await SharedPreferences.getInstance()).setString(_theme, v);
    appThemeMode.value = v == 'light'
        ? ThemeMode.light
        : v == 'dark'
        ? ThemeMode.dark
        : ThemeMode.system;
  }

  /// Call once at startup so the saved appearance applies immediately.
  static Future<void> applySavedAppearance() async {
    final v = await appearance();
    appThemeMode.value = v == 'light'
        ? ThemeMode.light
        : v == 'dark'
        ? ThemeMode.dark
        : ThemeMode.system;
  }
}
