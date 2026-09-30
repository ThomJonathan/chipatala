import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../appPrefs.dart';
import '../employer/saleScreen.dart' show saleCartCount;
import 'employeeUi.dart';
import 'receipt.dart';

// ============================================================================
// CASHIER SETTINGS — own account + this device. No business settings.
//   Profile (name/phone) via update_own_profile(); password + sign-out via
//   Supabase Auth; everything else lives in device preferences. Sheets keep
//   the bottom nav visible; dialogs on desktop.
// ============================================================================

class SettingsScreen extends StatefulWidget {
  final String userId;
  final String fullName;
  final String email;
  final String role;
  final String branchName;
  final String branchPhone;
  const SettingsScreen({
    super.key,
    required this.userId,
    required this.fullName,
    required this.email,
    required this.role,
    required this.branchName,
    required this.branchPhone,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

String _roleLabel(String role) {
  switch (role) {
    case 'stock_controller':
      return 'Stock controller';
    case 'cashier':
      return 'Cashier';
    case 'manager':
      return 'Manager';
    case 'admin':
      return 'Admin';
    default:
      return role;
  }
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _name = '';
  String _phone = '';
  bool _editingProfile = false;
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  bool _savingProfile = false;

  String _paper = 'roll80';
  bool _autoPrint = false;
  String _saleType = 'retail';
  String _appearance = 'system';

  @override
  void initState() {
    super.initState();
    _name = widget.fullName;
    _nameCtrl.text = widget.fullName;
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final row = await Supabase.instance.client
          .from('users')
          .select('full_name, phone')
          .eq('id', widget.userId)
          .single();
      if (!mounted) return;
      setState(() {
        _name = (row['full_name'] as String?) ?? widget.fullName;
        _phone = (row['phone'] as String?) ?? '';
        _nameCtrl.text = _name;
        _phoneCtrl.text = _phone;
      });
    } catch (_) {}
    final paper = await EmpPrefs.paperSize();
    final auto = await EmpPrefs.autoPrint();
    final type = await EmpPrefs.defaultSaleType();
    final theme = await EmpPrefs.appearance();
    if (!mounted) return;
    setState(() {
      _paper = paper;
      _autoPrint = auto;
      _saleType = type;
      _appearance = theme;
    });
  }

  Future<void> _saveProfile() async {
    if (_nameCtrl.text.trim().isEmpty) {
      empToast(context, 'Full name is required.', error: true);
      return;
    }
    setState(() => _savingProfile = true);
    try {
      await Supabase.instance.client.rpc(
        'update_own_profile',
        params: {
          'p_full_name': _nameCtrl.text.trim(),
          'p_phone': _phoneCtrl.text.trim().isEmpty
              ? null
              : _phoneCtrl.text.trim(),
        },
      );
      if (!mounted) return;
      setState(() {
        _name = _nameCtrl.text.trim();
        _phone = _phoneCtrl.text.trim();
        _editingProfile = false;
        _savingProfile = false;
      });
      empToast(context, 'Profile updated.');
    } on PostgrestException catch (e) {
      if (!mounted) return;
      setState(() => _savingProfile = false);
      empToast(context, e.message, error: true);
    }
  }

  Future<void> _changePassword() async {
    final result = await _showSettingsSheet<List<String>>(
      context,
      builder: (_) => const _PasswordSheet(),
    );
    if (result == null || result.length != 2) return;
    if (result[0] != result[1]) {
      if (mounted)
        empToast(context, 'The two passwords don’t match.', error: true);
      return;
    }
    if (result[0].length < 6) {
      if (mounted)
        empToast(
          context,
          'Password is too short — use at least 6 characters.',
          error: true,
        );
      return;
    }
    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: result[0]),
      );
      if (mounted) empToast(context, 'Password changed.');
    } on AuthException catch (e) {
      if (!mounted) return;
      final msg = e.message.toLowerCase();
      if (msg.contains('reauth') ||
          msg.contains('session') ||
          msg.contains('expired') ||
          e.statusCode == '401') {
        empToast(
          context,
          'Your sign-in is too old — sign out and sign in again first.',
          error: true,
        );
      } else {
        empToast(context, e.message, error: true);
      }
    }
  }

  Future<void> _signOut() async {
    if (saleCartCount.value > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Sign out?'),
          content: Text(
            'A sale is in progress (${saleCartCount.value} ${saleCartCount.value == 1 ? 'item' : 'items'} in the cart). Signing out will lose it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Stay'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Sign out anyway'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    } else {
      final ok = await showDialog<bool>(
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
      if (ok != true) return;
    }
    await Supabase.instance.client.auth.signOut();
    if (mounted)
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
  }

  Future<void> _testPrint() async {
    final now = DateTime.now().toUtc().add(const Duration(hours: 2));
    final sample = <String, dynamic>{
      'items': [
        {
          'name': 'AMLODIPINE TABS',
          'quantity': 2,
          'unit_price': 500,
          'subtotal': 1000,
        },
        {
          'name': 'GLOVES (BOX)',
          'quantity': 1,
          'unit_price': 2500,
          'subtotal': 2500,
        },
      ],
      'balance_due': 0,
      'sale_date': now.toIso8601String(),
      'branch_name': widget.branchName,
      'receipt_number': 'TEST-000000',
      'total_amount': 3500,
      'amount_paid': 3500,
      'payment_method': 'cash',
      'cashier_name': _name,
    };
    final format = _paper == 'roll57'
        ? PdfPageFormat.roll57
        : _paper == 'a5'
        ? PdfPageFormat.a5
        : PdfPageFormat.roll80;
    try {
      await ReceiptService.printReceipt(sample, format: format);
    } catch (e) {
      if (mounted) empToast(context, 'Printing failed: $e', error: true);
    }
  }

  // ---- Build -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: empBg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, c) {
            final wide = c.maxWidth >= empWideBreakpoint;
            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                wide ? 32 : 18,
                wide ? 28 : 14,
                wide ? 32 : 18,
                24,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Settings',
                        style: empSans(
                          22,
                          weight: FontWeight.w700,
                          color: empInk,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Your account and this device.',
                        style: empSans(12.5, color: empMuted),
                      ),
                      const SizedBox(height: 16),
                      _accountCard(),
                      const SizedBox(height: 12),
                      _receiptsCard(),
                      const SizedBox(height: 12),
                      _saleDefaultsCard(),
                      const SizedBox(height: 12),
                      _appearanceCard(),
                      const SizedBox(height: 12),
                      _aboutCard(),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 50,
                        child: OutlinedButton.icon(
                          onPressed: _signOut,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: empDanger,
                            side: const BorderSide(color: empBorder),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(Icons.logout, size: 19),
                          label: const Text('Sign out'),
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

  Widget _cardTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: empSans(15, weight: FontWeight.w700, color: empInk),
      ),
    );
  }

  Widget _accountCard() {
    return EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('Account'),
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: empPrimary,
                child: Text(
                  _name.trim().isEmpty ? '?' : _name.trim()[0].toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 19,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _name.isEmpty ? '—' : _name,
                      style: empSans(
                        15,
                        weight: FontWeight.w700,
                        color: empInk,
                      ),
                    ),
                    Text(widget.email, style: empSans(12.5, color: empMuted)),
                    const SizedBox(height: 2),
                    Text(
                      '${_roleLabel(widget.role)} · ${widget.branchName}',
                      style: empSans(12, color: empMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_editingProfile) ...[
            TextField(
              controller: _nameCtrl,
              style: empSans(14, color: empInk),
              decoration: empField('Full name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              style: empSans(14, color: empInk),
              decoration: empField('Phone number'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _savingProfile
                        ? null
                        : () => setState(() {
                            _editingProfile = false;
                            _nameCtrl.text = _name;
                            _phoneCtrl.text = _phone;
                          }),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: empInk,
                      minimumSize: const Size(0, 44),
                      side: const BorderSide(color: empBorder),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: _savingProfile ? null : _saveProfile,
                    style: empPrimaryButton(height: 44),
                    child: _savingProfile
                        ? const SizedBox(
                            width: 19,
                            height: 19,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Save'),
                  ),
                ),
              ],
            ),
          ] else
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _editingProfile = true),
                style: OutlinedButton.styleFrom(
                  foregroundColor: empPrimary,
                  minimumSize: const Size(0, 44),
                  side: const BorderSide(color: empBorder),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(
                  _phone.isEmpty ? 'Add name & phone' : 'Edit name & phone',
                ),
              ),
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton.icon(
              onPressed: _changePassword,
              style: TextButton.styleFrom(
                foregroundColor: empPrimary,
                minimumSize: const Size(0, 44),
              ),
              icon: const Icon(Icons.lock_outline, size: 18),
              label: const Text('Change password'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _receiptsCard() {
    return EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('Receipts & printing'),
          Text(
            'Paper size',
            style: empSans(13, weight: FontWeight.w600, color: empMuted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _optionChip('80mm roll', 'roll80', _paper, (v) async {
                setState(() => _paper = v);
                await EmpPrefs.setPaperSize(v);
              }),
              _optionChip('58mm roll', 'roll57', _paper, (v) async {
                setState(() => _paper = v);
                await EmpPrefs.setPaperSize(v);
              }),
              _optionChip('A5 paper', 'a5', _paper, (v) async {
                setState(() => _paper = v);
                await EmpPrefs.setPaperSize(v);
              }),
            ],
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            value: _autoPrint,
            onChanged: (v) async {
              setState(() => _autoPrint = v);
              await EmpPrefs.setAutoPrint(v);
            },
            title: Text(
              'Print receipt automatically',
              style: empSans(13.5, color: empInk),
            ),
            subtitle: Text(
              'After each sale, without asking.',
              style: empSans(12, color: empMuted),
            ),
            activeColor: empPrimary,
            contentPadding: EdgeInsets.zero,
          ),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _testPrint,
              style: OutlinedButton.styleFrom(
                foregroundColor: empPrimary,
                minimumSize: const Size(0, 44),
                side: const BorderSide(color: empBorder),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              icon: const Icon(Icons.print_outlined, size: 18),
              label: const Text('Test print'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _saleDefaultsCard() {
    return EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('Sale defaults'),
          Text(
            'Default sale type for new sales',
            style: empSans(13, weight: FontWeight.w600, color: empMuted),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              _optionChip('Retail', 'retail', _saleType, (v) async {
                setState(() => _saleType = v);
                await EmpPrefs.setDefaultSaleType(v);
              }),
              _optionChip('Wholesale', 'wholesale', _saleType, (v) async {
                setState(() => _saleType = v);
                await EmpPrefs.setDefaultSaleType(v);
              }),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'You can still change it on each sale.',
            style: empSans(12, color: empMuted),
          ),
        ],
      ),
    );
  }

  Widget _appearanceCard() {
    return EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('Appearance'),
          Wrap(
            spacing: 8,
            children: [
              _optionChip('Light', 'light', _appearance, (v) async {
                setState(() => _appearance = v);
                await EmpPrefs.setAppearance(v);
              }),
              _optionChip('Dark', 'dark', _appearance, (v) async {
                setState(() => _appearance = v);
                await EmpPrefs.setAppearance(v);
              }),
              _optionChip('Follow device', 'system', _appearance, (v) async {
                setState(() => _appearance = v);
                await EmpPrefs.setAppearance(v);
              }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _aboutCard() {
    return EmpCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _cardTitle('About'),
          _aboutRow('App version', '1.0.0'),
          _aboutRow('Branch', widget.branchName),
          if (widget.branchPhone.isNotEmpty)
            _aboutRow('Branch phone', widget.branchPhone),
          const SizedBox(height: 8),
          Text(
            'For role, branch or access changes, contact your admin.',
            style: empSans(12, color: empMuted, height: 1.4),
          ),
        ],
      ),
    );
  }

  Widget _aboutRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: empSans(13, color: empMuted)),
          ),
          Text(
            value,
            style: empSans(13, weight: FontWeight.w600, color: empInk),
          ),
        ],
      ),
    );
  }

  Widget _optionChip(
    String label,
    String value,
    String group,
    ValueChanged<String> onPick,
  ) {
    final active = group == value;
    return ChoiceChip(
      label: Text(label),
      selected: active,
      onSelected: (_) => onPick(value),
      selectedColor: empPrimary,
      backgroundColor: empSurface,
      side: BorderSide(color: active ? empPrimary : empBorder),
      labelStyle: empSans(
        13,
        weight: FontWeight.w600,
        color: active ? Colors.white : empMuted,
      ),
      showCheckmark: false,
    );
  }
}

