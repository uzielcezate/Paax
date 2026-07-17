// lib/presentation/screens/auth/complete_profile_screen.dart
//
// Fallback for a verified user whose profile is incomplete (e.g. the pending
// registration payload was lost/expired, or a prior update failed). Collects the
// required fields and writes RLS-safe columns only.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/auth/auth_errors.dart';
import '../../../core/auth/demographics.dart';
import '../../../core/auth/validators.dart';
import '../../../core/theme/app_colors.dart';
import '../../state/auth_controller.dart';
import '../../widgets/auth/auth_widgets.dart';

class CompleteProfileScreen extends StatefulWidget {
  const CompleteProfileScreen({super.key});
  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _username = TextEditingController();
  final _state = TextEditingController();
  final _city = TextEditingController();
  DateTime? _dob;
  String? _gender;
  String? _country;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final p = context.read<AuthController>().profile;
    if (p != null) {
      _first.text = p.firstName ?? '';
      _last.text = p.lastName ?? '';
      // Only pre-fill username if it isn't the auto-generated fallback.
      if (!p.username.startsWith('user_')) _username.text = p.username;
      _state.text = p.stateRegion ?? '';
      _city.text = p.city ?? '';
      _dob = p.birthDate;
      _country = p.countryCode;
      _gender = (p.genderIdentity != null && GenderOptions.labels.contains(p.genderIdentity))
          ? p.genderIdentity
          : null;
    }
  }

  @override
  void dispose() {
    for (final c in [_first, _last, _username, _state, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDob() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dob ?? DateTime(now.year - 18),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (picked != null) setState(() => _dob = picked);
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _error = null);
    if (!_formKey.currentState!.validate()) return;
    final dobErr = AuthValidators.birthDate(_dob);
    final countryErr = _country == null ? 'Select your country' : null;
    if (dobErr != null || countryErr != null) {
      setState(() => _error = dobErr ?? countryErr);
      return;
    }
    setState(() => _busy = true);
    final displayName = AuthValidators.buildDisplayName(_first.text, _last.text);
    try {
      await context.read<AuthController>().completeProfile({
        'username': AuthValidators.normalizeUsername(_username.text),
        'display_name': displayName,
        'first_name': _first.text.trim(),
        'last_name': _last.text.trim(),
        'birth_date': DateFormat('yyyy-MM-dd').format(_dob!),
        if (_gender != null) 'gender_identity': _gender,
        'country_code': _country,
        if (_state.text.trim().isNotEmpty) 'state_region': _state.text.trim(),
        if (_city.text.trim().isNotEmpty) 'city': _city.text.trim(),
      });
      // AuthGate routes onward (onboarding/home).
    } on AuthFailure catch (f) {
      if (mounted) setState(() => _error = f.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Complete profile',
      showBack: false,
      actions: [
        TextButton(
          onPressed: () => context.read<AuthController>().logout(),
          child: const Text('Log out', style: TextStyle(color: AppColors.mutedText)),
        ),
      ],
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthHeadline('Finish setting up',
                subtitle: 'A few details to complete your Paax profile.'),
            AuthInlineError(_error),
            PaaxTextField(
                controller: _username,
                label: 'Username',
                validator: AuthValidators.username),
            const SizedBox(height: 14),
            PaaxTextField(
                controller: _first,
                label: 'Given name(s)',
                validator: (v) => AuthValidators.requiredText(v, 'first name')),
            const SizedBox(height: 14),
            PaaxTextField(
                controller: _last,
                label: 'Family name(s)',
                validator: (v) => AuthValidators.requiredText(v, 'last name')),
            const SizedBox(height: 14),
            InkWell(
              onTap: _pickDob,
              borderRadius: BorderRadius.circular(14),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Date of birth',
                  labelStyle: const TextStyle(color: AppColors.mutedText),
                  filled: true,
                  fillColor: AppColors.surface,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(_dob == null ? 'Select a date' : DateFormat('yyyy-MM-dd').format(_dob!),
                    style: TextStyle(
                        color: _dob == null ? AppColors.mutedText : AppColors.textPrimary)),
              ),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _gender,
              dropdownColor: AppColors.surface,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Gender (optional)',
                labelStyle: const TextStyle(color: AppColors.mutedText),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
              items: [
                for (final g in GenderOptions.labels)
                  DropdownMenuItem(value: g, child: Text(g)),
              ],
              onChanged: (v) => setState(() => _gender = v),
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _country,
              isExpanded: true,
              dropdownColor: AppColors.surface,
              style: const TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: 'Country',
                labelStyle: const TextStyle(color: AppColors.mutedText),
                filled: true,
                fillColor: AppColors.surface,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
              items: [
                for (final c in Countries.all)
                  DropdownMenuItem(value: c.code, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _country = v),
            ),
            const SizedBox(height: 14),
            PaaxTextField(controller: _state, label: 'State / region'),
            const SizedBox(height: 14),
            PaaxTextField(controller: _city, label: 'City (optional)'),
            const SizedBox(height: 20),
            PaaxPrimaryButton(label: 'Save and continue', loading: _busy, onPressed: _submit),
          ],
        ),
      ),
    );
  }
}
