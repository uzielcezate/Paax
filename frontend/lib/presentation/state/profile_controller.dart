// lib/presentation/state/profile_controller.dart
//
// Edits the authenticated user's own profile (Phase 3.2.2). Owns the
// submit/avatar workflow and error surface for the Edit-Profile and Profile
// screens. Never throws to the UI — failures land in [error] and return false.
//
// This controller does NOT refresh AuthController; callers should invoke
// `context.read<AuthController>().bootstrap()` after a successful change to
// re-fetch and redisplay the profile.

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/validators.dart';
import '../../core/media/avatar_service.dart';
import '../../data/repositories/profile_repository.dart';

class ProfileController extends ChangeNotifier {
  final ProfileRepository _profiles;
  final AvatarService _avatars;
  final SupabaseClient _client;

  ProfileController({
    ProfileRepository? profileRepository,
    AvatarService? avatarService,
    SupabaseClient? client,
  })  : _profiles = profileRepository ?? ProfileRepository(),
        _avatars = avatarService ?? AvatarService(),
        _client = client ?? Supabase.instance.client;

  bool _isSubmitting = false;
  String? _error;

  bool get isSubmitting => _isSubmitting;
  String? get error => _error;

  /// Updates the whitelisted profile fields. Returns true on success.
  /// Maps a username-unique violation (Postgres 23505) to a friendly message.
  Future<bool> updateProfile(Map<String, dynamic> fields) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) {
      _fail('You are not signed in.');
      return false;
    }
    _begin();
    try {
      await _profiles.updateOwn(uid, fields);
      _finish();
      return true;
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        _fail('That username is taken.');
      } else {
        _fail('Could not save your changes. Please try again.');
      }
      return false;
    } catch (_) {
      _fail('Could not save your changes. Please try again.');
      return false;
    }
  }

  /// Debounced availability check (normalizes input). Never throws — returns
  /// true on network failure so the user is not blocked by a transient error.
  Future<bool> isUsernameAvailable(String username) async {
    try {
      return await _profiles
          .isUsernameAvailable(AuthValidators.normalizeUsername(username));
    } catch (_) {
      return true;
    }
  }

  /// Picks + uploads a new avatar, then persists `avatar_url`. Returns true on
  /// success, false on cancel or failure (with [error] set on real failures).
  Future<bool> changeAvatar() async {
    _begin();
    try {
      final url = await _avatars.pickAndUpload();
      if (url == null) {
        _finish(); // user cancelled — not an error
        return false;
      }
      final ok = await _persistAvatar(url);
      return ok;
    } on AvatarException catch (e) {
      _fail(e.message);
      return false;
    } catch (_) {
      _fail('Could not update your photo. Please try again.');
      return false;
    }
  }

  Future<bool> _persistAvatar(String url) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null || uid.isEmpty) {
      _fail('You are not signed in.');
      return false;
    }
    try {
      await _profiles.updateOwn(uid, {'avatar_url': url});
      _finish();
      return true;
    } catch (_) {
      _fail('Your photo uploaded but could not be saved. Please try again.');
      return false;
    }
  }

  void _begin() {
    _isSubmitting = true;
    _error = null;
    notifyListeners();
  }

  void _finish() {
    _isSubmitting = false;
    _error = null;
    notifyListeners();
  }

  void _fail(String message) {
    _isSubmitting = false;
    _error = message;
    notifyListeners();
  }
}
