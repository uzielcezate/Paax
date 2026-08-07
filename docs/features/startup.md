# Feature: Startup & Offline Resilience

> **Phase 3.4.2** — offline-first startup, explicit state machine, bounded retries.
> **Status**: implemented, PR open.
> **Owner docs**: [authentication.md](authentication.md), [offline.md](offline.md), [profile.md](profile.md).

---

## Why this exists

Two production faults converged:

1. **A wedged PostgREST instance** on the Supabase project issued ~2,344 req/s of
   empty transactions for ~12 days, saturating Nano compute. `GET /rest/v1/profiles`
   started returning **503/504**.
2. **The app treated any failed profile read as "this user has no profile"** and
   routed fully-configured users into **Complete Profile**, or hung on Splash.

Fault 1 was infrastructure and was cleared by a project restart (see
[AI_NOTES.md](../AI_NOTES.md)). Fault 2 was ours, and this phase removes the
*class* of bug rather than the instance.

---

## The invariant

> `CompleteProfileRequired` is reachable from **exactly one** event:
> `RemoteProfileResolved` carrying a `RemoteSuccess` that positively proves
> required fields are missing.

No timeout, 5xx, DNS failure, offline condition, cancellation, or unclassified
error can reach it — none of them can *construct* that event. Enforced by:

- `RemoteResult<T>` (`core/network/remote_result.dart`) — a sealed type where
  `RemoteSuccess(null)` means "server reached, no row" and `RemoteUnavailable`
  carries **no value at all**. The old `Profile?` return type collapsed these.
- `startupReducer` (`core/startup/startup_state.dart`) — a pure, exhaustive
  function; `assertNeverFromFailure()` enumerates every failure kind × cache
  state × source phase and is asserted in CI.

---

## State machine

| Phase | Meaning | Destination |
|---|---|---|
| `initializing` | nothing restored yet | Splash |
| `authenticating` | credential exchange in flight | Splash |
| `loadingLocalProfile` | reading the account-scoped cache (no network) | Splash |
| `loadingRemoteProfile` | **blocking** remote read — only when there is no usable cache | Splash |
| `onlineReady` | cache complete + remote confirmed | Shell |
| `offlineReady` | cache complete, remote unreachable | Shell |
| `syncing` | shell visible, background refresh in flight | Shell |
| `completeProfileRequired` | **proven** incomplete | Complete Profile |
| `onboardingRequired` | proven onboarding pending | Artist Onboarding |
| `setupBlockedOffline` | first-ever account, no cache, no server | "Connect to finish setting up" |
| `unverified` | email not confirmed | Verify Email |
| `recovery` | password-recovery deep link | Reset Password |
| `fatalStartupError` | local storage unreadable | Recoverable error screen |

`onlineReady`, `offlineReady` and `syncing` all map to **one** `StartupDestination.shell`,
and `AuthGate` selects on the *destination*, so connectivity changes never rebuild
the gate, remount Home/Library, lose scroll position, or interrupt playback.

### Key transitions

| From | Event | To |
|---|---|---|
| `loadingLocalProfile` | `LocalProfileLoaded` (complete **and** onboarded) | `syncing` — **shell opens before any network call** |
| `loadingLocalProfile` | `LocalProfileLoaded` (null/partial) | `loadingRemoteProfile` — an empty cache is *not* evidence |
| any | `RemoteProfileResolved(Success(complete))` | `onlineReady` |
| any | `RemoteProfileResolved(Success(null \| incomplete))` | `completeProfileRequired` |
| shell/any + cache | `RemoteProfileResolved(Unavailable(*))` | `offlineReady` |
| no cache | `RemoteProfileResolved(Unavailable(*))` | `setupBlockedOffline` |
| any | `RemoteProfileResolved(Unavailable(unauthorized))` | `unauthenticated` |
| any | `SignedOut` | `unauthenticated` (wins from every phase, incl. offline) |
| any | `LocalStorageFailed` | `fatalStartupError` |

---

## Cache schema

`profile_bootstrap` Hive box, keyed by **user UUID**, values JSON.

| Field | Notes |
|---|---|
| `schema_version` | `1`. A mismatch is a cache **miss**, never a migration failure |
| `user_id`, `username`, `display_name`, `first_name`, `last_name` | |
| `avatar_url`, `birth_date`, `country_code`, `state_region`, `city`, `gender_identity` | |
| `profile_completed`, `onboarding_completed` | the two routing gates |
| `last_successful_sync_at` | ISO-8601 |
| `__active_user__` (special key) | which account owns the device session |

