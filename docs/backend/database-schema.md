# Database Schema — Supabase Postgres (Phase 1)

> **Purpose**: The always-current reference of the Supabase Postgres schema — tables, constraints, indexes, RLS, functions, views, and Storage. Agents must read this before writing any database query or migration.
> **Update when**: Any migration is applied — reflect the change immediately.

> **See also**: [`../database.md`](../database.md) (overview of both persistence layers — this server schema **and** the still-live client Hive store), [`../decisions.md`](../decisions.md) **ADR-009** (why Supabase exists now), [`auth.md`](auth.md), [`storage.md`](storage.md), [`../security.md`](../security.md).

---

## Status

**Phase 1 foundation — DEPLOYED but NOT yet consumed by any application code.**

| Layer | Status |
|-------|--------|
| Postgres schema (34 tables), RLS, views, functions, triggers | ✅ **Implemented & applied** (2026-07-16) |
| Storage buckets + policies | ✅ **Implemented & applied** |
| Subscription plans + entitlements seed | ✅ **Seeded** |
| Owner test account bootstrap | ✅ Script (`scripts/bootstrap-owner.mjs`); run manually |
| Flutter integration | 🟡 **Partial** — auth/profile (Phase 3.1) + library sync, avatar upload, and artist onboarding (Phase 3.2A) now read/write Supabase directly (`profiles`, `user_liked_tracks`/`user_saved_albums`/`user_followed_artists`/`user_hidden_tracks`, `user-avatars`, `complete_artist_onboarding`). Browsing still uses Hive cache + paax-api `/v2/*` |
| paax-api integration | ❌ **Not connected** — paax-api still serves the legacy `/v2/*`; not modified in Phase 3.2A |
| Deezer ingestion, YouTube matching jobs, Stripe, Redis jobs | ❌ **Planned** (Phase 2+) |

- **Project**: `jecgmiuypuathhvjuhea` → `https://jecgmiuypuathhvjuhea.supabase.co`
- **Migrations**: `supabase/migrations/*.sql` (11 files, applied via Supabase MCP, mirrored in repo). Never make Dashboard-only schema changes.
- **Extensions**: `pgcrypto`, `pg_trgm` (in `extensions` schema).
- **Schemas**: `public` (application data, API-exposed) and `private` (privileged helper functions, **never** API-exposed).

---

## Conventions

- `uuid` PKs via `gen_random_uuid()`; `timestamptz` everywhere; `snake_case`; `created_at`/`updated_at` (maintained by the shared `public.set_updated_at()` trigger).
- **Text + CHECK constraints instead of Postgres enums** (expansion-friendly).
- Every FK indexed; unique constraints on external IDs (`deezer_id`, ISRC left non-unique deliberately — Deezer reuses ISRCs across releases).
- **RLS enabled on all 34 tables.** Catalog: public read / service-role-only write. User data: own-row policies with `(select auth.uid())`.
- Denormalized counters are written **only** by `security definer` triggers/functions in `private` — never by clients.

## Migrations (repo ↔ remote, 1:1)

| File (`supabase/migrations/`) | Contents |
|---|---|
| `20260716090000_extensions_and_helpers` | `pg_trgm`, `private` schema, `set_updated_at()` |
| `20260716090100_catalog` | genres, artists, albums, album_artists, tracks, track_artists, artist/album/track_genres |
| `20260716090200_profiles_and_auth` | profiles, signup trigger, privileged-column guard, `public_profiles` view |
| `20260716090300_library_and_social` | likes/saves/follows, listening history, downloads, friendships, counter triggers, `record_qualified_play` |
| `20260716090400_playlists` | playlists, playlist_tracks, collaborators, follows/downloads, visibility helpers, `playlist_summary` |
| `20260716090500_stories` | stories, comments, views, reactions, `active_stories` |
| `20260716090600_billing` | plans, features, customers, subscriptions, events, entitlements fn, seeds |
| `20260716090700_notifications` | user_devices, notifications |
| `20260716090800_catalog_views` | album_track_details, artist_discography, artist_latest_release |
| `20260716090900_storage_buckets` | 3 buckets + Storage RLS |
| `20260716091000_storage_tighten_listing` | advisor fix: no public bucket listing |
| `20260717160000_phase3_2a_onboarding_and_hidden_tracks` | `user_hidden_tracks` table (+ RLS + FK index); `complete_artist_onboarding(uuid[])` RPC (Phase 3.2A) |

