// lib/presentation/screens/auth/forgot_password_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/auth/auth_errors.dart';
import '../../../core/auth/validators.dart';
import '../../../core/theme/app_colors.dart';
import '../../state/auth_controller.dart';
import '../../widgets/auth/auth_widgets.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _sent = false;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    super.dispose();
  }

  void _startCooldown() {
    _cooldown = 30;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _submit() async {
    if (_busy || _cooldown > 0) return;
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await context.read<AuthController>().sendPasswordReset(_email.text);
      if (mounted) {
        setState(() => _sent = true);
        _startCooldown();
      }
    } on AuthFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Reset password',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthHeadline('Forgot your password?',
                subtitle:
                    "Enter your email and we'll send a recovery link if an account exists."),
            AuthInlineError(_error),
            if (_sent)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'If that email is registered, a recovery link is on its way. '
                  'Check your inbox and spam.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                ),
              ),
            PaaxTextField(
              controller: _email,
              label: 'Email',
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.email],
              validator: AuthValidators.email,
            ),
            const SizedBox(height: 16),
            PaaxPrimaryButton(
              label: _cooldown > 0 ? 'Resend in $_cooldown s' : 'Send recovery link',
              loading: _busy,
              onPressed: _cooldown > 0 ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}
