// lib/data/local/onboarding_selection_store.dart
//
// Persists the in-progress artist selection during Phase 3.2 onboarding so an
// app restart mid-flow restores what the user had already picked. Versioned,
// corrupt-safe JSON via SharedPreferences. Contains no sensitive data.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/onboarding_artist.dart';

class OnboardingSelectionStore {
  static const int schemaVersion = 1;
  static const String _key = 'paax_onboarding_selection_v1';

  final Future<SharedPreferences> _prefs;
  OnboardingSelectionStore({Future<SharedPreferences>? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance();

  /// Persists the current selection (cheap; called on every toggle).
  Future<void> save(List<OnboardingArtist> artists) async {
    final p = await _prefs;
    final payload = jsonEncode({
      'schema_version': schemaVersion,
      'artists': artists.map((a) => a.toJson()).toList(),
    });
    await p.setString(_key, payload);
  }

  /// Loads a valid selection; auto-clears corrupt/version-mismatched payloads.
  Future<List<OnboardingArtist>> load() async {
    final p = await _prefs;
    final raw = p.getString(_key);
    if (raw == null) return const [];
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if ((map['schema_version'] as num?)?.toInt() != schemaVersion) {
        await clear();
        return const [];
      }
      final list = (map['artists'] as List?) ?? const [];
      final result = <OnboardingArtist>[];
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          final artist = OnboardingArtist.fromJson(item);
          if (artist != null && !result.contains(artist)) {
            result.add(artist);
          }
        }
      }
      return result;
    } catch (_) {
      await clear();
      return const [];
    }
  }

  Future<void> clear() async {
    final p = await _prefs;
    await p.remove(_key);
  }
}