Each file header documents its **rollback strategy**. Rollbacks are documented drops (no down-files; Supabase migration history is forward-only).

---

## Tables (by domain)

### Catalog (public read, service-role write)

| Table | Key points |
|-------|-----------|
| `genres` | `deezer_id` unique, `name`/`slug` unique, artwork cache fields, `platform_followers_count` (trigger-derived) |
| `artists` | `deezer_id` unique, `normalized_name` (btree + trgm GIN), `dominant_genre_id` FK, artwork cache fields, `metadata_source/status/updated_at` |
| `albums` | `album_type` ∈ album/single/ep/compilation/live/soundtrack/other; `release_date` (desc index), `upc`, totals, `platform_likes/play_count` |
| `album_artists` | PK `(album_id, artist_id, role)`; roles primary/featured/producer/composer/remixer/performer/other; `position` |
| `tracks` | `deezer_id` unique, `album_id` FK (`on delete set null` — deliberate: album deletion orphans, reconciliation re-links), `isrc`, BPM fields, artwork cache, counters, **YouTube mapping block** (below) |
| `track_artists` | PK `(track_id, artist_id, role)` + `position` + `display_name` — preserves collaborator order (e.g. Young Miko *primary*, Feid *featured*) |
| `artist_genres` / `album_genres` / `track_genres` | junctions with `relevance_score` (0–1) + `source` |

**Track YouTube mapping** (Phase 2 matcher will populate; iframe playback unchanged): `youtube_audio_video_id`, `youtube_music_video_id`, `preferred_youtube_video_id` (normally the audio/Topic match), `youtube_match_status` ∈ pending/resolving/matched/failed/stale/needs_review/unavailable, `youtube_match_confidence` (0–1), `youtube_match_reason`, `youtube_match_updated_at`, `youtube_last_verified_at`, `youtube_failure_count`. Partial index `idx_tracks_youtube_pending` = the matcher work queue. **No direct audio URLs, no downloaded audio — ever.**

### Identity

| Table | Key points |
|-------|-----------|
| `profiles` | 1:1 `auth.users` (cascade). `username` unique `^[a-z0-9_.]{3,30}$`. **Private fields** (birth_date, gender_identity, location, coords) never publicly exposed. **Privileged fields** (`app_role` ∈ user/moderator/admin/owner; `subscription_tier/status/expires_at` — *cache only*, authoritative = `user_subscriptions`) are guarded by the `protect_profiles_privileged_columns` trigger: clients can never change them. `onboarding_completed` is **flipped only by the `complete_artist_onboarding` RPC** (Phase 3.2A) — never by a client `updateOwn`. |

Signup: `private.handle_new_user()` (AFTER INSERT on `auth.users`, security definer, fixed search_path) creates the profile — metadata username only if valid & free, else derived `user_<id>`; **never** fails signup; **never** reads role/tier from metadata.

Onboarding: `public.complete_artist_onboarding(p_artist_ids uuid[])` (**SECURITY DEFINER**, `set search_path=''`, Phase 3.2A) requires `auth.uid()` (else `42501`); de-dups the input and validates **≥5 unique existing** artists (`<5` → `22023`; any non-existent id → `23503`); inserts idempotent follows (`ON CONFLICT DO NOTHING` on `user_followed_artists`), flips `profiles.onboarding_completed` **atomically**, and returns `jsonb {onboarding_completed, followed_count}`. `EXECUTE` granted to `authenticated` only. See [`../features/onboarding.md`](../features/onboarding.md).

### Library & social (own-row RLS)

