# Current State

> **Purpose**: A living snapshot of what is working, what is broken, and what is in progress RIGHT NOW. This is the most frequently updated doc. Agents should read this before starting any task.
> **Update when**: At the start and end of every significant work session.

---

## Project Status

**Status**: **Alpha** — feature-rich and demoable end-to-end, but not production-hardened (no CI, debug signing, streaming not consolidated). **Real Supabase auth landed in Phase 3.1**; **Phase 3.2A** added real artist onboarding, a real Supabase-backed profile + avatar upload, and offline-first cloud library sync; **Phase 3.2B** added **followed genres** and a **personalized Home** from real Supabase catalog sections; **Phase 3.3** migrated the browsing **display** (artist detail, search artists/albums, Home hydration) onto the normalized Supabase-first `/v2` catalog, fixed artist artwork/follower-count/discography-ordering, parallelized cold-artist ingestion, extracted a replaceable onboarding discovery source, and aligned the auth top bars — **playback left exactly as-is** (eager legacy YouTube path).
**Last Updated**: 2026-07-30
**Updated By**: Phase 3.3.3 search relevance + per-track credits (AI agent)

> **Phase 3.3.3 (2026-07-30)** — frontend-only stabilization (no backend/DB change): album track rows now show real per-track credits (e.g. Duro → "Skrillex, Young Miko") overlaid from the normalized `/v2/albums/deezer/{id}` graph while keeping the legacy playback videoId; Search Top Result is relevance-ranked (Shakira for "Dai Dai", not the obscure "DAIDAI") via a tested `SearchRelevance.rankArtists`; the first uncached search no longer flashes a blank/"No results" state (loading clears only on a non-empty category); and search results dedupe exact duplicate rows while keeping legitimate editions. On-device visual QA recommended.

> **Phase 3.3.2 (2026-07-29)** — small stabilization patch (frontend only, no backend/DB change): (1) failed-track rollback now restores the **full** confirmed playback snapshot (isPlaying/position/duration), not just track identity, so the player is no longer left in an incoherent play/paused state after tapping an invalid track; (2) the artist header follower pill reconciles against the live local follow state so a **stale paax-api cached count of 0** (Drake: DB=1 but cache=0) never shows "0 Followers" while the user follows. DB verified correct (canonical Drake deezer_id 246791: count=1=follow_rows). **On-device audio still needs manual QA.**

> **Phase 3.3.1 (2026-07-27)** fixed four device-confirmed defects from Phase 3.3: compact/Home artist artwork now backfills from the catalog (stale-Hive root cause); cold artist profiles render the fast normalized core (top tracks/related load as a bounded background section) instead of blocking ~40 s on eager YouTube matching; the follower pill always shows Paax followers + optimistic delta (fixes follow-from-Related-Artists); and a play-transaction state machine stops the UI from showing a track as "playing" before the iframe actually loads it (empty/invalid videoId → "Unable to play", restore previous, skip unplayable on auto-advance). Playback engine + eager resolution unchanged. **On-device audio switch still needs manual QA.** No DB change.

> For the at-a-glance health dashboard (build/tests/deploys/bug counts, milestone progress), see [PROJECT_STATUS.md](PROJECT_STATUS.md). This doc and that one should always agree.

---

## What Is Working ✅

