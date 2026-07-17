// lib/presentation/screens/auth/register_screen.dart
//
// 3-step registration wizard (Account -> Identity -> Location). Values persist
// across steps; each step validates before Continue; the Supabase account is
// created only on the final step. Paax dark UI, keyboard-safe.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/auth/auth_errors.dart';
import '../../../core/auth/demographics.dart';
import '../../../core/auth/validators.dart';
import '../../../core/theme/app_colors.dart';
import '../../state/auth_controller.dart';
import '../../widgets/auth/auth_widgets.dart';
import 'login_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _page = PageController();
  int _step = 0;

  // Step 1
  final _s1 = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  // Step 2
  final _s2 = GlobalKey<FormState>();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _username = TextEditingController();
  final _selfGender = TextEditingController();
  DateTime? _dob;
  String? _gender;

  // Step 3
  final _s3 = GlobalKey<FormState>();
  final _state = TextEditingController();
  final _city = TextEditingController();
  String? _country;

  // username availability
  Timer? _debounce;
  _Availability _avail = _Availability.idle;

  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_email, _password, _confirm, _first, _last, _username, _selfGender, _state, _city]) {
      c.dispose();
    }
    _page.dispose();
    super.dispose();
  }

  void _goto(int step) {
    setState(() => _step = step);
    _page.animateToPage(step,
        duration: const Duration(milliseconds: 220), curve: Curves.easeInOut);
  }

  void _onUsernameChanged(String value) {
    setState(() => _avail = _Availability.idle);
    _debounce?.cancel();
    final err = AuthValidators.username(value);
    if (err != null) return;
    _debounce = Timer(const Duration(milliseconds: 450), () async {
      setState(() => _avail = _Availability.checking);
      try {
        final ok = await context.read<AuthController>().isUsernameAvailable(value);
        if (mounted) setState(() => _avail = ok ? _Availability.available : _Availability.taken);
      } catch (_) {
        if (mounted) setState(() => _avail = _Availability.idle);
      }
    });
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 18, now.month, now.day),
      firstDate: DateTime(1900),
      lastDate: now,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: Colors.white,
            onPrimary: Colors.black,
            surface: AppColors.surface,
            onSurface: AppColors.textPrimary,
          ),
          dialogBackgroundColor: AppColors.background,
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _dob = picked);
  }

  bool _validateStep(int step) {
    switch (step) {
      case 0:
        return _s1.currentState!.validate();
      case 1:
        final okForm = _s2.currentState!.validate();
        final dobErr = AuthValidators.birthDate(_dob);
        if (dobErr != null) {
          setState(() => _error = dobErr);
          return false;
        }
        if (_gender == null) {
          setState(() => _error = 'Select your gender');
          return false;
        }
        if (_avail == _Availability.taken) {
          setState(() => _error = 'That username is taken');
          return false;
        }
        return okForm;
      case 2:
        return _s3.currentState!.validate();
    }
    return false;
  }

  Future<void> _next() async {
    setState(() => _error = null);
    if (!_validateStep(_step)) return;
    if (_step < 2) {
      _goto(_step + 1);
    } else {
      await _submit();
    }
  }

  String get _genderValue {
    if (_gender == GenderOptions.selfDescribe) return _selfGender.text.trim();
    return _gender ?? '';
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await context.read<AuthController>().register(
            email: _email.text,
            password: _password.text,
            firstName: _first.text,
            lastName: _last.text,
            username: _username.text,
            birthDateIso: _dob == null ? null : DateFormat('yyyy-MM-dd').format(_dob!),
            genderIdentity: _genderValue.isEmpty ? null : _genderValue,
            countryCode: _country,
            stateRegion: _state.text.trim().isEmpty ? null : _state.text.trim(),
            city: _city.text.trim().isEmpty ? null : _city.text.trim(),
          );
      if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
      // AuthGate routes to Verify Email.
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
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => _step == 0 ? Navigator.of(context).maybePop() : _goto(_step - 1),
        ),
        title: Text('Step ${_step + 1} of 3',
            style: const TextStyle(
                color: AppColors.textPrimary, fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _ProgressBar(step: _step),
            Expanded(
              child: PageView(
                controller: _page,
                physics: const NeverScrollableScrollPhysics(),
                children: [_stepAccount(), _stepIdentity(), _stepLocation()],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Column(
                children: [
                  AuthInlineError(_error),
                  PaaxPrimaryButton(
                    label: _step < 2 ? 'Continue' : 'Create account',
                    loading: _busy,
                    onPressed: _next,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _wrap(Widget child) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: child,
      );

  Widget _stepAccount() => _wrap(Form(
        key: _s1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthHeadline('Create your account', subtitle: 'Start with your login details.'),
            PaaxTextField(
              controller: _email,
              label: 'Email',
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              validator: AuthValidators.email,
            ),
            const SizedBox(height: 14),
            PaaxPasswordField(
              controller: _password,
              label: 'Password',
              textInputAction: TextInputAction.next,
              onChanged: (_) => setState(() {}),
              validator: AuthValidators.password,
            ),
            const SizedBox(height: 12),
            PasswordChecklist(password: _password.text),
            const SizedBox(height: 14),
            PaaxPasswordField(
              controller: _confirm,
              label: 'Confirm password',
              textInputAction: TextInputAction.done,
              validator: (v) => AuthValidators.confirmPassword(_password.text, v),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Text('Already have an account?',
                  style: TextStyle(color: AppColors.mutedText)),
              PaaxTextLink(
                  label: 'Log in',
                  onPressed: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const LoginScreen()))),
            ]),
          ],
        ),
      ));

  Widget _stepIdentity() => _wrap(Form(
        key: _s2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthHeadline('About you', subtitle: 'Tell us who you are.'),
            PaaxTextField(
                controller: _first,
                label: 'Given name(s)',
                textInputAction: TextInputAction.next,
                validator: (v) => AuthValidators.requiredText(v, 'first name')),
            const SizedBox(height: 14),
            PaaxTextField(
                controller: _last,
                label: 'Family name(s)',
                textInputAction: TextInputAction.next,
                validator: (v) => AuthValidators.requiredText(v, 'last name')),
            const SizedBox(height: 14),
            PaaxTextField(
              controller: _username,
              label: 'Username',
              textInputAction: TextInputAction.next,
              onChanged: _onUsernameChanged,
              validator: AuthValidators.username,
              suffix: _availabilitySuffix(),
            ),
            const SizedBox(height: 14),
            _dobField(),
            const SizedBox(height: 14),
            _genderField(),
          ],
        ),
      ));

  Widget _stepLocation() => _wrap(Form(
        key: _s3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthHeadline('Where are you?',
                subtitle: 'Approximate location only — no GPS, no tracking.'),
            _countryField(),
            const SizedBox(height: 14),
            PaaxTextField(
                controller: _state,
                label: 'State / region',
                textInputAction: TextInputAction.next,
                validator: (v) => AuthValidators.requiredText(v, 'state or region')),
            const SizedBox(height: 14),
            PaaxTextField(
                controller: _city,
                label: 'City (optional)',
                textInputAction: TextInputAction.done),
          ],
        ),
      ));

  Widget? _availabilitySuffix() {
    switch (_avail) {
      case _Availability.checking:
        return const Padding(
            padding: EdgeInsets.all(14),
            child: SizedBox(
                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)));
      case _Availability.available:
        return const Icon(Icons.check_circle, color: Colors.greenAccent);
      case _Availability.taken:
        return const Icon(Icons.cancel, color: AppColors.primaryEnd);
      case _Availability.idle:
        return null;
    }
  }

  Widget _dobField() => InkWell(
        onTap: _pickDob,
        borderRadius: BorderRadius.circular(14),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: 'Date of birth',
            labelStyle: const TextStyle(color: AppColors.mutedText),
            filled: true,
            fillColor: AppColors.surface,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.08))),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(
            _dob == null ? 'Select a date' : DateFormat('yyyy-MM-dd').format(_dob!),
            style: TextStyle(
                color: _dob == null ? AppColors.mutedText : AppColors.textPrimary),
          ),
        ),
      );

  Widget _genderField() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            value: _gender,
            dropdownColor: AppColors.surface,
            iconEnabledColor: AppColors.mutedText,
            style: const TextStyle(color: AppColors.textPrimary),
            decoration: InputDecoration(
              labelText: 'Gender',
              labelStyle: const TextStyle(color: AppColors.mutedText),
              filled: true,
              fillColor: AppColors.surface,
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.08))),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
            items: [
              for (final g in GenderOptions.labels)
                DropdownMenuItem(value: g, child: Text(g)),
            ],
            onChanged: (v) => setState(() => _gender = v),
          ),
          if (_gender == GenderOptions.selfDescribe) ...[
            const SizedBox(height: 12),
            PaaxTextField(
                controller: _selfGender, label: 'Describe (optional)', maxLength: 60),
          ],
        ],
      );

  Widget _countryField() => DropdownButtonFormField<String>(
        value: _country,
        isExpanded: true,
        dropdownColor: AppColors.surface,
        iconEnabledColor: AppColors.mutedText,
        style: const TextStyle(color: AppColors.textPrimary),
        decoration: InputDecoration(
          labelText: 'Country',
          labelStyle: const TextStyle(color: AppColors.mutedText),
          filled: true,
          fillColor: AppColors.surface,
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.08))),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        ),
        items: [
          for (final c in Countries.all)
            DropdownMenuItem(value: c.code, child: Text(c.name)),
        ],
        validator: (v) => (v == null) ? 'Select your country' : null,
        onChanged: (v) => setState(() => _country = v),
      );
}

enum _Availability { idle, checking, available, taken }

class _ProgressBar extends StatelessWidget {
  final int step;
  const _ProgressBar({required this.step});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
      child: Row(
        children: [
          for (int i = 0; i < 3; i++) ...[
            Expanded(
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  color: i <= step ? Colors.white : Colors.white.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (i < 2) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}
