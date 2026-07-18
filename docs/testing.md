# Testing

> **Purpose**: Defines the testing strategy, tools, coverage expectations, and test organization. Agents must follow these conventions when writing or modifying tests.
> **Update when**: New testing tools are adopted, coverage goals change, or a new type of test is introduced.

---

## Current Reality (read this first)

Paax has **minimal automated test coverage** (growing since Phase 3.1/3.2A). There is:

- **A small Flutter test suite** — `frontend/test/unit/` has **18 passing** unit tests (`auth_errors_test`, `library_sync_state_test` — including a `genreFollow` journal round-trip — and `search_controller_test`: min-length gate, newest-wins cancellation, instant cache, coalesced-query resolution, prewarm) plus the Phase 3.1 live anon-contract test `frontend/test/live/auth_live_test.dart` (4/4). Coverage is otherwise still sparse.
- **No backend test suite** — `backend/` contains standalone **probe scripts** (`test_*.py`, `verify_*.py`, `debug_*.py`, `explore_genres.py`) that hit live APIs or dump `ytmusicapi` structures. They are **exploratory tooling, not assertions**, and are gitignored.
- **No CI** — no GitHub Actions; nothing runs tests on push/PR.

The only enforced gates are **`flutter analyze`** (lint) and **`dart format`**. Building a real test pyramid is a prioritized backlog item ([tasks/backlog.md](tasks/backlog.md), [IDEAS.md](IDEAS.md)). The sections below describe the **target** strategy per [`.claude/rules/testing.md`](../.claude/rules/testing.md) and mark aspirational vs. existing.

---

## Test Pyramid (target)

```
        /\
       /E2E\         ← Few (none yet): play-a-track journey
      /------\
     /  Intg.  \     ← paax-api endpoint tests, repository/data-source tests (none yet)
    /------------\
   /  Unit Tests  \  ← mappers, string_utils, matcher scoring, controllers (none yet)
  /----------------\
```

Write more unit than integration, more integration than E2E.

---

## Coverage Requirements (target)

| Area | Target | Current |
|------|--------|---------|
| Overall | 70% | ~0% |
| Business logic (controllers, mappers, matcher) | 90% | ~0% |
| API routes (paax-api) | 80% | ~0% |

Coverage must not decrease once a baseline exists. There is no baseline to protect yet.

---

## What to Test First (highest ROI given zero coverage)

Pure, deterministic, high-value units — start here:

1. **`core/utils/string_utils.dart`** — `isViewCountString`, `formatArtistNames`, `normalizeReleaseType`, `formatFans`, `extractYear`. Pure functions.
2. **paax-api `youtube_matcher._score_candidate`** — the 0–100 scoring (duration/title/artist/trust). Critical correctness, deterministic.
3. **`deezer_mapper`** — `map_track`/`map_album`/`map_artist` incl. cover-URL fallback and `_normalize_album_type`.
4. **`MusicRepositoryImpl` v2 mappers** — that `Track.id == playback.videoId` and multi-artist joining behave.
5. **`PlaybackController`** queue logic — next/prev (prev seeks 0 if pos > 3 s), shuffle, loop off→all→one→off.
6. **`HiveStorage`** — upsert-by-id, caps (recent 20 / searches 10), pin cap 5, de-dup migrations.

---

## Writing Tests

### Unit (Flutter)
`flutter_test`; mock the data source/repository (add `mocktail`). Test happy path, edge cases, errors. No shared mutable state.
```dart
test('normalizeReleaseType maps single record to single', () {
  expect(normalizeReleaseType('single'), 'single');
});
```

### Widget (Flutter)
`pumpWidget` a single widget with fake controllers (Provider `.value`). Verify the 5 UI states ([ui rule](../.claude/rules/ui.md)): loading (shimmer), loaded, empty, error (`ErrorStateWidget` + retry), offline. See [frontend/screens.md](frontend/screens.md).

### Integration (paax-api)
`pytest` + `httpx.AsyncClient` against the FastAPI app with Deezer/YouTube **mocked** (never hit live upstreams in CI — flaky, rate-limited). Assert `/v2/*` shapes and the `playback` block ([api.md](api.md)).

