import 'package:flutter/material.dart';


import '../auth-repository.dart';
import '../widgets/authScafold.dart';
import '../widgets/branding.dart';
import 'login.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _authRepository = AuthRepository();

  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  // Letters, numbers, underscores only — matches the fallback the trigger
  // generates server-side (email-prefix + id suffix), so anything a user
  // types here stays consistent with that format.
  static final _usernamePattern = RegExp(r'^[a-zA-Z0-9_]{3,20}$');

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await _authRepository.signUp(
        fullName: _nameController.text.trim(),
        username: _usernameController.text.trim(),
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Account created. An admin will review and approve your access.')),
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    } catch (e) {
      setState(() => _errorMessage = 'Could not create your account. Try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Create your account',
      subtitle: 'Set up staff access for Tumaini Investments',
      form: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_errorMessage != null) ...[
              ErrorBanner(message: _errorMessage!),
              const SizedBox(height: 16),
            ],
            AppTextField(
              label: 'Full name',
              controller: _nameController,
              validator: (value) =>
              (value == null || value.trim().isEmpty) ? 'Enter your name' : null,
            ),
            const SizedBox(height: 14),
            AppTextField(
              label: 'Username',
              controller: _usernameController,
              validator: (value) {
                final v = value?.trim() ?? '';
                if (v.isEmpty) return 'Choose a username';
                if (!_usernamePattern.hasMatch(v)) {
                  return '3-20 characters: letters, numbers, underscores only';
                }
                return null;
              },
            ),
            const SizedBox(height: 14),
            AppTextField(
              label: 'Email',
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              validator: (value) =>
              (value == null || !value.contains('@')) ? 'Enter a valid email' : null,
            ),
            const SizedBox(height: 14),
            AppTextField(
              label: 'Password',
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
              label: 'Confirm password',
              controller: _confirmController,
              obscureText: _obscurePassword,
              validator: (value) =>
              value != _passwordController.text ? 'Passwords do not match' : null,
            ),
            const SizedBox(height: 20),
            PrimaryButton(label: 'Create account', onPressed: _submit, isLoading: _isLoading),
          ],
        ),
      ),
      footerLink: SwitchAuthLink(
        question: 'Already have an account?',
        actionLabel: 'Sign in',
        onTap: () => Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
        ),
      ),
    );
  }
}