**Not cached by design**: `app_role`, `subscription_tier`, `subscription_status`.
A tampered or stale cache must never be able to grant a role or a paid tier;
these reconstruct at safe defaults (`user`/`free`/`inactive`) and are re-read from
the server on the background refresh. *Consequence*: a premium user briefly shows
as free while offline. This is a deliberate security-over-convenience trade.

**Migration**: none required — additive box, absent on upgrade, and an absent or
unreadable record is a cache miss, which routes to "ask the server".

**Logout** clears `__active_user__` but retains the per-account record, so an
offline logout correctly lands on the auth screen while a re-login on the same
device is still instant and offline-capable.

---

## Bounded retry

`core/network/bounded_retry.dart`. Retries were added to a system that had just
been the *victim* of a request storm, so every property is anti-storm:

- hard attempt cap (`maxAttempts`, asserted ≤ 5);
- independent **total wall-clock budget**, so the splash has a ceiling;
- only transient kinds retry — `unauthorized` and `unknown` fail after one attempt;
- **full jitter**, so devices recovering from a shared outage don't synchronise;
- each job registers with `StartupDiagnostics` (leak/duplicate detection).

| Policy | Attempts | Attempt timeout | Total budget |
|---|---|---|---|
| `startupProfile` (blocking) | 3 | 5 s | 12 s |
| `backgroundRefresh` (behind shell) | 3 | 8 s | 30 s |
| `single` | 1 | 6 s | 8 s |

There is deliberately **no** "retry forever in background" mode. Reconciliation is
driven by explicit events (token refresh, connectivity, pull-to-refresh).

---

## Single-resolution guarantee

Previously the constructor called `bootstrap()` **and** the SDK's `initialSession`
event called `_resolve()` — production logs show paired requests 3 ms apart for
`profiles`, `user_followed_artists`, `user_followed_genres` and `albums`.

Now:
- `bootstrap()` sets `_bootstrapStarted` **synchronously**, before any `await`, so
  it deterministically wins the race against the async stream event;
- `initialSession` is **dropped** once bootstrap has run (it means "the SDK
  restored the persisted session" — exactly what bootstrap did);
- `_resolveSession` additionally deduplicates concurrent calls by user id, so
  `login()` and the `signedIn` event collapse into one run;
- `tokenRefreshed` **no longer refetches the profile** (it used to, every ~50 min
  forever); it only reconciles if we were `offlineReady`;
- concurrent background refreshes coalesce.

**Cold start now issues exactly 1 profile request** (was 2).

---

## Diagnostics

`core/startup/startup_diagnostics.dart`. `enabled` is a **compile-time constant**
(`!kReleaseMode && STARTUP_DIAGNOSTICS`), so release builds tree-shake it entirely.

Tracks: bootstrap executions, profile fetches, state transitions, and live counts
of auth listeners / realtime subscriptions / timers / retry jobs. Assertions trip
in development on a second bootstrap, an excessive fetch count, or a duplicate
resource registration.

Disable with one flag:
```
flutter build apk --dart-define=STARTUP_DIAGNOSTICS=false
```

---

## Startup dependency audit

None of these block the shell:

| Dependency | Status |
|---|---|
| Supabase profile read | background when cached; bounded when not |
| playlist hydration, follower subs, notifications, activity | after shell, own error boundaries |
| paax-api / Redis / Railway / Deezer / matcher | never on the startup path |
| Party scaffold | flag-gated, no runtime |
| `Supabase.initialize` | local session restore, bounded 8 s, non-fatal |
| `AudioService.init` | local platform channel, bounded 10 s, non-fatal |
| `HiveStorage.init` | only hard dependency → `fatalStartupError`, not a crash |

**Timers**: no `Timer.periodic` exists anywhere in the startup path. The repeated
`playlist_get_activity` calls seen in production logs were user-driven sheet
opens, not polling.

**Listeners**: `AuthController`'s `onAuthStateChange` subscription is now retained
and cancelled in `dispose()` (previously fire-and-forget, uncancellable, and able
to double-register on hot restart).

---

## Tests

| File | Covers |
|---|---|
| `test/unit/startup_reducer_test.dart` | 26 tests — exhaustive safety invariant, cache-first, isolation, no route thrash |
| `test/unit/bounded_retry_test.dart` | 17 tests — error classification (503/504/DNS/SQLSTATE/PGRST200), hard caps, timeouts |
| `test/unit/startup_controller_test.dart` | 25 tests — success/404/timeout/503/offline/expired-token/stale/switch/restart, fetch counts |
| `test/widget/startup_routing_test.dart` | 11 tests — no Complete-Profile flash frame by frame, routing table |

---

*Last updated: 2026-08-07*