### E2E
First journey to automate: **search → open track → play → media notification → skip next**. Dedicated test config; never production upstream credentials.

---

## Test File Naming

| Source File | Test File |
|-------------|-----------|
| `frontend/lib/core/utils/string_utils.dart` | `frontend/test/core/utils/string_utils_test.dart` |
| `paax-api/services/youtube/youtube_matcher.py` | `paax-api/tests/test_youtube_matcher.py` |

Test files mirror the source tree.

---

## Test Data

- Use factories/builders — no hardcoded ids or emails.
- Never use production upstream data or the shared `YTMUSIC_OAUTH_JSON` account in tests.
- Open a fresh temp Hive box per test to avoid cross-test contamination.

---

## Anti-Patterns

| Anti-Pattern | Fix |
|-------------|-----|
| Hitting live Deezer/YouTube in CI | Mock upstreams |
| `sleep()` waiting on playback | Fakes / stream expectations |
| Testing WebView internals | Test `PlaybackController` against a fake `PlaybackEngine` |
| Order-dependent Hive tests | Fresh temp box per test |
| Ignoring analyzer warnings | `flutter analyze` must be clean |

---

## CI Integration (target)

Once tests exist, add GitHub Actions:
1. `flutter analyze` + `dart format --set-exit-if-changed` (enforce now).
2. `flutter test` with coverage.
3. `pytest` for paax-api (mocked upstreams).
4. Block merge on failure.

None of this runs automatically today — see [deployment.md](deployment.md).

---

## paax-api backend suite (Phase 2)

`paax-api` has **85 passing tests** (`pytest`, mocked externals via a fake
Supabase gateway / `respx`): repositories, Deezer ingestion + mappers, cache +
distributed lock + stale-while-revalidate, YouTube matcher + persistence, artwork,
rate limiter, and `/v2` endpoints. Phase 2.6 added 9 discography-attribution
regressions (parent-context attribution, explicit-data preservation + dedupe,
no-placeholder-without-context, partial downgrade, ingest idempotency). Run:
`cd paax-api && ./.venv/Scripts/python -m pytest -q`.

---

## Frontend + DB tests (Phase 3.2A)

- **Flutter unit** — `flutter test test/unit/` = **12/12**: `auth_errors_test`
  (`AuthErrorMapper`, incl. the reused-current-password `same_password` mapping)
  and `library_sync_state_test` (pending-ops journal: dedup by `kind + deezerId`,
  last-write-wins, replay). `flutter analyze` clean.
- **SQL tests** — `supabase/tests/phase3_2a_onboarding_hidden_tracks_test.sql`
  exercises the `complete_artist_onboarding` RPC and `user_hidden_tracks` RLS/PK.
- **Live disposable-account verification** — the migration was validated against
  throwaway Supabase accounts (deleted afterward, 0 leftover): onboarding RPC
  happy-path / reject-<5 / dedup / auth-guard (`42501`); hidden-tracks RLS +
  idempotency; like/save/follow/hide under RLS with counter bump→restore;
  cross-user isolation (account B sees 0 of account A's rows). This live-DB approach
  complements (does not replace) the checked-in SQL/unit tests.
- **Build** — debug + release APK build verified (`applicationId com.paax.music`;
  release still debug-signed — pre-existing).

---

## Frontend + DB tests (Phase 3.2B)

- **Flutter unit** — `flutter test test/unit/` = **13/13** (12 from 3.2A + a new
  `genreFollow` pending-ops journal round-trip in `library_sync_state_test`).
  `flutter analyze` = **0 errors**.
- **SQL tests** — `supabase/tests/phase3_2b_followed_genres_test.sql` exercises
  `user_followed_genres` RLS/PK, genre-follow idempotency, and the
  `bump_genre_followers` counter.
- **Live disposable-account verification** — validated against throwaway Supabase
  accounts (deleted afterward): genre-follow idempotency, `bump_genre_followers`
  0→1→restore, and cross-user isolation (account B sees 0 of account A's followed
  genres). Complements (does not replace) the checked-in SQL/unit tests.
- **Build** — debug + release APK build verified (`applicationId com.paax.music`;
  release still debug-signed — pre-existing). **No migration, no backend change/redeploy.**

---

*Last updated: 2026-07-17*
