// lib/presentation/screens/auth/login_screen.dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/auth/auth_errors.dart';
import '../../../core/auth/validators.dart';
import '../../../core/theme/app_colors.dart';
import '../../state/auth_controller.dart';
import '../../widgets/auth/auth_widgets.dart';
import 'auth_gate.dart';
import 'forgot_password_screen.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final auth = context.read<AuthController>();
    try {
      await auth.login(email: _email.text, password: _password.text);
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      // The AuthGate re-routes based on the new state.
    } on AuthFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Please try again');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Log in',
      child: Form(
        key: _formKey,
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AuthHeadline('Welcome back', subtitle: 'Log in to continue.'),
              AuthInlineError(_error),
              PaaxTextField(
                controller: _email,
                label: 'Email',
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.username, AutofillHints.email],
                validator: AuthValidators.email,
              ),
              const SizedBox(height: 14),
              PaaxPasswordField(
                controller: _password,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                validator: (v) => (v == null || v.isEmpty) ? 'Enter your password' : null,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: PaaxTextLink(
                  label: 'Forgot password?',
                  onPressed: () =>
                      AuthRoutes.push(context, const ForgotPasswordScreen()),
                ),
              ),
              const SizedBox(height: 8),
              PaaxPrimaryButton(label: 'Log in', loading: _busy, onPressed: _submit),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Don't have an account?",
                      style: TextStyle(color: AppColors.mutedText)),
                  PaaxTextLink(
                    label: 'Sign up',
                    onPressed: () {
                      Navigator.of(context).pushReplacement(
                          MaterialPageRoute(builder: (_) => const RegisterScreen()));
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