`user_liked_tracks`, `user_saved_albums`, `user_followed_artists`, `user_followed_genres` — composite-PK relation tables; insert/delete bumps the corresponding catalog counter via `private.bump_*` triggers. **Consumed live as of Phase 3.2A** by the Flutter offline-first library sync (Hive cache + Supabase authority — see [`../features/library.md`](../features/library.md), [`../decisions.md`](../decisions.md) ADR-011); clients do idempotent, `auth.uid()`-scoped CRUD and never write the counters.

`user_hidden_tracks` (**Phase 3.2A**, migration `20260717160000`) — `(user_id, track_id, reason?, created_at)`, PK `(user_id, track_id)`, own-row RLS (`SELECT`/`INSERT`/`DELETE`), FK index. Hidden = excluded from automatic playback + future recommendation inputs; the catalog track is **not** deleted.

`user_listening_history` — event table (`played_at`, `listened_seconds`, `completion_percentage` 0–100, `playback_source`, `session_id`, `device_id`). Client INSERT policy **forces `qualified_as_play = false`**; no client UPDATE. Only `private.record_qualified_play(history_id)` (service-role only; rule: ≥30 s or ≥50 %) qualifies an event and bumps `tracks`/`albums.platform_play_count`. Idempotent.

`user_downloaded_tracks` / `user_downloaded_albums` / `user_downloaded_playlists` — sync metadata only (`local_status`, `device_id` in PK, `last_synced_at`). **Never audio bytes.**

`user_friendships` — PK `(requester_id, addressee_id)`, no self-friendship, **unique `(least, greatest)` index prevents inverse duplicates**, statuses pending/accepted/declined/blocked/removed, participants-only RLS, trigger blocks re-pointing participants.

### Playlists

`playlists` (visibility private/followers/unlisted/public; `collaborative`; trigger-maintained `total_tracks`/`total_duration_seconds`/`platform_followers_count`), `playlist_tracks` (**own uuid row id** → reorderable/repeatable; `position`, `added_by`), `playlist_collaborators` (roles viewer/editor/owner; owner-managed), `user_followed_playlists`, `user_downloaded_playlists`.

Visibility/authorization goes through `private.can_view_playlist()` / `private.can_edit_playlist()` (security definer — avoids recursive RLS): *private* → owner+collaborators; *followers* → + accepted friends of owner; *unlisted* → anyone with the id; *public* → everyone. Edits: owner always; editors only when `collaborative = true`.

### Stories (24 h)

`stories` — ≤1 linked entity (track/album/artist/playlist) via CHECK; `expires_at` default +24 h, client policies cap at 24 h; soft `deleted_at`. `story_comments` (soft delete), `story_views` (PK `(story_id, viewer_id)` → duplicate views impossible), `story_reactions` (PK `(story_id, user_id)` → one reaction, update to change). Visibility via `private.can_view_story()`: owner always; others only non-expired+non-deleted of public profiles or friends. Feed query = `active_stories` view. **Cleanup**: expired stories are hidden, not hard-deleted; a future scheduled job (pg_cron/backend) purges N days after expiry + deletes story-media objects.

### Billing (provider-agnostic; no live payments)

`subscription_plans` (seeded: `free` $0; `premium_monthly` 9 900 / `premium_yearly` 99 900 minor units **mxn — PROVISIONAL placeholders**, ADR-009), `plan_features` (9 keys × 3 plans seeded: ad_free, unlimited_skips, high_quality_option, offline_downloads, unlimited_library, social_features, family_members, story_creation, advanced_recommendations), `billing_customers` (user ↔ provider customer id), `user_subscriptions` (**partial unique index: one active/trialing per user**; statuses inactive/trialing/active/past_due/canceled/unpaid/paused/expired), `billing_events` (idempotent ledger, `(provider, provider_event_id)` unique, **RLS with zero policies = service-role only**).

`private.sync_profile_subscription_cache()` trigger keeps `profiles.subscription_tier/status/expires_at` synced from `user_subscriptions`. `public.current_user_entitlements()` (security invoker, authenticated-only) returns the caller's effective features, falling back to the free plan.

### Notifications

