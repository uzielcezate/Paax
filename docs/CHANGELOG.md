# Changelog

> **Purpose**: A human-readable, chronological record of all notable changes to this project. Distinct from `release-notes.md` (which is user-facing) — this file is for developers and AI agents, with more technical detail.
> **Update when**: Any notable change is merged: features, fixes, refactors, dependency upgrades, breaking changes, or migrations.

---

## Format

Follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) conventions.
Versions follow [Semantic Versioning](https://semver.org/).

- **Added** — New features or capabilities.
- **Changed** — Changes to existing behavior.
- **Deprecated** — Features that will be removed in a future version.
- **Removed** — Features that have been removed.
- **Fixed** — Bug fixes.
- **Security** — Security patches or vulnerability mitigations.
- **Refactored** — Internal code restructuring with no behavior change.
- **Performance** — Performance improvements.
- **Docs** — Documentation-only changes.

> **Reconstructed history.** This changelog was backfilled on 2026-07-16 from ~163 commits of git history (the repo predates the changelog and has only one tag, `v0.1-mobile-stable`). Entries are grouped into the **development phases** the commit history reveals rather than into SemVer releases, because the project was never versioned per-release. Dates other than the top entry are approximate/relative. See [versioning](VERSIONING.md) and [decisions](decisions.md).

---

## [Unreleased]

### Phase 3.3 — Catalog normalization, Deezer→Supabase browsing migration, perf + UI fixes (2026-07-26)

Migrates the browsing **display** onto the normalized Supabase-first `/v2`
catalog while keeping the current UI and the existing (eager, legacy) YouTube
playback path **exactly as-is** — playback was explicitly out of scope.

- **Changed (frontend)** — Artist detail now loads its displayed profile (name,
  artwork, Paax follower count, genres, deterministically-ordered discography,
  latest release) from the normalized `GET /v2/artists/deezer/{id}`, in parallel
  with the legacy call that still supplies **top tracks + related artists** (the
  playback/navigation-bearing parts, unchanged). Search **artists + albums**
  results now come from normalized `GET /v2/find`; **track** search stays on the
  eager legacy path so playback is untouched.
- **Fixed (frontend §7)** — Artist artwork no longer blanks on Home circles /
  search / onboarding / compact cards. Root cause was mapping fragmentation (5
  different image-key rules); replaced with one canonical `ArtworkResolver`
  (cached → original → Deezer picture) used by every artist/album mapper.
- **Fixed (frontend §6)** — Artist header shows the **Paax platform follower
  count** (`artists.platform_followers_count`, trigger-maintained) with correct
  singular/plural ("1 Follower"/"2 Followers") and optimistic follow/unfollow
  reconciliation, instead of the external Deezer fan count. Fan count kept only
  as a fallback.
- **Fixed (frontend + backend §5)** — Discography ordering. Client sort was
  `int.tryParse("2025-03-15") → 0`, collapsing dated releases; replaced with a
  date-aware `compareReleaseDesc` (exact date → year → title → id). Backend adds
  a canonical `release_ordering` module (same rule) used by the repository and
  response mapper so malformed upstream order never leaks; `latestRelease` is the
  newest eligible record of any type. `releaseYear` is now exposed on releases.
- **Performance (backend §3)** — Uncached-artist first open no longer runs a
  serial loop of up to 100 partial-album upserts; it's a bounded-concurrency
  fan-out (`MAX_DISCOGRAPHY_CONCURRENCY`, default 8), cutting perceived latency
  toward the 1–1.5 s target while keeping discography populated. Artwork + YT
  matching remain deferred (already off the read path). Ingest timing is logged.
- **Added (frontend §9)** — Onboarding discovery is now a replaceable
  `ArtistDiscoveryRepository` (Deezer / Supabase / Hybrid sources) behind
  `ARTIST_DISCOVERY_MODE` (default `hybrid` = current behavior). The onboarding
  UI/controller is source-agnostic; switching to Supabase-first later needs no UI
  change.
- **Fixed (frontend §13)** — Home: followed-artist hydration uses the canonical
  resolver and carries the catalog UUID; followed artists are deduped and
  un-navigable entries (no Deezer id and no UUID) are dropped; search avatars
  render via `AppImage` (graceful placeholder) instead of raw `NetworkImage`.
- **Fixed (frontend §11)** — Auth top bars (Login/Register/Verify/Forgot/Reset/
  Complete Profile) drop the Material-3 surface-tint/scroll-under gray overlay
  and use the canonical Paax chevron (`arrow_back_ios_new_rounded`). No redesign,
  no navigation change.
- **Verified (frontend §12)** — Transient Supabase 5xx/network failures already
  map to a safe retryable message (never "invalid credentials"); locked with
  regression tests. No auth-error redesign.
- **Tests** — Backend 95 pytest (+10: release ordering, bounded ingest
  concurrency); frontend +26 unit (artwork/follower/release-sort, discovery
  abstraction, §12 transient auth). No schema/migration change (reads existing
  `albums.release_year`). Playback files untouched.

### Search performance — faster, cancellable, cached (2026-07-17)

- **Performance** — Optimized the Deezer-backed search pipeline (**logic only**;
  the Search screen/cards/spacing/animations/layout are unchanged): debounce
  400 ms → **220 ms**; searches start at **≥ 2 chars**; a generation token gives
  proper **newest-wins cancellation** (a slow older response can never overwrite
  a newer query); an in-memory **LRU cache** (40) paints repeated queries
  instantly with background **stale-while-revalidate**; track/album/artist
  searches paint **partially** as each returns; identical in-flight queries are
  **coalesced**; the keep-alive HTTP client is **prewarmed** and large search
  JSON is decoded in a **background isolate** for 60 FPS scrolling. Still Deezer
  `/v2` search (no normalized-`/v2` migration); the pipeline stays behind the
  `MusicRepository` interface so that migration remains a drop-in swap.
- **Tests** — `SearchController` repository made injectable; +6 unit tests
  (`search_controller_test`): min-length gate, newest-wins cancellation, instant
  cache, coalesced-query resolution, prewarm. Suite now 18/18.


> Accumulate changes here as they are merged. Move to a version section at release time.

### Phase 3.2B — Followed genres + personalized Home (real data) (2026-07-17)

> Branch `feat/phase-3.2b-genres-home`. Phase 3.2.4 (Followed Genres) +
> Phase 3.2.5 (Personalized Home). Scope was clarified mid-phase to **connect the
> existing UI to real data** — no Home redesign, no new visual system, no new
> standalone screens; existing screens/widgets/navigation are reused and state stays
> **Provider + ChangeNotifier**. **No migration** (the genres tables already existed),
> **no paax-api change**, no Railway redeploy; the YouTube IFrame playback engine is
> unchanged. See [decisions.md](decisions.md) ADR-012, [features/home.md](features/home.md),
> [features/library.md](features/library.md).

- **Added** — **Followed genres (offline-first)**, mirroring the Phase 3.2A
  artist-follow pipeline over the **existing** Supabase objects (no migration):
  `public.genres`, `public.user_followed_genres` (own-row RLS, PK `(user_id,genre_id)`)
  and the `private.bump_genre_followers` counter trigger. New `Genre` entity (Hive
  **typeId 5**: Deezer genre id + name/imageUrl/slug + `supabaseId` catalog uuid) and a
  `followed_genres` Hive box. Sync additions: `CatalogResolver.resolveGenre(s)`
  (`genres.deezer_id` → uuid); `LibraryRemoteDataSource.fetchFollowedGenreIds`/
  `followGenre`/`unfollowGenre`/`fetchCatalogGenres` (idempotent, counters never
  client-written); `LibraryRepository.pushFollowGenre` + genre cases in the exhaustive
  `_resolveForKind`/`_applyRemote` switches, hydrate/migrate blocks, and
  `_hasLocalLibrary`; `SyncOpKind.genreFollow`; `HiveStorage.getFollowedGenres`/
  `toggleFollowGenre`/`isGenreFollowed` (box cleared in `clearLibraryBoxes`/`clearAll`);
  `LibraryController.followedGenres`/`toggleFollowGenre`/`isGenreFollowed` (reset on
  account switch).
- **Added** — A **Follow / Following pill on the existing `GenreResultsScreen`**
  (`frontend/lib/presentation/screens/genre_results_screen.dart`, current button style).
  It resolves the display slug to a catalog genre (exact case-insensitive name match,
  then a deterministic substring fallback) and is **hidden** when no catalog genre
  matches or the genre has no Deezer id. Following persists to Supabase + Hive via the
  offline-first pipeline; unresolved follows (signed out / offline) queue in the
  pending-ops journal. **No** standalone genre browse/detail screen was added — the
  existing Search genre grid → `GenreResultsScreen` is reused.
- **Added** — **Personalized Home real-data sections** via a new `HomeRepository`
  (`frontend/lib/data/repositories/home_repository.dart`, batched public-catalog queries
  → typed `HomeAlbum`) and `HomeController`
  (`frontend/lib/presentation/state/home_controller.dart`): parallel section loads,
  followed artist/genre UUIDs resolved **once** (shared by new + popular, no N+1),
  stale-request cancellation via a monotonic token, per-user offline
  `SharedPreferences` cache, debounced pull-to-refresh, retry/error/offline states.
  Wired in `main.dart` via `ChangeNotifierProxyProvider<AuthController, HomeController>`
  calling `onUserSession(uid)` so the persistent Home tab drops the previous user's
  sections on account switch (no cross-account bleed).
- **Changed** — **Home data source** replaced: the old generic / YouTube-derived chart
  + genre-text-search sections are gone; Home now renders deterministic **real Supabase
  catalog** sections (each **hidden when empty**, no fake data, no "Continue Listening"
  placeholder): *Your artists*, *Your genres* (tap → existing `GenreResultsScreen`),
  *New from your artists*, *Popular from your artists*, *Recommended for you* (albums in
  followed genres), *Trending*, *Recently added*. The **existing** `home_screen` layout
  (header, top/bottom edge fades, horizontal `MusicCard` rails, `SectionHeader`,
  navigation) is preserved; album cards reuse the existing `SavedAlbum` →
  `AlbumDetailScreen` path (albums without a Deezer id are hidden).
- **Notes** — No database migration (genres tables pre-existed), no paax-api change,
  no Railway redeploy. Discarded as out-of-scope per the clarification: the exploratory
  standalone Genre Browse/Detail screens, a genre chip widget, and a new Home skeleton
  widget — only their data/controller/repository logic was kept.
- **Tests** — `flutter analyze` = 0 errors; `flutter test test/unit/` = **13/13**
  (adds a `genreFollow` journal round-trip); live disposable-account DB verification
  (genre-follow idempotency, `bump_genre_followers` 0→1→restore, cross-user isolation —
  account B sees 0) via `supabase/tests/phase3_2b_followed_genres_test.sql`; debug +
  release APK build (`applicationId com.paax.music`; release still debug-signed —
  pre-existing).

### Phase 3.2A — Onboarding, real profile + avatar, cloud library sync (2026-07-17)

> Branch `feat/phase-3.2a-onboarding-profile-library`. Three features + one Phase 3.1
> fix. paax-api was **not** modified (no Railway redeploy); the YouTube IFrame
> playback engine is unchanged. See [decisions.md](decisions.md) ADR-011,
> [features/onboarding.md](features/onboarding.md), [features/library.md](features/library.md),
> [features/profile.md](features/profile.md).

- **Added** — **Artist onboarding** (`ArtistOnboardingScreen`, `OnboardingController`):
  min-5 selection, popular artists from the `artists` table (top 30 by followers) +
  `/v2/find` search (debounced 350ms, stale-cancel + dedup) with lazy
  Deezer→catalog-UUID resolve on selection (`/v2/artists/deezer/{id}`); in-progress
  selection persisted locally (`paax_onboarding_selection_v1`, cleared on logout);
  `PopScope(canPop:false)` bypass prevention; completion via the
  `complete_artist_onboarding` RPC then `AuthController.bootstrap()` → Home. Replaces
  and **deletes** `onboarding_placeholder_screen.dart`.
- **Added** — **Real profile + avatar**: `profile_screen` renders the Supabase
  `profiles` row (name, `@username`, email, city/state/country, real
  `subscription_tier`, joined date) + live library stats; skeleton while
  `profile == null`; `EditProfileScreen` edits whitelisted fields
  (`ProfileRepository.updateOwn`); new `ProfileController`; `AvatarService`
  (image_picker → MIME/size validate → resize 512px/JPEG q85 → upload to
  `user-avatars/{uid}/avatar_{ts}.jpg` → set `avatar_url` → delete old). Home greeting
  uses `profile.firstName`.
- **Added** — **Offline-first cloud library sync** (Hive cache + Supabase authority):
  `catalog_resolver`, `library_remote_data_source`, `library_repository`,
  `library_sync_state`. RLS-safe CRUD on `user_liked_tracks`/`user_saved_albums`/
  `user_followed_artists`/`user_hidden_tracks`, scoped to `auth.uid()`, idempotent
  (ignore `23505`), counters never client-written. Optimistic local write + best-effort
  push; pending-ops journal (last-write-wins); add-only `hydrateFromCloud` (skips
  pending removes); migrate-once; clear-on-account-switch; unowned-local not uploaded.
  Wired via `ChangeNotifierProxyProvider<AuthController,LibraryController>`.
- **Added (DB)** — migration `20260717160000_phase3_2a_onboarding_and_hidden_tracks`:
  `public.user_hidden_tracks` (own-row RLS, FK index) and the
  `complete_artist_onboarding(p_artist_ids uuid[])` SECURITY DEFINER RPC
  (`search_path=''`, authenticated-only, ≥5 unique existing artists, idempotent
  follows, atomically flips `profiles.onboarding_completed`, returns
  `jsonb{onboarding_completed,followed_count}`). SQL tests in
  `supabase/tests/phase3_2a_onboarding_hidden_tracks_test.sql`.
- **Changed** — `Track` gained a nullable `deezerTrackId` (**HiveField 11**, additive/
  backwards-compatible; from the v2 payload's top-level id in `_mapTrackV2`) so tracks
  resolve to `tracks.id`. Logout now also clears the in-progress onboarding selection.
- **Fixed** — Phase 3.1: `AuthErrorMapper` maps Supabase's reused-current-password
  error (`same_password` / "should be different from the old password") to "Your new
  password must be different from your current password." — matched **before** the
  generic weak-password branch (regression test added).
- **Security** — onboarding RPC is authenticated-only + validates ownership/inputs;
  `user_hidden_tracks` own-row RLS; multi-account local isolation
  (clear-on-switch, unowned-not-uploaded); avatar Storage writes scoped to the caller's
  `{uid}/` prefix; trigger-maintained counters never client-written;
  `onboarding_completed` flippable only by the RPC.
- **Tests** — `flutter test test/unit/` = **12/12** (`auth_errors_test` +
  `library_sync_state_test`); live disposable-account DB verification (onboarding RPC
  happy/reject/dedup/auth-guard; hidden-tracks RLS+idempotency; like/save/follow/hide
  under RLS with counter bump→restore; cross-user isolation; 0 leftover test users);
  `flutter analyze` clean; debug+release APK build (`applicationId com.paax.music`;
  release still debug-signed — pre-existing).

### Phase 3.1 — Real Supabase authentication in Flutter (2026-07-17)

- **Added** — The Flutter app is wired to **Supabase Auth** (anon key, PKCE):
  email+password sign-in, a 3-step registration wizard (account → identity →
  location) with live password-strength and debounced username-availability
  checks, mandatory **email verification** (`paax://auth/confirm`), **password
  recovery** (`paax://auth/reset-password`), and a Complete-Profile fallback.
- **Added** — Deterministic routing: `AuthController` exposes an `AppAuthState`
  state machine (`initializing`/`unauthenticated`/`unverified`/`profileLoading`/
  `completeProfile`/`onboarding`/`ready`/`recovery`) that `AuthGate` maps to a
  single destination. New: `auth_repository`, `profile_repository`,
  `PendingRegistration` local store, `Profile` entity, `AuthValidators`,
  `AuthErrorMapper`/`AuthFailure`, and the `auth/*` screens.
- **Added** — Auth deep-link handling: Android intent-filter (`paax://auth`) and
  iOS `CFBundleURLSchemes` (`paax`).
- **Added** — Live integration test `frontend/test/live/auth_live_test.dart`
  (email-free anon-contract, 4/4 passing against the live project).
- **Removed** — The demo auth stub (`auth_screen.dart`, hard-coded
  `user@gmail.com`/`12345`) and the unused old intro `onboarding_screen.dart`.
- **Changed** — Logout now signs out via Supabase and **preserves** the local
  Hive library (previously a full wipe); Profile → "Clear Data" wipes local data
  then signs out. Both fixed to route via `AuthGate` (the deleted `AuthScreen`
  navigation left the build broken).
- **Security** — Client holds the anon key only; `profiles` RLS + a
  `protect_profiles_privileged_columns` trigger reject client edits to
  `app_role`/`subscription_*` with `42501`; password reset is enumeration-neutral.
- **Docs** — Rewrote [features/authentication.md](features/authentication.md).

### Phase 2.6 — Catalog integrity: discography attribution (2026-07-17)

- **Fixed** — `paax-api` artist-profile ingestion attributed albums to a
  null-`deezer_id` "Unknown Artist" placeholder when Deezer's `/artist/{id}/albums`
  entries omit the nested `artist` field, leaving the artist discography empty and
  accumulating one duplicate placeholder per album. `ingest_artist_profile` now
  injects the authoritative parent-artist context (deezer_id + canonical name)
  into each album graph; `_album_artists`/`album_graph_payload` use explicit Deezer
  data when present (deduped), else the parent context, and **never persist an
  "Unknown Artist"** — an unattributable album stays `partial`. No schema change
  (PR #3, `1ef1bd1`).
- **Data cleanup (production)** — Daft Punk (deezer 27): relinked 38 discography
  albums to the canonical artist, removed 38 placeholder `album_artists` links,
  deleted 38 orphan "Unknown Artist" rows (0 albums lost; verified via
  `artist_discography` = 38, latest release correct).
- **Verified generic** — cold-ingested Pink Floyd (deezer 860) in production: 64
  albums linked, **0** placeholder rows created, discography = 64.
- **Tests** — +9 regressions (85 total, all passing).
- Flutter, UI, playback, iframe, and schema unchanged.

### Phase 2.5 — Artwork caching + normalized /v2 + deploy (2026-07-17)

- **Added** — `services/artwork/ArtworkService`: background download (host-
  allowlisted to Deezer CDN, size/timeout capped, MIME+image validated) → WebP →
  Supabase Storage `music-images` (`artists|albums|genres/{id}/…webp`) → update
  cached URL/status → invalidate cache. Never fails catalog endpoints.
- **Added** — normalized Supabase-first `/v2/*` endpoints (`api/v2_catalog_router`):
  `/v2/artists|albums|tracks/{id}` + `/deezer/{id}`, discography, top,
  `resolve-playback`, `report-playback-failure`, `/v2/find`, `/v2/home`.
  Additive — legacy `/v2/artist|album|track|search|chart` unchanged (Flutter
  migrates in Phase 3).
- **Added** — `app_container` (single service graph at startup), richer `/health`
  (healthy/degraded/unavailable + dependency states, no secrets), request-
  correlation IDs + structured logging (`observability`), Redis rate limiting
  (`services/rate_limit`, degrades open) on expensive endpoints.
- **Tests** — +13 (artwork, rate limiter, `/v2` integration via TestClient);
  **75 total**, all passing.
- **Deploy** — Railway `paax-api` (GitHub `main` auto-deploy). Requires
  `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` to activate the normalized catalog;
  degrades gracefully (legacy endpoints keep working) until set.

### Phase 2.4 — Persistent YouTube matcher (2026-07-17)

- **Added** — `paax-api` persistent YouTube matching that writes to
  `tracks.youtube_*` (never touches canonical metadata):
  `services/youtube/candidate_classifier` (audio_only / lyric_video /
  official_music_video / live / remix / cover / other; rejects renditions absent
  from the Deezer title), `services/youtube/track_matcher` (two-slot resolver —
  best audio + best MV — with duration/title/artist/trust scoring),
  `services/catalog/playback_service` (`PlaybackMatchingService`): on-demand
  `resolve_and_persist`, `report_failure` revalidation (increment failure count,
  mark stale/unavailable, find a replacement, keep the catalog track),
  `schedule_missing_matches` (bounded-concurrency background matching so
  artist/album reads never block).
- **Playback rule** — `preferred_youtube_video_id` = audio slot; MV only when no
  acceptable audio; a valid audio preferred is never replaced by a later MV; both
  IDs + `youtube_*_match_type` persisted.
- **Tests** — +13 (classifier, matcher preference/rejection/duration, persistence,
  never-replace-audio, revalidation, missing-match-safe); 62 total, all passing.

### Phase 2.3 — Redis cache-first & stale-while-revalidate (2026-07-17)

- **Added** — `paax-api` `cache/` package (folded the old `cache.py` into
  `cache/store.py`, re-exported so `from cache import …` is unchanged):
  `cache_keys` (centralized key registry — no raw key strings elsewhere),
  `cache_policy` (TTL/freshness from config), `distributed_lock` (ownership-safe,
  expiring, bounded-wait Redis lock that degrades open without Redis),
  `response_cache` (hit/miss/stale envelopes + negative cache + targeted
  invalidation).
- **Added** — cache-first catalog services (`services/catalog/`): `CatalogService`
  (Redis → Supabase(fresh/stale-while-revalidate) → locked Deezer ingest →
  cache), `SearchService` (DB-first trigram + Deezer discovery merge/dedupe,
  never waits on YouTube matching), `HomeService` (ONE bounded chart refresh with
  a circuit-breaker cooldown that serves stale instead of 500 on Deezer 403/429),
  `BackgroundJobs` (in-process SWR refresh; process-restart limitation documented).
- **Added** — `mappers/discovery_mapper` normalized search/home item builders.
- **Tests** — +18 (locks, response cache, SWR paths, negative cache, search
  merge/dedupe, home breaker); 49 total, all passing.
- Backend-only. Redis remains transient (Supabase is the source of truth).

### Phase 2.2 — Deezer ingestion & reconciliation (2026-07-17)

- **Added (DB)** — migration `20260717145607_catalog_phase2_2_ingestion_upserts`:
  atomic `catalog_upsert_{artist,album,track}_graph(jsonb)` RPCs (+ private
  helpers), service-role-only. Enforce: preserve existing `youtube_*` and
  cached-artwork columns on refresh; never downgrade `full`→`partial`; bump
  `metadata_updated_at` only on `full`; prune junction rows only when the
  payload is `complete`. Integration-tested against production, then cleaned up.
- **Added** — `paax-api` ingestion layer: Deezer→payload mappers
  (`mappers/deezer_*`), `CatalogIngestionService` (complete album graph with
  per-track collaborators fetched from `/track/{id}` under bounded concurrency),
  `relationship_reconciler` (artist-genre enrichment), repository graph-upsert
  write methods. +18 unit tests (31 total).
- **Security / Fixed** — Deezer client now uses **secure TLS** (`verify=True`,
  certifi) instead of `verify=False`; normalized upstream errors (404→NotFound,
  403/5xx→Unavailable, 429→RateLimited, timeout→Timeout, malformed→BadResponse,
  including Deezer's HTTP-200-with-`error`-body quirk); bounded concurrency +
  in-flight request de-duplication.
- Backend-only: no Flutter, playback engine, or `/v2` endpoint changes yet.

### Phase 2.1 — Supabase catalog data layer (2026-07-17)

- **Added** — `paax-api` Supabase-first catalog data layer (ADR-009 Phase 2):
  centralized `config.py`; reusable async Supabase gateway (service-role,
  backend-only, injectable); typed catalog schemas (domain graphs + normalized
  camelCase API responses) with vocabularies pinned to the live DB CHECK
  constraints; artist/album/track/genre/search repositories with batched
  (non-N+1) entity-graph loading; row→graph and graph→response mappers; 13 unit
  tests via an in-memory fake gateway.
- **Added (DB)** — migration `20260717082812_catalog_phase2_1_match_types_and_search`:
  `tracks.youtube_audio_match_type` / `youtube_music_video_match_type` columns
  (+ CHECKs); `public.catalog_normalize(text)`; `public.catalog_search(...)`
  trigram RPC (service-role-only). Applied to production.
- **Changed (DB history)** — Phase 1's `supabase/migrations` (previously
  untracked) is now committed as the single canonical history; local filenames
  reconciled to the live version timestamps.
- **Deps** — `paax-api` adds `supabase>=2.9,<3`, `Pillow>=10.3,<12`; dev adds
  `pytest`, `pytest-asyncio`, `respx`.
- Backend-only: no Flutter, playback engine, or `/v2` endpoint changes yet.

### Added
- (nothing pending)

### Changed
- (nothing pending)

### Fixed
- (nothing pending)

### Security
- (see Phase 3.2A above; plus open items in [known issues](KNOWN_ISSUES.md): TLS `verify=False`, `str(e)` leakage, no rate limiting)

---

## Supabase Phase 1 foundation — 2026-07-16

> **Supabase Phase 1 foundation deployed — 34-table schema, RLS, storage buckets, billing readiness, owner bootstrap (ADR-009).** Deployed foundation only: nothing consumes it yet — Flutter still runs on Hive + demo auth and `paax-api` is unchanged. See [decisions](decisions.md) ADR-009 and [backend/database-schema.md](backend/database-schema.md).

### Added
- feat(db): Supabase project (`jecgmiuypuathhvjuhea`) with 34 RLS-enabled Postgres tables (catalog, profiles, library/social, playlists, stories, billing, notifications), 6 views, secure `private`-schema functions/triggers, `pg_trgm` search indexes — 11 migrations in `supabase/migrations/` (repo ↔ remote 1:1).
- feat(storage): 3 Storage buckets with policies (`music-images`, `user-avatars`, `story-media`).
- feat(billing): provider-agnostic billing schema with seeded subscription plans/features (provisional prices; no live Stripe); Stripe Edge Function scaffolds in `supabase/functions/` (**not deployed**).
- chore(auth): `scripts/bootstrap-owner.mjs` for the owner test account.

### Changed
- docs(adr): ADR-009 accepted — supersedes ADR-002 ("no server DB"); Hive remains the live client store until the Phase-3 migration.

---

## Phase 5 — "Liquid Glass" polish & dynamic color environments — 2026-07-16

> The most recent arc: solid "cinematic black" surfaces standing in for real glass, Apple-Music-style dominant-color backgrounds, full removal of the old orange accent, and slimmer chrome. Blur remains globally disabled (`forceSolidGlass=true`) except the single `BackdropFilter` in the full player.

### Changed
- style(theme): match "OC Liquid Glass" reference settings; slimmer mini player (67px) and nav bar; partial glass rim lightband (`224eb0f`, `4293f28`, `c7c282c`).
- feat(theme): Phase 5 — dynamic **dominant-color backgrounds** for artist/album/playlist detail screens; "Apple Music-style color environments"; color-matched fades with adaptive contrast (`d14425c`, `50fcb8e`, `100117f`).
- feat(ui): remove all **orange accents**, standardize adaptive foregrounds across detail/library screens; white Play button, glass secondary buttons, bold titles (`f9e2c0e`, `7fc2b31`, `23f2867`).
- feat(ui): dynamic bottom menus, play-button cutout, nav-bar consistency; exclude pure-black covers from dynamic backgrounds (`bbbf1c0`, `818c0de`, `d7a9a2e`).

### Fixed
- fix(ui): stale fades, black-glass artifacts, liquid-glass transition artifacts, readability, animation speeds, route-fade lifecycle (`a10dc8f`, `d546d6f`, `925f932`, `5b5fe7b`).
- fix(genre): genre background now a flat solid color (no darkening gradient), matching album/artist/playlist (`7785fef`, `92c5d9b`).
- fix(build): resolve `const` errors in `main_wrapper` and discography screen (`af52d44`).

---

## Phase 4 — iOS-style glass UI system — (pre-2026-07-16)

### Added
- feat(ui): Phase 4 iOS-style white glass blur UI system; floating glass navigation — remove all traditional top bars (`24b3967`, `30327a7`).

### Changed
- refine(ui): Phase 4 polish — lower opacity, fix double-blur, match widths; thinner borders, blur chips, stable controls, deeper gradients; pure-black final polish (`161d022`, `4d645f9`, `ec97da3`).

> Note: the "glass" system later converged to **solid** surfaces (`BlurCapability.canBlur()` always false) for performance/readability; the live blur is only in `player_screen.dart`. See [architecture](architecture.md).

---

## Phase 3 — Artist discography, playlist management & image caching — (pre-2026-07-16)

### Added
- feat(artist): artist **discography** with "Último lanzamiento / Álbumes / Sencillos y EPs" sections + full discography screen (`46545a9`); enrich releases from top tracks via `/album/{id}` (`5c4ede8`).
- feat(player): full-player UI polish + playback **queue with drag-to-reorder**; Song/Lyrics modes; English translation; play-icon fix (`e9563ff`, `72d3c10`, `0079c4f`).
- feat(library): **playlist management** — create/edit-order (`ReorderableListView`), pin (cap 5), per-tab search + sort (`11a61f2`, `21e5a98`, `1b02ec7`).

### Performance
- perf(artist): two-phase artist rendering (basic → enrich) + image caching improvements (`11a61f2`). See [optimization log](OPTIMIZATION_LOG.md) OPT-004.

### Fixed
- fix(artist): Singles not appearing; metadata formatting; UI translated to English (`c0e9fc4`).

---

## Client-side playback, PWA & TWA — (pre-2026-07-16)

### Added
- feat(pwa): offline-first **service worker** for TWA cold start; `.well-known/assetlinks.json` for TWA digital asset links; maskable icons & splash; PWA manifest ("Paax Music", dark `#0D0D0D`) (`b89ff5e`, `03a9903`, `4eae54b`, `9e97239`, `20232e8`).
- feat(web): **Web Media Session API**; production web build for Vercel — all metadata routes to `api.paaxmusic.app`, direct CDN streaming on web (no proxy) (`eb00652`, `9e97239`).
- feat(playback): hidden-WebView identity provider experiment (Phase 10) — HeadlessInAppWebView cookie/visitorData extraction, `flutter_inappwebview` added as a direct dependency (`c25ae64`). *(Later superseded by the direct-IFrame v2 path.)*

### Fixed
- fix(pwa): `viewport-fit=cover` for safe-area support; splash/screen unification; `CardTheme`→`CardThemeData` Flutter compatibility (`496797a`, `06c77ac`, `938cf07`).

---

## v2 hybrid pipeline & caching foundation — (pre-2026-07-16)

### Added
- feat(api): **v2 Deezer + YouTube hybrid** — `/v2/*` endpoints serving clean Deezer metadata with per-track YouTube `videoId` matching (`yt-dlp ytsearch`, scored on duration/title/artist/trust). paax-api becomes the live metadata backend, superseding the legacy `backend/` monolith. See [api](api.md).
- feat(cache): two-tier **Redis + in-memory `MemoryCache(500)`** with TTL jitter; 7-day YouTube match cache; `X-Cache` header; env-based API config. See [cache strategy](CACHE_STRATEGY.md), [optimization log](OPTIMIZATION_LOG.md) OPT-001/007.

### Changed
- chore(brand): begin **Beaty → Paax** rebrand (manifest, icons, titles); some identifiers (`beaty` package, `com.beaty.music.beaty`) still remain. See [known issues](KNOWN_ISSUES.md) ISSUE-010.

---

## [0.1.0] — v0.1-mobile-stable (initial monorepo) — (project inception)

> The only tagged milestone. Initial Flutter client + FastAPI ytmusicapi backend, then mobile playback stabilization.

### Added
- Initial monorepo: Flutter client (`beaty`) + FastAPI backend (ytmusicapi metadata + yt-dlp streaming).
- Core layered Flutter architecture (`core`/`data`/`domain`/`presentation`), Provider + ChangeNotifier state, Hive local persistence, manual `Navigator` + `IndexedStack` shell.
- Mobile playback via `flutter_inappwebview` with background-audio survival + Android foreground service (`PaaxAudioHandler`).
- v1 API surface: search/home/charts/moods/genre/artist/album/song/watch/lyrics + authenticated library/playlist/rate (single shared YTMusic OAuth).

### Security
- Auth is a **local demo stub** (`user@gmail.com`/`12345`); no server accounts. Documented, not a regression. See [security](security.md).

---

*Last updated: 2026-07-17*
