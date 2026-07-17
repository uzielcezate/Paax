# Current State

> **Purpose**: A living snapshot of what is working, what is broken, and what is in progress RIGHT NOW. This is the most frequently updated doc. Agents should read this before starting any task.
> **Update when**: At the start and end of every significant work session.

---

## Project Status

**Status**: **Alpha** — feature-rich and demoable end-to-end, but not production-hardened (no CI, debug signing, streaming not consolidated). **Real Supabase auth landed in Phase 3.1** (branch `feat/paax-branding-auth`), replacing the demo stub.
**Last Updated**: 2026-07-17
**Updated By**: Phase 3.1 auth integration (AI agent)

> For the at-a-glance health dashboard (build/tests/deploys/bug counts, milestone progress), see [PROJECT_STATUS.md](PROJECT_STATUS.md). This doc and that one should always agree.

---

## What Is Working ✅

- **Hybrid v2 metadata pipeline** — Deezer metadata + YouTube-matched playback IDs via `paax-api` `/v2/*`. See [architecture.md](architecture.md), [api.md](api.md).
- **Playback** — YouTube IFrame playback on mobile (`flutter_inappwebview`, background audio) and web (`youtube_player_iframe`), with OS media notification via `audio_service`/`PaaxAudioHandler`. See [features/player.md](features/player.md).
- **Local library** — liked tracks, playlists (create/rename/delete/reorder/pin, cap 5), saved albums, followed artists, recently played, hidden tracks — all in Hive. See [features/library.md](features/library.md).
- **Search** — debounced (400 ms) parallel track/album/artist search; genre browse grid. See [features/search.md](features/search.md).
- **Artist & album detail** — 2-phase artist profiles, discography (album/single/EP), album detail with track lists. See [features/artists.md](features/artists.md), [features/albums.md](features/albums.md).
- **Lyrics** — synced/plain lyrics via LRCLIB (+ ytmusicapi fallback). See [features/player.md](features/player.md).
- **Cinematic black / "liquid glass" UI** — dark-only, dominant-color adaptivity, gradient fades. See [design/design-system.md](design/design-system.md).
- **Image resilience** — throttling/backoff/domain-sharding to survive Google/Deezer 429s. See [performance.md](performance.md).
- **Caching** — Redis + in-memory in `paax-api`; 7-day YouTube match cache. See [CACHE_STRATEGY.md](CACHE_STRATEGY.md).
- **Deploys** — `paax-api` (Railway), Cloudflare Worker resolver, `paax-stream` (Railway, standby), web PWA/TWA. See [deployment.md](deployment.md).
- **Supabase Phase-1 foundation** — 34-table RLS-enabled Postgres schema, views/functions/triggers, 3 Storage buckets, seeded billing plans, 11 migrations in `supabase/migrations/`, owner bootstrap script. See [backend/database-schema.md](backend/database-schema.md), [decisions.md](decisions.md) ADR-009.
- **Real authentication (Phase 3.1) — Flutter wired to Supabase Auth** — email+password with PKCE, mandatory email verification, password recovery, a 3-step registration wizard, an RLS-protected `profiles` row (auto-created by trigger, privileged columns guarded), deep-link callbacks (`paax://auth/*`) on Android + iOS, and a deterministic `AuthController`/`AuthGate` routing state machine. Client uses the anon key only. The demo stub (`user@gmail.com`/`12345`) and old intro `onboarding_screen.dart` are removed. Verified live (email-free anon-contract integration test `frontend/test/live/auth_live_test.dart` 4/4 + disposable-account lifecycle: trigger, RLS, `42501` privilege-escalation guard). See [features/authentication.md](features/authentication.md). **Cloud library sync (Hive → Supabase) is still Phase 3.2+ — the library remains on-device Hive.**
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
| Frontend Phase 3.2 (cloud library sync + 5-artist onboarding) | — | not started | Phase 3.1 auth is **done** (real Supabase sign-in). Next: migrate Hive library to Supabase, real onboarding (the `onboarding` route is a placeholder). |
| "Liquid glass" UI polish (Phase 5) | uzielcezate | ongoing | Latest commits tune shadows/edges/nav bar |
| Branding Beaty → Paax | uzielcezate | ongoing | `applicationId`, `frontend/README.md`, root `README.md` still say Beaty |
| Streaming consolidation (IFrame vs Worker vs IPv6 proxy) | uzielcezate | TBD | Pick one server fallback, delete the rest (ADR-006) |

See [tasks/in-progress.md](tasks/in-progress.md).

---

## Recent Changes

| Date | Change | Author |
|------|--------|--------|
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
3. **Real auth + cloud sync integration** — the Supabase foundation is deployed (ADR-009 Phase 1); next is Phase 2 backend ingestion, then Phase 3 Flutter Auth sign-in + Hive migration.
4. **Automated tests + CI** — start with the pure units in [testing.md](testing.md).
5. **Finish Beaty → Paax rebrand.**

See [roadmap.md](roadmap.md) and [tasks/backlog.md](tasks/backlog.md).

---

*Last updated: 2026-07-16*
