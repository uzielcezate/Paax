// lib/presentation/screens/profile/edit_profile_screen.dart
//
// Edits the whitelisted profile fields (Phase 3.2.2). Prefills from
// AuthController.profile, validates + debounces the username availability check,
// writes via ProfileController.updateProfile, then re-fetches through
// AuthController.bootstrap() on success.
//
// Provides its own ProfileController inline so main.dart needs no wiring.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/auth/demographics.dart';
import '../../../core/auth/validators.dart';
import '../../../core/theme/app_colors.dart';
import '../../state/auth_controller.dart';
import '../../state/profile_controller.dart';
import '../../widgets/auth/auth_widgets.dart';

class EditProfileScreen extends StatelessWidget {
  const EditProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ProfileController>(
      create: (_) => ProfileController(),
      child: const _EditProfileForm(),
    );
  }
}

class _EditProfileForm extends StatefulWidget {
  const _EditProfileForm();

  @override
  State<_EditProfileForm> createState() => _EditProfileFormState();
}

enum _UsernameStatus { idle, checking, available, taken, invalid }

class _EditProfileFormState extends State<_EditProfileForm> {
  final _formKey = GlobalKey<FormState>();
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _username = TextEditingController();
  final _displayName = TextEditingController();
  final _state = TextEditingController();
  final _city = TextEditingController();

  DateTime? _dob;
  String? _gender;
  String? _country;
  String _originalUsername = '';

  Timer? _debounce;
  _UsernameStatus _usernameStatus = _UsernameStatus.idle;

  @override
  void initState() {
    super.initState();
    final p = context.read<AuthController>().profile;
    if (p != null) {
      _first.text = p.firstName ?? '';
      _last.text = p.lastName ?? '';
      _username.text = p.username;
      _originalUsername = AuthValidators.normalizeUsername(p.username);
      _displayName.text = p.displayName ?? '';
      _state.text = p.stateRegion ?? '';
      _city.text = p.city ?? '';
      _dob = p.birthDate;
      _country = p.countryCode;
      _gender =
          (p.genderIdentity != null && GenderOptions.labels.contains(p.genderIdentity))
              ? p.genderIdentity
              : null;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final c in [_first, _last, _username, _displayName, _state, _city]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onUsernameChanged(String value) {
    _debounce?.cancel();
    final normalized = AuthValidators.normalizeUsername(value);
    // Unchanged username is trivially "available".
    if (normalized == _originalUsername) {
      setState(() => _usernameStatus = _UsernameStatus.idle);
      return;
    }
    if (AuthValidators.username(value) != null) {
      setState(() => _usernameStatus = _UsernameStatus.invalid);
      return;
    }
    setState(() => _usernameStatus = _UsernameStatus.checking);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final controller = context.read<ProfileController>();
      final ok = await controller.isUsernameAvailable(normalized);
      if (!mounted) return;
      // Ignore stale results if the field changed again meanwhile.
      if (AuthValidators.normalizeUsername(_username.text) != normalized) return;
      setState(() => _usernameStatus =
          ok ? _UsernameStatus.available : _UsernameStatus.taken);
    });
  }

  Widget? _usernameSuffix() {
    switch (_usernameStatus) {
      case _UsernameStatus.checking:
        return const Padding(
          padding: EdgeInsets.all(14),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.mutedText),
          ),
        );
      case _UsernameStatus.available:
        return const Icon(Icons.check_circle, color: Colors.greenAccent);
      case _UsernameStatus.taken:
      case _UsernameStatus.invalid:
        return const Icon(Icons.error_outline, color: AppColors.primaryEnd);
      case _UsernameStatus.idle:
        return null;
    }
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

  Future<void> _save() async {
    final controller = context.read<ProfileController>();
    if (controller.isSubmitting) return;
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;
    final dobErr = AuthValidators.birthDate(_dob);
    final countryErr = _country == null ? 'Select your country' : null;
    if (dobErr != null || countryErr != null) {
      _showSnack(dobErr ?? countryErr!);
      return;
    }
    if (_usernameStatus == _UsernameStatus.taken) {
      _showSnack('That username is taken.');
      return;
    }

    final displayName = _displayName.text.trim().isNotEmpty
        ? _displayName.text.trim()
        : AuthValidators.buildDisplayName(_first.text, _last.text);

    final fields = <String, dynamic>{
      'username': AuthValidators.normalizeUsername(_username.text),
      'display_name': displayName,
      'first_name': _first.text.trim(),
      'last_name': _last.text.trim(),
      'birth_date': DateFormat('yyyy-MM-dd').format(_dob!),
      if (_gender != null) 'gender_identity': _gender,
      'country_code': _country,
      if (_state.text.trim().isNotEmpty) 'state_region': _state.text.trim(),
      if (_city.text.trim().isNotEmpty) 'city': _city.text.trim(),
    };

    final ok = await controller.updateProfile(fields);
    if (!mounted) return;
    if (ok) {
      await context.read<AuthController>().bootstrap();
      if (!mounted) return;
      Navigator.of(context).pop();
    }
    // On failure the inline error (watched below) is shown; keep the form open.
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.surface),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<ProfileController>();
    return AuthScaffold(
      title: 'Edit profile',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthHeadline('Your details',
                subtitle: 'Update your public profile information.'),
            AuthInlineError(controller.error),
            PaaxTextField(
              controller: _username,
              label: 'Username',
              validator: (v) {
                final base = AuthValidators.username(v);
                if (base != null) return base;
                if (_usernameStatus == _UsernameStatus.taken) {
                  return 'That username is taken.';
                }
                return null;
              },
              onChanged: _onUsernameChanged,
              suffix: _usernameSuffix(),
            ),
            const SizedBox(height: 14),
            PaaxTextField(
                controller: _displayName,
                label: 'Display name',
                validator: (v) => AuthValidators.requiredText(v, 'display name')),
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
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
                child: Text(
                    _dob == null ? 'Select a date' : DateFormat('yyyy-MM-dd').format(_dob!),
                    style: TextStyle(
                        color: _dob == null
                            ? AppColors.mutedText
                            : AppColors.textPrimary)),
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
            const SizedBox(height: 24),
            PaaxPrimaryButton(
                label: 'Save changes',
                loading: controller.isSubmitting,
                onPressed: _save),
          ],
        ),
      ),
    );
  }
}
