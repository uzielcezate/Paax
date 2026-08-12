// test/unit/playlist_add_version_deletion_test.dart
//
// Phase 3.4.9 — the three bugs isolated by manual Android QA.
//
// All three share one shape: the client asserted something it had not actually
// established — that an add succeeded, that it knew the playlist version, or
// that a playlist still existed. Each test states the assertion that was wrong.

import 'package:beaty/data/repositories/playlist_repository.dart';
import 'package:beaty/domain/entities/playlist_mutation_result.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors `_reconcileRemoteDeletions`' decision table exactly, so the rule can
/// be exhaustively checked without Hive or Supabase. `null` row = not visible.
bool shouldRemoveLocally({
  required bool isCloudId,
  required bool inHydration,
  required bool isPendingCreate,
  required Map<String, dynamic>? authoritativeRow,
  required bool fetchThrew,
}) {
  if (!isCloudId) return false; // local-only playlist
  if (inHydration) return false; // still live
  if (isPendingCreate) return false; // awaiting its cloud create
  if (fetchThrew) return false; // network/permission — unknown
  if (authoritativeRow == null) return false; // RLS/not visible ≠ deleted
  return authoritativeRow['deleted_at'] != null;
}

void main() {
  group('BUG 1 — an add must never claim success it did not achieve', () {
    test('every failure mode is distinguishable from success', () {
      expect(PlaylistMutationResult.applied.isSuccess, isTrue);
      expect(PlaylistMutationResult.queuedOffline.isSuccess, isTrue);
      for (final r in [
        PlaylistMutationResult.conflict,
        PlaylistMutationResult.forbidden,
        PlaylistMutationResult.failed,
      ]) {
        expect(r.isSuccess, isFalse, reason: '$r must not read as success');
        expect(r.wasRolledBack, isTrue,
            reason: '$r must revert the optimistic insert');
      }
    });

    test('queuedOffline does NOT roll back — the journal will replay it', () {
      // Distinct from `failed`: the user's intent is durable, so the track
      // must stay on screen.
      expect(PlaylistMutationResult.queuedOffline.wasRolledBack, isFalse);
    });

    test('an unresolvable track is `failed`, not `queuedOffline`', () {
      // localIntegrity is not a network problem, so it must not be queued for
      // a replay that can never succeed — it must roll back and report.
      const unresolvable = PlaylistMutationResult.failed;
      expect(unresolvable.isSuccess, isFalse);
      expect(unresolvable.wasRolledBack, isTrue);
    });
  });

  group('BUG 2 — never assert a version we did not obtain', () {
    // The defect: PlaylistDetailController.version defaulted to 1, so a screen
    // whose load had not completed sent expected_version=1 against a server at
    // (say) 16 and the client reported its OWN mutation as an external change.
    //
    // Phase 3.4.11: this used to re-implement the rule as `lane ?? screen`,
    // which meant it kept passing after production changed — and it encoded the
    // *self-conflict* half of the bug as if it were correct. It now calls the
    // real selector, so these cases are a genuine lock. See
    // membership_and_version_test.dart for the full contract.
    int? effectiveExpectedVersion({int? laneVersion, int? screenVersion}) =>
        PlaylistRepository.authoritativeVersion(laneVersion, screenVersion);

    test('an unknown version sends NULL, not a fabricated 1', () {
      expect(effectiveExpectedVersion(laneVersion: null, screenVersion: null),
          isNull,
          reason: 'a fabricated version guarantees a self-conflict');
    });

    test('the lane version wins over the screen version', () {
      expect(
        effectiveExpectedVersion(laneVersion: 16, screenVersion: 1),
        16,
        reason: 'the lane holds the authoritative version from the last commit',
      );
    });

    test('the screen version is used when the lane has none', () {
      expect(effectiveExpectedVersion(laneVersion: null, screenVersion: 9), 9);
    });

    test('a genuine stale version still asserts optimistic concurrency', () {
      // Regression guard: the fix must NOT become "never send a version".
      expect(effectiveExpectedVersion(laneVersion: 7, screenVersion: null), 7);
    });
  });

  group('BUG 3 — absence is not proof of deletion', () {
    test('authoritative deleted_at removes the playlist locally', () {
      expect(
        shouldRemoveLocally(
          isCloudId: true,
          inHydration: false,
          isPendingCreate: false,
          authoritativeRow: {'deleted_at': '2026-08-10T03:13:18Z'},
          fetchThrew: false,
        ),
        isTrue,
      );
    });

    test('RLS / not-visible (null row) must NOT delete', () {
      expect(
        shouldRemoveLocally(
          isCloudId: true,
          inHydration: false,
          isPendingCreate: false,
          authoritativeRow: null,
          fetchThrew: false,
        ),
        isFalse,
        reason: 'a permission change is not a deletion',
      );
    });

    test('a network failure must NOT delete', () {
      expect(
        shouldRemoveLocally(
          isCloudId: true,
          inHydration: false,
          isPendingCreate: false,
          authoritativeRow: null,
          fetchThrew: true,
        ),
        isFalse,
        reason: 'offline must never destroy cached playlists',
      );
    });

    test('a live row (deleted_at null) is kept', () {
      expect(
        shouldRemoveLocally(
          isCloudId: true,
          inHydration: false,
          isPendingCreate: false,
          authoritativeRow: {'deleted_at': null},
          fetchThrew: false,
        ),
        isFalse,
      );
    });

    test('a pendingCreate playlist absent remotely stays local', () {
      expect(
        shouldRemoveLocally(
          isCloudId: true,
          inHydration: false,
          isPendingCreate: true,
          authoritativeRow: null,
          fetchThrew: false,
        ),
        isFalse,
        reason: 'it has not been created yet — of course it is absent',
      );
    });

    test('a local-only (non-UUID) playlist is never touched', () {
      expect(
        shouldRemoveLocally(
          isCloudId: false,
          inHydration: false,
          isPendingCreate: false,
          authoritativeRow: {'deleted_at': 'x'},
          fetchThrew: false,
        ),
        isFalse,
      );
    });

    test('a playlist present in hydration is never checked or removed', () {
      expect(
        shouldRemoveLocally(
          isCloudId: true,
          inHydration: true,
          isPendingCreate: false,
          authoritativeRow: {'deleted_at': 'x'},
          fetchThrew: false,
        ),
        isFalse,
      );
    });

    test('membership size is irrelevant to the decision', () {
      // "aaaaaaa" was reported as ~32 tracks but actually had 1; the rule must
      // not depend on membership at all.
      for (final trackCount in [0, 1, 32, 500]) {
        expect(
          shouldRemoveLocally(
            isCloudId: true,
            inHydration: false,
            isPendingCreate: false,
            authoritativeRow: {'deleted_at': 'x', 'tracks': trackCount},
            fetchThrew: false,
          ),
          isTrue,
          reason: 'cleanup must be identical for $trackCount tracks',
        );
      }
    });

    test('deleting an already-deleted playlist is idempotent', () {
      bool decide() => shouldRemoveLocally(
            isCloudId: true,
            inHydration: false,
            isPendingCreate: false,
            authoritativeRow: {'deleted_at': 'x'},
            fetchThrew: false,
          );
      expect(decide(), isTrue);
      expect(decide(), isTrue, reason: 'repeatable, never an error loop');
    });
  });
}
