// lib/presentation/screens/auth/reset_password_screen.dart
//
// Shown only from a valid recovery session (AppAuthState.recovery), triggered by
// the paax://auth/reset-password deep link.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/auth/auth_errors.dart';
import '../../../core/auth/validators.dart';
import '../../../core/theme/app_colors.dart';
import '../../state/auth_controller.dart';
import '../../widgets/auth/auth_widgets.dart';

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key});
  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await context.read<AuthController>().updatePassword(_password.text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password updated. You are signed in.')),
        );
        // AuthGate re-routes out of recovery automatically.
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
      title: 'New password',
      showBack: false,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthHeadline('Set a new password',
                subtitle: 'Choose a strong password to secure your account.'),
            AuthInlineError(_error),
            PaaxPasswordField(
              controller: _password,
              label: 'New password',
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              validator: AuthValidators.password,
            ),
            const SizedBox(height: 12),
            PasswordChecklist(password: _password.text),
            const SizedBox(height: 14),
            PaaxPasswordField(
              controller: _confirm,
              label: 'Confirm new password',
              textInputAction: TextInputAction.done,
              validator: (v) => AuthValidators.confirmPassword(_password.text, v),
            ),
            const SizedBox(height: 20),
            PaaxPrimaryButton(label: 'Update password', loading: _busy, onPressed: _submit),
            const SizedBox(height: 8),
            Center(
              child: PaaxTextLink(
                label: 'Request a new recovery email',
                onPressed: () => context.read<AuthController>().logout(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
