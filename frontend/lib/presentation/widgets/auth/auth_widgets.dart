// lib/presentation/widgets/auth/auth_widgets.dart
//
// Shared, dark-styled, accessible auth UI primitives (Paax visual language).
// Keyboard-safe, high-contrast white primary actions, rounded dark inputs.

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Dark scaffold with a keyboard-safe scrolling body and consistent back button.
class AuthScaffold extends StatelessWidget {
  final String? title;
  final Widget child;
  final bool showBack;
  final List<Widget>? actions;

  const AuthScaffold({
    super.key,
    this.title,
    required this.child,
    this.showBack = true,
    this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        leading: showBack && Navigator.of(context).canPop()
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
                onPressed: () => Navigator.of(context).maybePop(),
                tooltip: 'Back',
              )
            : null,
        automaticallyImplyLeading: showBack,
        title: title == null
            ? null
            : Text(title!,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
        actions: actions,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            physics: const ClampingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 40),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

class AuthHeadline extends StatelessWidget {
  final String title;
  final String? subtitle;
  const AuthHeadline(this.title, {super.key, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 26,
                fontWeight: FontWeight.w700)),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(subtitle!,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 14, height: 1.4)),
        ],
        const SizedBox(height: 24),
      ],
    );
  }
}

InputDecoration _decoration(String label, {Widget? suffix}) {
  const radius = BorderRadius.all(Radius.circular(14));
  OutlineInputBorder border(Color c) =>
      OutlineInputBorder(borderRadius: radius, borderSide: BorderSide(color: c, width: 1));
  return InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: AppColors.mutedText),
    floatingLabelStyle: const TextStyle(color: AppColors.textPrimary),
    filled: true,
    fillColor: AppColors.surface,
    suffixIcon: suffix,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    enabledBorder: border(Colors.white.withOpacity(0.08)),
    focusedBorder: border(Colors.white.withOpacity(0.55)),
    errorBorder: border(AppColors.primaryEnd),
    focusedErrorBorder: border(AppColors.primaryEnd),
    errorStyle: const TextStyle(color: AppColors.primaryEnd),
  );
}

class PaaxTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final void Function(String)? onChanged;
  final Widget? suffix;
  final bool enabled;
  final int? maxLength;

  const PaaxTextField({
    super.key,
    required this.controller,
    required this.label,
    this.validator,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.onChanged,
    this.suffix,
    this.enabled = true,
    this.maxLength,
  });

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      validator: validator,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      autofillHints: autofillHints,
      onChanged: onChanged,
      enabled: enabled,
      maxLength: maxLength,
      style: const TextStyle(color: AppColors.textPrimary),
      cursorColor: AppColors.textPrimary,
      decoration: _decoration(label, suffix: suffix).copyWith(counterText: ''),
    );
  }
}

/// Password field with an independent, accessible show/hide toggle.
class PaaxPasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String label;
  final String? Function(String?)? validator;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final void Function(String)? onChanged;

  const PaaxPasswordField({
    super.key,
    required this.controller,
    this.label = 'Password',
    this.validator,
    this.textInputAction,
    this.autofillHints,
    this.onChanged,
  });

  @override
  State<PaaxPasswordField> createState() => _PaaxPasswordFieldState();
}

class _PaaxPasswordFieldState extends State<PaaxPasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      validator: widget.validator,
      obscureText: _obscure,
      textInputAction: widget.textInputAction,
      autofillHints: widget.autofillHints,
      onChanged: widget.onChanged,
      style: const TextStyle(color: AppColors.textPrimary),
      cursorColor: AppColors.textPrimary,
      decoration: _decoration(
        widget.label,
        suffix: Semantics(
          button: true,
          label: _obscure ? 'Show password' : 'Hide password',
          child: IconButton(
            icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
                color: AppColors.mutedText),
            onPressed: () => setState(() => _obscure = !_obscure),
            tooltip: _obscure ? 'Show password' : 'Hide password',
          ),
        ),
      ),
    );
  }
}

class PaaxPrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool loading;
  const PaaxPrimaryButton(
      {super.key, required this.label, this.onPressed, this.loading = false});

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null || loading;
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: disabled ? null : onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          disabledBackgroundColor: Colors.white24,
          foregroundColor: Colors.black,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
              )
            : Text(label,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
    );
  }
}

class PaaxTextLink extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const PaaxTextLink({super.key, required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      child: Text(label,
          style: const TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
    );
  }
}

/// Live password-policy checklist.
class PasswordChecklist extends StatelessWidget {
  final String password;
  const PasswordChecklist({super.key, required this.password});

  @override
  Widget build(BuildContext context) {
    Widget row(bool ok, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Icon(ok ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 16, color: ok ? Colors.greenAccent : AppColors.mutedText),
            const SizedBox(width: 8),
            Text(text,
                style: TextStyle(
                    color: ok ? AppColors.textSecondary : AppColors.mutedText, fontSize: 12)),
          ]),
        );
    final p = password;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row(p.length >= 8, 'At least 8 characters'),
        row(RegExp(r'[A-Z]').hasMatch(p), 'One uppercase letter'),
        row(RegExp(r'[a-z]').hasMatch(p), 'One lowercase letter'),
        row(RegExp(r'\d').hasMatch(p), 'One number'),
        row(RegExp(r'[^A-Za-z0-9]').hasMatch(p), 'One special character'),
      ],
    );
  }
}

class AuthInlineError extends StatelessWidget {
  final String? message;
  const AuthInlineError(this.message, {super.key});
  @override
  Widget build(BuildContext context) {
    if (message == null || message!.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        const Icon(Icons.error_outline, color: AppColors.primaryEnd, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message!,
              style: const TextStyle(color: AppColors.primaryEnd, fontSize: 13)),
        ),
      ]),
    );
  }
}