- **Hybrid v2 metadata pipeline** — Deezer metadata + YouTube-matched playback IDs via `paax-api` `/v2/*`. See [architecture.md](architecture.md), [api.md](api.md).
- **Playback** — YouTube IFrame playback on mobile (`flutter_inappwebview`, background audio) and web (`youtube_player_iframe`), with OS media notification via `audio_service`/`PaaxAudioHandler`. See [features/player.md](features/player.md).
- **Library (offline-first, cloud-synced)** — liked tracks, playlists (create/rename/delete/reorder/pin, cap 5), saved albums, followed artists, followed genres, recently played, hidden tracks. Hive is the fast local cache; **liked/saved-albums/followed-artists/hidden-tracks (Phase 3.2A) + followed-genres (Phase 3.2B) now sync to Supabase** (durable, cross-device, multi-account isolated). Playlists remain Hive-only. See [features/library.md](features/library.md), [decisions.md](decisions.md) ADR-011/ADR-012.
- **Followed genres (Phase 3.2B)** — a Follow/Following pill on the existing `GenreResultsScreen` (Search genre grid → results) follows catalog genres through the same offline-first pipeline as artists (`user_followed_genres`, resolve by Deezer genre id, pending-ops journal, clear-on-account-switch). The pill is hidden when no catalog genre matches the display slug or the genre has no Deezer id. See [features/library.md](features/library.md), [decisions.md](decisions.md) ADR-012.
- **Personalized Home (Phase 3.2B)** — the existing home layout now renders deterministic **real Supabase catalog** sections (Your artists, Your genres, New from your artists, Popular from your artists, Recommended for you, Trending, Recently added), each hidden when empty, backed by `HomeRepository`/`HomeController` with a per-user offline cache and pull-to-refresh. No fake data, no "Continue Listening" placeholder. See [features/home.md](features/home.md).
- **Artist onboarding (Phase 3.2A)** — real 5-artist minimum selection (popular from the `artists` table + `/v2/find` search with lazy Deezer→UUID resolve), completed via the `complete_artist_onboarding` RPC, local selection persistence, bypass prevention. See [features/onboarding.md](features/onboarding.md).
- **Real profile + avatar (Phase 3.2A)** — profile screen renders the real Supabase `profiles` row (name, `@username`, email, location, real subscription tier, joined date) + live library stats; `EditProfileScreen` edits whitelisted fields; `AvatarService` uploads to the `user-avatars` Storage bucket (resize 512px/JPEG q85). See [features/profile.md](features/profile.md).
- **Search** — debounced (400 ms) parallel track/album/artist search; genre browse grid. See [features/search.md](features/search.md).
- **Artist & album detail** — 2-phase artist profiles, discography (album/single/EP), album detail with track lists. **Phase 3.3**: the artist profile display (image, Paax follower count, genres, deterministically-ordered discography, latest release) is served by the normalized Supabase-first `/v2/artists/deezer/{id}`; top tracks + related artists stay on the eager legacy path (playback unchanged). Discography ordering is date-aware (exact date → year → title). See [features/artists.md](features/artists.md), [features/albums.md](features/albums.md).
- **Lyrics** — synced/plain lyrics via LRCLIB (+ ytmusicapi fallback). See [features/player.md](features/player.md).
- **Cinematic black / "liquid glass" UI** — dark-only, dominant-color adaptivity, gradient fades. See [design/design-system.md](design/design-system.md).
- **Image resilience** — throttling/backoff/domain-sharding to survive Google/Deezer 429s. See [performance.md](performance.md).
- **Caching** — Redis + in-memory in `paax-api`; 7-day YouTube match cache. See [CACHE_STRATEGY.md](CACHE_STRATEGY.md).
- **Deploys** — `paax-api` (Railway), Cloudflare Worker resolver, `paax-stream` (Railway, standby), web PWA/TWA. See [deployment.md](deployment.md).
- **Supabase Phase-1 foundation** — 34-table RLS-enabled Postgres schema, views/functions/triggers, 3 Storage buckets, seeded billing plans, 11 migrations in `supabase/migrations/`, owner bootstrap script. See [backend/database-schema.md](backend/database-schema.md), [decisions.md](decisions.md) ADR-009.
- **Real authentication (Phase 3.1) — Flutter wired to Supabase Auth** — email+password with PKCE, mandatory email verification, password recovery, a 3-step registration wizard, an RLS-protected `profiles` row (auto-created by trigger, privileged columns guarded), deep-link callbacks (`paax://auth/*`) on Android + iOS, and a deterministic `AuthController`/`AuthGate` routing state machine. Client uses the anon key only. The demo stub (`user@gmail.com`/`12345`) and old intro `onboarding_screen.dart` are removed. Verified live (email-free anon-contract integration test `frontend/test/live/auth_live_test.dart` 4/4 + disposable-account lifecycle: trigger, RLS, `42501` privilege-escalation guard). See [features/authentication.md](features/authentication.md). **Cloud library sync landed in Phase 3.2A** (offline-first Hive cache + Supabase authority — see the Library entry above).
- **Phase 2 backend (Supabase-first catalog) — COMPLETE, deployed** — `paax-api` now reads catalog cache-first (Redis → Supabase → Deezer ingest), persists complete artist/album/track graphs with preserved per-track credits, persists YouTube matches (`tracks.youtube_*`, audio-preferred), caches artwork to Storage, and exposes normalized `/v2/*` endpoints. **Prepared-but-not-connected**: Flutter still calls the legacy `/v2` endpoints until Phase 3. Requires `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` on Railway to activate (degrades to legacy otherwise). **Live and healthy** (Supabase + Redis). **85 backend tests.** Phase 2.6 fixed artist discography attribution (no more "Unknown Artist" placeholders; PR #3). See [backend/phase2-catalog.md](backend/phase2-catalog.md), [decisions.md](decisions.md) ADR-010, [KNOWN_ISSUES.md](KNOWN_ISSUES.md) ISSUE-021.

---

## What Is Broken or Degraded ❌

| Issue | Severity | Affected Area | Known Workaround |
|-------|----------|---------------|------------------|
| Legacy `backend` `/stream/{videoId}` throws `NameError` (`_FORMAT_FALLBACKS`) | Medium | legacy backend | Service is superseded; unused |
| ~~Deezer client `verify=False` (TLS validation off)~~ **FIXED (Phase 2.2)** | ~~High~~ | paax-api security | TLS verification enabled in the async Deezer client (certifi CA). See [CHANGELOG.md](CHANGELOG.md) |
| paax-api write endpoints unauthenticated (shared account) | High | paax-api | Do not expose publicly |
| Release Android build signs with **debug keys**; `applicationId` still `com.beaty.music.beaty` | High | Android release | Blocks store release. See [deployment.md](deployment.md) |
| Cold-cache track endpoints multi-second (eager YouTube match) | Medium | paax-api latency | Match cache warms it. See [performance.md](performance.md) |
| Image 429s under heavy web scroll | Low–Med | web artwork | Throttling mitigates |
| `paax-stream` resolver stack orphaned; README stale | Low | paax-stream | Only `/stream` byte-proxy is live |

Full list: [KNOWN_ISSUES.md](KNOWN_ISSUES.md).

---

## What Is In Progress 🔄

| Task | Owner | Target | Notes |
|------|-------|--------|-------|
| Playlists cloud migration | — | not started | Phase 3.2A + 3.2B **done** (onboarding, profile+avatar, cloud library sync, followed genres, personalized Home). Playlists remain Hive-only. |
| Advanced recommendations / listening history | — | not started | "Recommended for you" today = albums in followed genres (no play-history engine); qualified-play history still deferred. |
| "Liquid glass" UI polish (Phase 5) | uzielcezate | ongoing | Latest commits tune shadows/edges/nav bar |
| Branding Beaty → Paax | uzielcezate | ongoing | `applicationId`, `frontend/README.md`, root `README.md` still say Beaty |
| Streaming consolidation (IFrame vs Worker vs IPv6 proxy) | uzielcezate | TBD | Pick one server fallback, delete the rest (ADR-006) |

See [tasks/in-progress.md](tasks/in-progress.md).

---

## Recent Changes

| Date | Change | Author |
|------|--------|--------|
| 2026-07-26 | Phase 3.3 — browsing display migrated to normalized Supabase-first `/v2` (artist detail, search artists/albums, Home hydration); canonical `ArtworkResolver` fixes missing artist artwork; Paax follower count + singular/plural + optimistic reconcile; date-aware discography ordering (client + backend `release_ordering`); bounded-concurrency cold-artist discography ingest; replaceable `ArtistDiscoveryRepository` (`ARTIST_DISCOVERY_MODE`); auth top-bar chevron/tint fix. Playback untouched. No schema change. | AI agent |
| 2026-07-17 | Phase 3.2B — followed genres (offline-first, `user_followed_genres`, no migration; Follow pill on `GenreResultsScreen`) + personalized Home rebuilt from real Supabase catalog sections (`HomeRepository`/`HomeController`, per-user cache) | AI agent |
| 2026-07-17 | Phase 3.2A — real artist onboarding (5-artist min + RPC), real Supabase profile + avatar upload, offline-first cloud library sync (`user_hidden_tracks` + `complete_artist_onboarding` RPC), Phase 3.1 password-reuse error fix | AI agent |
| 2026-07-17 | Phase 3.1 — Flutter wired to real Supabase Auth (verification, recovery, profile, deep links, routing state machine); demo stub + old onboarding removed; live integration test added | AI agent |
| 2026-07-16 | Supabase Phase 1 deployed — schema (34 tables) + RLS + storage + billing foundation (ADR-009); not yet integrated | AI agent |
| 2026-07-16 | Full documentation pass — all `docs/` filled from code | AI agent |
| 2026 (recent) | Liquid-glass polish: black sheets, slimmer mini player/nav, shadow/edge tuning | uzielcezate |
| 2026 | Phase 5: dynamic dominant-color environments, orange-accent removal | uzielcezate |
| 2026 | Phase 4: iOS-style glass UI, floating nav | uzielcezate |
| 2026 | v2 Deezer+YouTube hybrid (`paax-api`) | uzielcezate |
| 2026 | Client-side IFrame playback, PWA/TWA packaging | uzielcezate |

Full history: [CHANGELOG.md](CHANGELOG.md), [release-notes.md](release-notes.md).

---

## Environment Health

| Environment | Status | URL | Notes |
|-------------|--------|-----|-------|
| Development (local) | 🟢 OK | `127.0.0.1:8000/:8080` | Flutter + services locally |
| Staging | ⚪ None | — | No staging environment exists |
| Production | 🟢 Up | `api.paaxmusic.app`, `stream.paaxmusic.app`, `resolver.paaxmusic.app`, `paaxmusic.app` | No uptime monitoring configured |

---

## Next Priorities

1. **Consolidate streaming** — choose a single server fallback and remove dead code (ADR-006).
2. **Production hardening** — real signing config + Paax `applicationId`; fix Deezer `verify=False`; gate/remove unauthenticated write endpoints.
3. **Playlists cloud migration**, then qualified-play listening history and advanced recommendations. (Auth, onboarding, real profile, cloud library sync, followed genres, and personalized Home are done — ADR-009/ADR-011/ADR-012.)
4. **Automated tests + CI** — start with the pure units in [testing.md](testing.md).
5. **Finish Beaty → Paax rebrand.**

See [roadmap.md](roadmap.md) and [tasks/backlog.md](tasks/backlog.md).

---

*Last updated: 2026-07-17*
