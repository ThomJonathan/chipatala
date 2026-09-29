import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

const businessName = 'TUMAINI INVESTMENTS';

class ReceiptService {
  static final _money = NumberFormat('#,##0.00');
  static final _dateFmt = DateFormat('dd MMM yyyy, HH:mm');
  static String _mk(num v) => 'MK ${_money.format(v)}';

  /// Sale dates are stored as timestamptz; receipts always show Malawi time.
  static DateTime _malawiTime(String iso) =>
      DateTime.parse(iso).toUtc().add(const Duration(hours: 2));

  /// [format]: roll80 for 80mm thermal printers, roll57 for 58mm, PdfPageFormat.a5 for normal paper.
  static Future<pw.Document> build(
      Map<String, dynamic> r, {
        PdfPageFormat format = PdfPageFormat.roll80,
        double? cashReceived, // only known at the counter, not stored in the database
        double? change,
      }) async {
    final items = (r['items'] as List).cast<Map<String, dynamic>>();
    final balanceDue = (r['balance_due'] as num).toDouble();
    final date = _malawiTime(r['sale_date'] as String);

    pw.Widget line(String l, String rgt, {bool bold = false}) => pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(l, style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : null)),
        pw.Text(rgt, style: pw.TextStyle(fontSize: 9, fontWeight: bold ? pw.FontWeight.bold : null)),
      ],
    );
    final divider = pw.Divider(thickness: 0.5, height: 8);
    pw.Widget center(String t, {double size = 9, bool bold = false}) => pw.Center(
        child: pw.Text(t, style: pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : null)));

    final doc = pw.Document();
    doc.addPage(pw.Page(
      pageFormat: format.copyWith(
          marginLeft: 4 * PdfPageFormat.mm, marginRight: 4 * PdfPageFormat.mm,
          marginTop: 4 * PdfPageFormat.mm, marginBottom: 6 * PdfPageFormat.mm),
      build: (_) => pw.Column(
        mainAxisSize: pw.MainAxisSize.min,
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          center(businessName, size: 12, bold: true),
          center(r['branch_name'] ?? ''),
          if (r['branch_location'] != null) center(r['branch_location']),
          if (r['branch_phone'] != null) center('Tel: ${r['branch_phone']}'),
          divider,
          line('Receipt', r['receipt_number']),
          line('Date', _dateFmt.format(date)),
          if (r['cashier_name'] != null) line('Served by', r['cashier_name']),
          if (r['customer_name'] != null) line('Customer', r['customer_name']),
          if (r['sale_type'] == 'wholesale') line('Sale type', 'Wholesale'),
          divider,
          for (final it in items) ...[
            pw.Text(it['name'], style: const pw.TextStyle(fontSize: 9)),
            line('  ${it['quantity']} x ${_money.format(it['unit_price'])}', _money.format(it['subtotal'])),
            pw.SizedBox(height: 2),
          ],
          divider,
          line('TOTAL', _mk(r['total_amount']), bold: true),
          line('Paid (${(r['payment_method'] as String).replaceAll('_', ' ')})', _mk(r['amount_paid'])),
          if (balanceDue > 0) line('Balance owing', _mk(balanceDue), bold: true),
          if (cashReceived != null) line('Cash received', _mk(cashReceived)),
          if (change != null && change > 0) line('Change', _mk(change)),
          divider,
          center('Thank you for your purchase!'),
        ],
      ),
    ));
    return doc;
  }

  static Future<void> printReceipt(Map<String, dynamic> r,
      {PdfPageFormat format = PdfPageFormat.roll80, double? cashReceived, double? change}) async {
    final doc = await build(r, format: format, cashReceived: cashReceived, change: change);
    await Printing.layoutPdf(name: 'Receipt ${r['receipt_number']}', onLayout: (_) => doc.save());
  }

  static Future<void> shareReceipt(Map<String, dynamic> r,
      {PdfPageFormat format = PdfPageFormat.roll80, double? cashReceived, double? change}) async {
    final doc = await build(r, format: format, cashReceived: cashReceived, change: change);
    await Printing.sharePdf(bytes: await doc.save(), filename: '${r['receipt_number']}.pdf');
  }
}