`user_devices` (unique `(user_id, device_id)`; **push tokens = private, own-row RLS**; partial index on active+token), `notifications` (backend-created — no client INSERT policy; users read/mark-read/delete own; `protect_notification_content` trigger allows clients to change only `read_at`).

---

## Views

| View | Security | Purpose |
|------|----------|---------|
| `public_profiles` | **definer (deliberate)** + security_barrier | Safe public projection (id, username, display_name, avatar_url, is_private, created_at) of non-private profiles + self. Documented advisor exception — see [`../security.md`](../security.md). |
| `album_track_details` | invoker | Album tracks + full ordered contributor list (jsonb) |
| `artist_discography` | invoker | Releases `release_date desc nulls last` + type + role |
| `artist_latest_release` | invoker | Latest dated primary release per artist |
| `active_stories` | invoker | Non-deleted, non-expired stories (RLS still applies) |
| `playlist_summary` | invoker | Live track count + duration per playlist |

## Functions

| Function | Mode | Callable by |
|----------|------|-------------|
| `public.set_updated_at()` | invoker trigger | (trigger) |
| `public.current_user_entitlements()` | invoker | authenticated |
| `public.complete_artist_onboarding(p_artist_ids uuid[])` | **definer** (`search_path=''`) | **authenticated** only (revoked from anon/public) — Phase 3.2A |
| `private.handle_new_user()` | definer trigger | (auth trigger) |
| `private.protect_profile_privileged_columns()` / `protect_friendship_parties()` / `protect_notification_content()` | invoker triggers | (triggers) |
| `private.is_accepted_friend(a,b)` | definer | internal only |
| `private.can_view_playlist` / `can_edit_playlist` / `can_view_story` | definer | anon+authenticated **via RLS policies only** (private schema is not API-exposed) |
| `private.bump_artist_followers` / `bump_genre_followers` / `bump_track_likes` / `bump_album_likes` / `bump_playlist_followers` / `refresh_playlist_totals` / `sync_profile_subscription_cache` | definer triggers | (triggers) |
| `private.record_qualified_play(history_id)` | definer | **service-role only** |

All `security definer` functions use `set search_path = ''` and validate inputs.

## Counter strategy

| Counter | Source of truth | Updated by |
|---------|-----------------|------------|
| `artists/genres/playlists.platform_followers_count` | follow relation tables | trigger (sync) |
| `tracks/albums.platform_likes_count` | like/save tables | trigger (sync) |
| `playlists.total_tracks/total_duration_seconds` | playlist_tracks | trigger (sync) |
| `tracks/albums.platform_play_count` | qualified listening events | `record_qualified_play` (backend, async, eventually consistent) |
| `tracks.platform_download_count` | download tables | backend job (future; not yet wired) |

Relation/event tables are authoritative; counters are read-optimization only.

## Storage

See [`storage.md`](storage.md): `music-images` (public read via URL, no listing, service-role writes), `user-avatars` (public read via URL, own-folder write/list), `story-media` (private; own-folder CRUD; others via backend-signed URLs).

## Metadata freshness (target TTLs — Phase 2 will implement)

Artist 7 d · album 30 d · track 30 d · home/charts 1–3 h · search cache 15–60 min · YouTube mapping 30 d or until playback verification fails. Staleness is computed from `metadata_updated_at` / `youtube_match_updated_at`; `metadata_status` ∈ partial/full/stale/failed. Ingestion model (documented, not implemented): Flutter → backend → Supabase; fresh returns immediately; stale returns + schedules refresh; Deezer upsert reconciles relations; missing YouTube IDs queue for matching; Redis dedups refresh jobs.

## Search

`pg_trgm` GIN indexes on `artists/albums/tracks.normalized_*` support similarity search now. Full-text search and **vector embeddings are deliberately deferred** — no recommendation feature consumes embeddings yet, and adding pgvector before an actual consumer would be dead weight (revisit with Phase 3 recommendations).

---

*Last updated: 2026-07-17 (Phase 3.2A: `user_hidden_tracks` + `complete_artist_onboarding` RPC; library tables now consumed live)*
