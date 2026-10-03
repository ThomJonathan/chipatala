import 'package:shared_preferences/shared_preferences.dart';

// ============================================================================
// DEVICE PREFERENCES — cashier device settings (paper size, auto-print,
// default sale type). Saved per device; account data (name,
// phone) lives in the database instead.
// ============================================================================

class EmpPrefs {
  static const _paper = 'receipt_paper'; // roll80 | roll57 | a5
  static const _autoPrint = 'receipt_autoprint';
  static const _saleType = 'default_sale_type'; // retail | wholesale

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
}
