# Testing

> **Purpose**: Defines the testing strategy, tools, coverage expectations, and test organization. Agents must follow these conventions when writing or modifying tests.
> **Update when**: New testing tools are adopted, coverage goals change, or a new type of test is introduced.

---

## Current Reality (read this first)

Paax has **near-zero automated test coverage**. There is:

- **No Flutter test suite** — `frontend/test/` is effectively empty; `flutter_test` ships but is unused for real tests.
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

*Last updated: 2026-07-17*