Future<T?> _showSettingsSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final wide = MediaQuery.of(context).size.width >= empWideBreakpoint;
  if (wide) {
    return showDialog<T>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(child: builder(ctx)),
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

class _PasswordSheet extends StatefulWidget {
  const _PasswordSheet();

  @override
  State<_PasswordSheet> createState() => _PasswordSheetState();
}

class _PasswordSheetState extends State<_PasswordSheet> {
  final _first = TextEditingController();
  final _second = TextEditingController();
  bool _hide1 = true;
  bool _hide2 = true;
  String? _error;

  @override
  void dispose() {
    _first.dispose();
    _second.dispose();
    super.dispose();
  }

  void _submit() {
    if (_first.text.length < 6) {
      setState(
        () => _error = 'Password is too short — use at least 6 characters.',
      );
      return;
    }
    if (_first.text != _second.text) {
      setState(() => _error = 'The two passwords don’t match.');
      return;
    }
    Navigator.of(context).pop([_first.text, _second.text]);
  }

  @override
  Widget build(BuildContext context) {
    return EmpSheetFrame(
      title: 'Change password',
      subtitle: 'Type the new password twice.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _first,
            obscureText: _hide1,
            style: empSans(14, color: empInk),
            decoration: empField('New password').copyWith(
              suffixIcon: IconButton(
                icon: Icon(
                  _hide1
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 19,
                  color: empMuted,
                ),
                onPressed: () => setState(() => _hide1 = !_hide1),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _second,
            obscureText: _hide2,
            style: empSans(14, color: empInk),
            decoration: empField('Repeat new password').copyWith(
              suffixIcon: IconButton(
                icon: Icon(
                  _hide2
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 19,
                  color: empMuted,
                ),
                onPressed: () => setState(() => _hide2 = !_hide2),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: empSans(12.5, weight: FontWeight.w600, color: empDanger),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _submit,
            style: empPrimaryButton(),
            child: const Text('Save password'),
          ),
        ],
      ),
    );
  }
}
