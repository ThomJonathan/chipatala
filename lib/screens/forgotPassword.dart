import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../auth-repository.dart';
import '../widgets/authScafold.dart';
import '../widgets/branding.dart';
import 'login.dart';

enum _ResetStep { email, code, newPassword }

/// Password reset via a 6-digit emailed code — no deep link involved.
/// Flow: request code -> verify code -> set new password -> back to login.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _authRepository = AuthRepository();

  _ResetStep _step = _ResetStep.email;
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _authRepository.sendPasswordResetCode(_emailController.text.trim());
      setState(() => _step = _ResetStep.code);
    } catch (e) {
      setState(() => _errorMessage = 'Could not send a code. Check the email and try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _verifyCode() async {
    if (_codeController.text.trim().length < 6) {
      setState(() => _errorMessage = 'Enter the 6-digit code from your email.');
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _authRepository.verifyPasswordResetCode(
        email: _emailController.text.trim(),
        code: _codeController.text.trim(),
      );
      setState(() => _step = _ResetStep.newPassword);
    } catch (e) {
      setState(() => _errorMessage = 'That code is wrong or has expired. Try resending it.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _resetPassword() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _authRepository.updatePassword(_passwordController.text);
      await _authRepository.signOut(); // drop the recovery session
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated. Sign in with your new password.')),
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    } catch (e) {
      setState(() => _errorMessage = 'Could not update your password. Try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: _title,
      subtitle: _subtitle,
      form: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_errorMessage != null) ...[
              ErrorBanner(message: _errorMessage!),
              const SizedBox(height: 16),
            ],
            ..._stepFields(),
          ],
        ),
      ),
      footerLink: SwitchAuthLink(
        question: _step == _ResetStep.email ? 'Remembered it?' : 'Stuck?',
        actionLabel: 'Back to sign in',
        onTap: () => Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        ),
      ),
    );
  }

  String get _title {
    switch (_step) {
      case _ResetStep.email:
        return 'Reset your password';
      case _ResetStep.code:
        return 'Check your email';
      case _ResetStep.newPassword:
        return 'Set a new password';
    }
  }

  String get _subtitle {
    switch (_step) {
      case _ResetStep.email:
        return "We'll email you a 8-digit code";
      case _ResetStep.code:
        return 'Enter the code sent to ${_emailController.text.trim()}';
      case _ResetStep.newPassword:
        return 'Your code is verified — choose a new password';
    }
  }

  List<Widget> _stepFields() {
    switch (_step) {
      case _ResetStep.email:
        return [
          AppTextField(
            label: 'Email',
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            validator: (value) =>
            (value == null || !value.contains('@')) ? 'Enter a valid email' : null,
          ),
          const SizedBox(height: 20),
          PrimaryButton(label: 'Send code', onPressed: _sendCode, isLoading: _isLoading),
        ];

      case _ResetStep.code:
        return [
          AppTextField(
            label: '6-digit code',
            controller: _codeController,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 14),
          PrimaryButton(label: 'Verify code', onPressed: _verifyCode, isLoading: _isLoading),
          const SizedBox(height: 14),
          Center(
            child: TextButton(
              onPressed: _isLoading ? null : _sendCode,
              child: Text(
                "Didn't get it? Resend code",
                style: GoogleFonts.ibmPlexSans(fontSize: 13, color: AppPalette.primary),
              ),
            ),
          ),
        ];

      case _ResetStep.newPassword:
        return [
          AppTextField(
            label: 'New password',
            controller: _passwordController,
            obscureText: _obscurePassword,
            validator: (value) =>
            (value == null || value.length < 6) ? 'At least 6 characters' : null,
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                color: AppPalette.inkMuted,
              ),
              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          const SizedBox(height: 14),
          AppTextField(
            label: 'Confirm new password',
            controller: _confirmController,
            obscureText: _obscurePassword,
            validator: (value) =>
            value != _passwordController.text ? 'Passwords do not match' : null,
          ),
          const SizedBox(height: 20),
          PrimaryButton(label: 'Update password', onPressed: _resetPassword, isLoading: _isLoading),
        ];
    }
  }
}