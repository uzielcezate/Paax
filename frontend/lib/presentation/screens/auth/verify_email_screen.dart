// lib/presentation/screens/auth/verify_email_screen.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/auth/auth_errors.dart';
import '../../../core/theme/app_colors.dart';
import '../../state/auth_controller.dart';
import '../../widgets/auth/auth_widgets.dart';

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key});
  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  String? _message;
  String? _error;
  bool _busy = false;
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    _cooldown = 45;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _resend() async {
    if (_busy || _cooldown > 0) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await context.read<AuthController>().resendVerification();
      if (mounted) {
        setState(() => _message = 'Verification email sent. Check your inbox.');
        _startCooldown();
      }
    } on AuthFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    await context.read<AuthController>().refreshVerificationStatus();
    if (mounted) {
      setState(() {
        _busy = false;
        if (context.read<AuthController>().state == AppAuthState.unverified) {
          _message = 'Still not verified yet. Open the link in your email.';
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = context.select<AuthController, String?>((c) => c.pendingVerificationEmail);
    return AuthScaffold(
      title: 'Verify email',
      showBack: false,
      actions: [
        TextButton(
          onPressed: () => context.read<AuthController>().logout(),
          child: const Text('Log out', style: TextStyle(color: AppColors.mutedText)),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.mark_email_unread_outlined,
              color: AppColors.textPrimary, size: 56),
          const SizedBox(height: 20),
          const AuthHeadline('Confirm your email',
              subtitle:
                  'We sent a verification link. Open it to activate your account, then come back.'),
          if (email != null)
            Text(email,
                style: const TextStyle(
                    color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          AuthInlineError(_error),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_message!,
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            ),
          PaaxPrimaryButton(label: 'I already verified', loading: _busy, onPressed: _refresh),
          const SizedBox(height: 12),
          Center(
            child: PaaxTextLink(
              label: _cooldown > 0 ? 'Resend in $_cooldown s' : 'Resend email',
              onPressed: _cooldown > 0 ? null : _resend,
            ),
          ),
        ],
      ),
    );
  }
}
