// test/widget/offline_surfaces_test.dart
//
// Phase 3.4.5 — cache-first offline behaviour.
//
// The governing rule these tests encode: offline is a STATE, not an error.
// Cached content must keep rendering; the offline copy appears only where
// content genuinely is not cached; and a failed refresh must never destroy good
// cached state.

import 'package:beaty/core/network/offline_status.dart';
import 'package:beaty/presentation/widgets/error_state_widget.dart';
import 'package:beaty/presentation/widgets/offline_notice.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('known-offline errors show the exact copy, not a generic error', () {
    for (final raw in const [
      'SocketException: Failed host lookup: api.paaxmusic.app',
      'ClientException with SocketException',
      'Network is unreachable',
      'Connection refused',
      'Connection closed before full header was received',
      'TimeoutException after 0:00:10.000000',
      'Exception: API Error 503: Service Unavailable',
      'Exception: API Error 504: Gateway Timeout',
    ]) {
      testWidgets('offline copy for: $raw', (tester) async {
        await tester.pumpWidget(_wrap(ErrorStateWidget(rawError: raw)));
        await tester.pump();

        expect(find.text("Oops, you're offline"), findsOneWidget);
        expect(find.text('Connect to the internet to enjoy more music.'),
            findsOneWidget);
        expect(find.text('Something went wrong'), findsNothing);
      });
    }

    testWidgets('a genuine server error still shows a real error, not offline',
        (tester) async {
      await tester.pumpWidget(_wrap(
          const ErrorStateWidget(rawError: 'Exception: API Error 404: no such artist')));
      await tester.pump();
      expect(find.text("Oops, you're offline"), findsNothing);
    });

    testWidgets('an unrecognised error is NOT claimed to be offline',
        (tester) async {
      // Telling a connected user they are offline is its own bug.
      await tester.pumpWidget(
          _wrap(const ErrorStateWidget(rawError: 'Bad state: something odd')));
      await tester.pump();
      expect(find.text("Oops, you're offline"), findsNothing);
      expect(find.text('Something went wrong'), findsOneWidget);
    });

    testWidgets('offline state offers a retry when one is available',
        (tester) async {
      var retried = 0;
      await tester.pumpWidget(_wrap(ErrorStateWidget(
        rawError: 'SocketException: failed host lookup',
        onRetry: () => retried++,
      )));
      await tester.pump();
      await tester.tap(find.text('Try again'));
      expect(retried, 1);
    });

    testWidgets('no spinner is left running in the offline state',
        (tester) async {
      await tester.pumpWidget(_wrap(
          const ErrorStateWidget(rawError: 'SocketException: no route')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  group('OfflineNotice copy is exact and centrally defined', () {
    test('constants match the product copy verbatim', () {
      expect(OfflineNotice.title, "Oops, you're offline");
      expect(OfflineNotice.body, 'Connect to the internet to enjoy more music.');
    });

    testWidgets('compact variant keeps the same wording', (tester) async {
      await tester.pumpWidget(_wrap(const OfflineNotice(compact: true)));
      await tester.pump();
      expect(find.text("Oops, you're offline"), findsOneWidget);
      expect(find.text('Connect to the internet to enjoy more music.'),
          findsOneWidget);
    });
  });

  group('isKnownOfflineError is conservative', () {
    test('recognises connectivity failures', () {
      expect(isKnownOfflineError('SocketException: x'), isTrue);
      expect(isKnownOfflineError('Failed host lookup'), isTrue);
      expect(isKnownOfflineError('503 Service Unavailable'), isTrue);
      expect(isKnownOfflineError('TimeoutException'), isTrue);
    });

    test('does NOT claim offline for server/logic errors', () {
      expect(isKnownOfflineError('API Error 404'), isFalse);
      expect(isKnownOfflineError('PLAYLIST_VERSION_CONFLICT'), isFalse);
      expect(isKnownOfflineError('permission denied'), isFalse);
      expect(isKnownOfflineError(null), isFalse);
    });
  });

  group('OfflineStatus — one shared signal, one refresh per reconnect', () {
    late OfflineStatus status;
    setUp(() => status = OfflineStatus());

    test('starts online and only network failures flip it offline', () {
      expect(status.isOffline, isFalse);
      status.reportOutcome(succeeded: false, wasNetworkFailure: false);
      expect(status.isOffline, isFalse,
          reason: 'a validation/auth failure says nothing about connectivity');
      status.reportOutcome(succeeded: false, wasNetworkFailure: true);
      expect(status.isOffline, isTrue);
      status.reportOutcome(succeeded: true);
      expect(status.isOffline, isFalse);
    });

    test('reconnect triggers exactly ONE refresh per key', () async {
      status.debugSetOffline(true);
      var refreshes = 0;
      Future<void> refresh() async => refreshes++;

      status.debugSetOffline(false); // reconnect
      await status.refreshOnce('home', refresh);
      await status.refreshOnce('home', refresh);
      await status.refreshOnce('home', refresh);

      expect(refreshes, 1, reason: 'rebuilds must not multiply requests');
    });

    test('repeated rebuilds do not multiply requests', () async {
      status.debugSetOffline(true);
      status.debugSetOffline(false);
      var refreshes = 0;
      // Simulate 50 widget rebuilds each calling refreshOnce.
      for (var i = 0; i < 50; i++) {
        await status.refreshOnce('artist:1', () async => refreshes++);
      }
      expect(refreshes, 1);
    });

    test('concurrent callers join the in-flight refresh', () async {
      status.debugSetOffline(true);
      status.debugSetOffline(false);
      var refreshes = 0;
      Future<void> slow() async {
        refreshes++;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }

      await Future.wait([
        status.refreshOnce('lib', slow),
        status.refreshOnce('lib', slow),
        status.refreshOnce('lib', slow),
      ]);
      expect(refreshes, 1);
    });

    test('different surfaces each refresh once', () async {
      status.debugSetOffline(true);
      status.debugSetOffline(false);
      final hits = <String>[];
      for (final key in ['home', 'library', 'artist', 'album', 'playlist']) {
        await status.refreshOnce(key, () async => hits.add(key));
        await status.refreshOnce(key, () async => hits.add(key)); // rebuild
      }
      expect(hits, ['home', 'library', 'artist', 'album', 'playlist']);
    });

    test('a SECOND reconnect refreshes again', () async {
      var refreshes = 0;
      Future<void> refresh() async => refreshes++;

      status.debugSetOffline(true);
      status.debugSetOffline(false);
      await status.refreshOnce('home', refresh);

      status.debugSetOffline(true); // dropped again
      status.debugSetOffline(false); // reconnected again
      await status.refreshOnce('home', refresh);

      expect(refreshes, 2);
      expect(status.onlineGeneration, 2);
    });

    test('no refresh runs while still offline', () async {
      status.debugSetOffline(true);
      var refreshes = 0;
      await status.refreshOnce('home', () async => refreshes++);
      expect(refreshes, 0,
          reason: 'refreshing while offline just burns a doomed request');
    });

    test('a failed refresh can be retried on the next reconnect', () async {
      status.debugSetOffline(true);
      status.debugSetOffline(false);
      var attempts = 0;
      await status.refreshOnce('home', () async {
        attempts++;
        throw Exception('still flaky');
      });
      expect(attempts, 1);

      status.debugSetOffline(true);
      status.debugSetOffline(false);
      await status.refreshOnce('home', () async => attempts++);
      expect(attempts, 2, reason: 'a failure must not wedge the key forever');
    });

    test('account switch clears per-account refresh state', () async {
      status.debugSetOffline(true);
      status.debugSetOffline(false);
      var refreshes = 0;
      await status.refreshOnce('library', () async => refreshes++);
      expect(refreshes, 1);

      status.onUserSession('other-user');
      await status.refreshOnce('library', () async => refreshes++);
      expect(refreshes, 2, reason: 'the new account must load its own data');
    });

    test('going offline does not clear any cached state — status only', () {
      // OfflineStatus holds no content; this pins the design decision that the
      // offline signal is orthogonal to cached data and can never evict it.
      status.debugSetOffline(true);
      expect(status.isOffline, isTrue);
      expect(status.onlineGeneration, 0,
          reason: 'generation only advances on RECONNECT, not on going offline');
    });
  });
}
