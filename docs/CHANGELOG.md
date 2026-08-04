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

### Phase 3.4.1.2 — Follow notifications, avatars, notification deep-nav, activity polish, integrity audit (2026-08-04)

Completion/stabilization pass before Phase 3.4.2 Cloud Likes. **DB: additive
migration only** (redefines two functions; no schema/table change, no `paax-api`/
Railway change). UI preserved, playback untouched, Provider + ChangeNotifier.

- **Added — Follow notifications (§A):** following a viewable playlist emits
  exactly one `playlist_followed` notification to the owner, from inside
  `playlist_set_follow` (trusted RPC). Deduped per (owner, follower, playlist) via
  `pl_follow:` key; `FOUND`-gated so an idempotent repeat follow never
  re-notifies; never self-notifies. **Unfollow is intentionally silent** (product
  decision: avoid follow/unfollow inbox spam; a re-follow refreshes the existing
  row). Following does **not** touch `updated_at`/`last_modified_at/by` — the
  counter is maintained by the existing `bump_playlist_followers` trigger only
  (verified). Clients still cannot forge notifications (no INSERT policy; emitter
  `EXECUTE` revoked).
- **Added — Actor avatars (§B):** the emitter payload now carries `actor_avatar`
  (`coalesce(avatar_url, avatar_original_url)`). A single canonical `ActorAvatar`
  widget renders every actor avatar (circular center-crop, error/placeholder
  fallback, initials for a known name, neutral glyph for a deleted/unknown actor).
  Notification rows show the actor avatar; the body keeps the actor's username
  snapshot so historical rows stay readable after the actor is deleted — never a
  raw UUID (falls back to "Deleted user"). No N+1 (payload is self-contained).
- **Added — Notification deep navigation (§C):** tapping a playlist notification
  marks it read, resolves the canonical playlist UUID, and opens Playlist Detail
  (back returns to the inbox). In-library playlists open instantly; others are
  fetched under RLS (visibility + blocking enforced server-side). A deleted /
  private-inaccessible / blocked target shows "This playlist is no longer
  available." instead of crashing or looping. Playlist Detail now falls back to
  the passed entity when the target isn't in the local library (e.g. a
  pending-invite playlist), guarded by the existing soft-delete/access check.
- **Changed — Activity presentation (§E):** a single `PlaylistActivityPresentation`
  mapper (icon · title · subtitle · semanticLabel · destructive) is now the one
  source of truth for every activity type — distinct Material icons, friendlier
  public/private copy ("made this playlist public/private"), bounded inline track
  summary ("Duro, offline, WASSUP and 3 more"), a11y semantics, no color-only
  meaning. The activity sheet renders through it (no duplicated switches).
- **Fixed — Playlist follower realtime (§F):** a follow bumps the counter without
  bumping `version`, so the version-guarded `playlist` realtime event was dropped
  and viewers never saw the count change. The realtime backend now also emits an
  unguarded `followers` event carrying the authoritative absolute count; the
  detail controller applies it idempotently (no delta double-apply) and never
  infers the current user's follow state from the global count.
- **Audit — Cloud playlist integrity (§G):** read-only audit of all 3 production
  playlists — perfect integrity (zero orphans, zero counter mismatches). One live
  valid owned playlist + two legitimately owner-soft-deleted. **No disposable
  artifacts → no cleanup performed** (§I dry-run: nothing eligible). Root cause of
  any "playlists don't appear": two accounts exist — the active
  `iamleizu@gmail.com` (owns all 3) and a never-signed-in
  `uziel.sando@hotmail.com` (owns none); signing into the latter shows nothing.
  Hydration/migration verified correct for the active account.
- **Tests:** +25 (activity presentation icons/copy/bounded, actor avatar,
  deep-nav resolver, notification avatar/label, `followers` unguarded dispatch).
  257 pass; `flutter analyze` clean; no new security advisor. Follow-notification
  lifecycle verified in production with disposable users in rolled-back
  transactions (emit-once, dedupe, self-skip, silent unfollow, no `last_modified`
  change).

### Phase 3.4.1.1 — Cloud playlist stabilization, invitation notifications, privacy management, Party entry scaffold (2026-08-03)

Follow-up to 3.4.1. **DB: additive migrations only** (extends the pre-existing
`notifications` table; no `paax-api` change, no Railway redeploy). UI preserved,
playback untouched, still Provider + ChangeNotifier.

- **Fixed — Reorder header overlap (§A):** in Edit Order mode the first
  reorderable row rendered under the fixed top bar. The list top inset is now
  composed from the real bar height via the pure `editOrderListPadding(safeTop)`
  helper (`safeTop + kEditOrderBarHeight + kEditOrderListGap`), not a hardcoded
  number. Widget test asserts the first row's top is at/below the bar bottom.
- **Fixed — Delete/leave/unfollow by role (§B):** the root cause of "deleted in
  app but still in Supabase" was an optimistic local removal with no RPC and no
  rollback plus role confusion. `LibraryController.deletePlaylist` is now
  **RPC-first** (owner-only `playlist_delete`; throws before any local change →
  no local-only deletion), then clears Hive + device-local pin. New
  `leavePlaylist` (collaborator → `playlist_leave`, own library only); followers
  unfollow via `playlist_set_follow(false)`; pending invitees decline. The
  overflow menu now shows the correct single action per role
  (owner=Delete, collaborator=Leave, follower=Remove-from-library,
  invitee=Decline) — UI visibility is convenience; the RPC/RLS is authoritative.
- **Changed — "Last modified…" always tappable (§C):** every cloud playlist
  (owner/collaborative/followed/zero-track) opens the activity detail sheet.
  `ensureLatestActivity()` fetches on demand and synthesizes a "created" event
  when the log is empty. Actor shows username, never a UUID (fallback "A user").
- **Added — Playlist privacy management (§D):** owner overflow → "Edit privacy"
  (Private/Public) via version-checked `playlist_update_metadata`; emits a
  grouped `visibility_changed` activity; rolls back + reloads on version
  conflict. Visibility stays orthogonal to collaboration.
- **Added — Invitation notifications (§E):** the existing `notifications` table
  gains `actor_user_id, entity_type, entity_id, acted_at, dedupe_key,
  deleted_at`, a partial-unique dedupe index `(user_id, dedupe_key)`, and
  realtime. A trusted `private.emit_playlist_notification` (revoked from all
  client roles) is called **inside** the collaboration RPCs (same transaction):
  invite→invitee, accept/decline→owner, leave→owner, remove→user (+ revokes the
  pending invite notif), ownership-transfer→new owner. Types:
  `playlist_collaboration_invited/accepted/declined`,
  `playlist_collaborator_removed/left`, `playlist_ownership_transferred`.
- **Added — Notification inbox + Home bell (§E/§F):** a Flutter layer
  (`AppNotification` model, `NotificationInbox` data source,
  `NotificationRealtimeService`, `NotificationController`), a Home-header
  **bell** immediately left of the profile (live red badge, hidden at 0, caps at
  "99+", never blocks the tap), and a **Notifications screen** (Today/Earlier,
  unread-distinct, relative time, pull-to-refresh, realtime, loading/empty/error
  states, mark-one-on-open, "Mark all as read", inline Accept/Decline on live
  invites, quiet status for revoked/expired). Account-switch safe (rebinds +
  discards previous rows; realtime filtered `user_id=eq`).
- **Added — Create action sheet + Party entry scaffold (§G):** the "+" button
  opens a sheet (Create playlist / Start a Party). Create playlist keeps the
  existing flow. **Start a Party is an entry scaffold only**, behind
  `AppConfig.partyEnabled` (default **OFF**): it opens an informational prep
  sheet ("temporary shared listening session… coming soon") and creates nothing.
  No Party backend/migrations.
- **Security:** notification rows can only be created by the trusted RPC path —
  RLS has **no client INSERT policy** (verified: a direct client INSERT and a
  direct call to the emitter both fail); SELECT/UPDATE/DELETE are own-rows-only;
  the emitter payload is display-safe (playlist title/cover + actor username, no
  private track data). Non-owner invite is `FORBIDDEN`, closing the forgery
  vector. Verified end-to-end in production with disposable users in rolled-back
  transactions (invite/accept/decline/leave/remove/transfer + dedupe; zero data
  left behind).
- **Tests:** +32 automated (notification model, inbox realtime lifecycle,
  controller state/realtime/mark-read/invite-response/account-isolation, Home
  bell badge, reorder-header geometry, create/Party sheet). Full suite green
  (one pre-existing empty smoke test fails on `path_provider` in headless mode).

### Phase 3.4.1 — Cloud Playlists, collaboration, ownership, activity, following, cross-device sync (2026-08-02)

Converts playlists from device-local Hive entities into authoritative
Supabase-backed cloud playlists while preserving the current UI, playback, collage
and device-local pins. Hive remains the offline cache / optimistic mirror /
pending-op journal. **DB: additive migrations only (all playlist tables were
empty → zero data risk); no `paax-api` change, no Railway redeploy.**

- **Schema** (additive): `playlists` gains `version`, `last_modified_at/by`,
  `deleted_at`, `cover_mode`, `custom_cover_url`, `source_playlist_id`;
  `playlist_tracks` gains `updated_at` + a deferrable `unique(playlist_id,position)`
  + `unique(playlist_id,track_id)` (**one-based** positions); `playlist_collaborators`
  gains the invitation lifecycle (`status`/`invited_by`/`invited_at`/`accepted_at`/
  `joined_at`/`updated_at`). New `playlist_activity` (append-only) and `user_blocks`
  tables. Tightened `private.can_view_playlist`/`can_edit_playlist` (accepted-only
  edit, blocking-aware, soft-delete aware) + `is_playlist_owner`/`is_blocked`/
  `log_playlist_activity`. Reused existing totals/follower/updated_at triggers.
  Realtime enabled for the four playlist tables.
- **14 transactional RPCs** (SECURITY DEFINER, `search_path=''`, auth+permission+
  version checked, activity-emitting, `authenticated`-only): create, save_order
  (optimistic version conflict), add/remove tracks, update_metadata, delete
  (soft), set_follow, invite/respond/leave/remove_collaborator, transfer_ownership,
  clone, add_tracks_from_source, plus `private.handle_owner_account_deletion`
  (oldest eligible accepted collaborator; skips blocked; soft-delete when none)
  fired by an `auth.users` AFTER DELETE trigger.
- **Flutter cloud-sync layer**: `PlaylistPermissions` (central role policy),
  `PlaylistActivity`/`ActivitySummary`, `PlaylistRemoteDataSource` (typed
  conflict/forbidden errors), offline `PlaylistOp`/journal/`PlaylistSyncService`
  (ordered replay), `PlaylistRealtimeService` (ref-counted, version-guarded,
  account-reset), `PlaylistMigrationService` (idempotent, retry-safe client UUID),
  `PlaylistRepository` facade.
- **Role-dependent Playlist Detail UI** (spec §6/§7/§9): header line 1
  `contributors · Last modified …` (tappable → activity detail sheet), line 2
  `Visibility · N songs · duration · N followers`; owner/editor keep the edit
  action row, a non-member gets Follow/Following + Add-to-playlist and Pin →
  overflow; owner-only **Manage collaborators** (invite/remove/transfer) +
  invitee Accept/Decline prompt. No redesign; collage/spacing/playback unchanged.
- **LibraryController cloud integration**: new playlists are cloud-backed from
  creation (client UUID); mutations push (best-effort + journal); on session,
  idempotent migration of pre-3.4.1 local playlists → cloud (re-key local + pin
  to the cloud UUID) + flush + hydrate owned/collaborating/followed.
- Tests: DB/RLS verified via JWT-claim simulation + a two-account end-to-end
  production scenario (create→invite→accept→edit→reorder→public→follow→clone→
  transfer, self-cleaning); 40+ new Flutter unit/widget tests (permissions,
  activity, sync journal/replay, migration idempotency, realtime guards, formatter,
  activity sheet, collaborators sheet, uuid). No new/real security advisory (the
  RPC WARNs are the intended permission-checked SECURITY DEFINER pattern).
- **Not started** (out of scope): cloud likes/hidden tracks, playback-session
  persistence, listening history, folders, full activity feed, discovery rankings.
  **Multi-device realtime delivery and audible playback are on-device QA.**

### Phase 3.3.6 — Playlist metadata, cloud-ready ordering, cover collage, Library spacing (2026-08-01)

Focused stabilization before Phase 3.4 cloud sync. **Frontend only — no backend
change, no Railway redeploy, no Supabase migration** (local Hive model + UI). No
playback change. UI preserved (no redesign).

- **Changed — Playlist Detail metadata is now 3 semantic lines:** title / owner +
  accepted collaborators (comma-separated) / `Visibility · N songs · duration`
  (e.g. `Private · 6 songs · 22 min`). Replaces the old single line that
  concatenated a hardcoded `iamleizu` with the track count. Owner falls back to
  the live profile username; the contributor line is deduped by canonical user
  id (owner first, never repeated), never blank, ellipsized. Singular/plural and
  duration (`22 min` / `1 hr 18 min`, omitted when zero) via a tested
  `PlaylistMeta` formatter. **No "Collaborative" label** — collaboration is shown
  by the participant line; visibility (Public/Private) is independent.
- **Added — cloud-ready playlist model:** `owner`, `collaborators` (accepted-only
  for display), `visibility`, `isCollaborative`, and **explicit zero-based track
  positions** (normalized: contiguous, no duplicates). All additive + nullable
  (legacy Hive records upgrade idempotently). Repository seam
  `updatePlaylistTrackPositions(playlistId, [{trackId, position}])` — local-only
  this phase (Phase 3.4 will push to Supabase).
- **Changed — reorder is committed only on Save.** Edit Order stages changes in a
  buffer; cancel/back retains the previously committed order; Save normalizes
  positions and persists to Hive (survives restart). New tracks append after the
  max position; removal never corrupts ordering.
- **Fixed — generated cover collage alignment.** The collage now fills its parent
  square via `AspectRatio(1)` + `Expanded` quadrants (each exactly half the
  actual box) with one outer clip and center-crop; deduped + invalid-URL-filtered
  inputs; balanced 1/2/3/4 layouts. Root cause was a rigid `size:240` grid
  clipped inside a `screenWidth*0.54` box.
- **Fixed — large blank gap in Library.** All tabs hardcoded `safeTop + 230`,
  ~80px more than the real ~150px header. Now the header is measured and every
  tab pads to it via one shared helper (`LibraryLayout.listTopInset`) — no per-tab
  magic number. Non-empty lists start shortly below the search row; the
  mini-player never affects the top inset.
- **Changed — pinned playlists are device-local AND per-account.** Pin state is
  namespaced by account scope so it never leaks across accounts on the same
  device; excluded from any future cloud payload. Legacy flat pins migrate to the
  local scope.
- Tests: `playlist_meta`, `playlist_order`, `playlist_persistence` (real Hive
  restart + idempotent migration), `library_layout`, `playlist_cover` widget
  (square/quadrant proof) — 60+ new assertions, 151 suite pass.

### Phase 3.3.5 — Real-time global artist follower counts (2026-07-31)

Fixes a multi-user consistency bug: the artist follower pill combined a stale
24h-cached API baseline with the current user's local follow delta
(`reconcileFollowerCount`) instead of the authoritative global count. So after
another user followed/unfollowed, the number was wrong (e.g. showed 1 or 0 when
the DB total was 2/1). **Frontend + one small DB migration; no `paax-api`
change, no Railway redeploy** (verified read-only + a controlled 0→1→2→1→0
follow-cycle simulation: the trigger-maintained `platform_followers_count` is
authoritative and consistent for every artist; no duplicate-UUID identity bug).

- **Added — `FollowerCountService` (`data/remote`).** Renders the AUTHORITATIVE
  global count from `artists.platform_followers_count` via a direct read + a
  Supabase **Realtime** UPDATE subscription on the public `artists` row
  (aggregate only — no user identity; RLS-safe). `user_followed_artists` is
  own-rows-only under RLS, so it can't be a global-count source. Backend-agnostic
  for headless tests.
- **Changed — the follower pill** now binds to the authoritative count (live via
  realtime), not `cachedBase + sessionDelta`. `isFollowing` (the checkmark)
  stays the current user's; the number is the community's. Singular/plural
  unchanged. `reconcileFollowerCount` is retired from the UI.
- **Added — source-priority guard.** A cached API value only *seeds*; it can
  never overwrite an authoritative realtime/server value (a stale
  `/v2/artists/deezer/{id}` can't clobber a newer count).
- **Added — optimistic + realtime reconciliation.** Optimistic +1/-1 on the
  user's own toggle, reconciled by the realtime UPDATE their own write triggers;
  a monotonic optimistic-sequence guard discards a `refresh()` that raced the
  optimistic action, so the pill never jumps backward (2→1→2). Never shows 0
  while another user still follows.
- **Added — lifecycle.** `ArtistDetailScreen` subscribes (ref-counted — one
  channel per artist shared across Related-Artist navigation), disposes on
  leave, refreshes on app resume; keyed strictly by the canonical Supabase UUID.
  Driven by the auth session for multi-account isolation.
- **Migration** `20260731090000_phase3_3_5_realtime_artist_followers.sql` — adds
  `public.artists` to the `supabase_realtime` publication (idempotent; default
  replica identity suffices). No new security advisor.
- Tests: `test/unit/follower_count_service_test.dart` (14) — all 12 required
  scenarios + raced-refresh guard + optimistic floor. 111 suite pass.
  Multi-device realtime delivery is on-device QA (fake backend can't prove it).

### Phase 3.3.4 — Universal per-track artist credits across all albums (2026-07-30)

Phase 3.3.3 fixed per-track credits for **SOMA** only because that album had been
*played* (the play-queue enrichment carried its collaborators). Every unplayed
album (att., DeBÍ TiRAR MáS FOToS) still collapsed each row to the album's primary
artist. **Frontend only — no backend change, no Railway redeploy, no DB/schema
change, no data repair** (verified read-only: att. 16/16, DeBÍ TiRAR MáS FOToS
17/17, SOMA 13/13 tracks fully credited in Supabase, zero missing/duplicate rows).

- **Fixed — per-track credits now resolve for every album, not just played ones.**
  Root cause was *not* data or key mismatch: the 3.3.3 credit overlay ran inline on
  the album-open path with a **2.5s timeout**, but the normalized
  `/v2/albums/deezer/{id}` response for a 16-track album is ~3.2s even warm → it
  timed out → empty credits → legacy album-primary fallback. SOMA escaped only via
  play-queue enrichment. The overlay now runs **progressively, off the critical
  path** (`enrichAlbumCredits`, 12s bound), so the album opens fast and subtitles
  fill in shortly after — one batched normalized request per album (no N+1), keyed
  by Deezer track id, keeping each track's legacy playback videoId.
- **Fixed — normalized overlay could downgrade richer credits (max-wins).**
  `_applyTrackCredits` now overlays only when the normalized graph is at least as
  complete as the track's existing artists, so a partial ingest can't drop a
  collaborator a played track already shows.
- **Changed — coverage-aware retry moved into the repository.** A second normalized
  read fires only when the catalog returned a payload *and* some tracks are still
  uncovered (partial ingest); never for a not-in-catalog album nor a fully-resolved
  one. Not-in-catalog albums no longer pay two wasteful 12s round-trips. Screen
  enrichment collapsed to a single `mounted`-guarded `setState`.
- **Unchanged:** album header still uses `album_artists`; playback path,
  3.3.2 failed-track rollback, UI/typography untouched.
- Tests: `test/unit/album_credits_test.dart` — generic att./Bad Bunny fixtures
  (not SOMA), videoId preservation, batch=1, no-downgrade, partial-ingest retry.
  97 unit tests pass (PR #74 → `1a08e57`).

### Phase 3.3.3 — Search relevance, progressive rendering, per-track credits (2026-07-30)

Focused stabilization based on real Android QA. **Frontend only — no backend
change, no Railway redeploy, no DB/schema change** (verified read-only: SOMA's
`track_artists` are correct in Supabase). No UI redesign; playback unchanged.

- **Fixed — album track rows showed only the album primary artist (issue 3/4).**
  SOMA rows all read "Skrillex". Root cause was UI/mapping: album detail used the
  legacy `/v2/album/{id}`, whose per-track `artists` only carry the album primary
  artist (Deezer's album tracklist omits contributors). Album detail now overlays
  the real per-track credits from the normalized `/v2/albums/deezer/{id}`
  (Supabase `track_artists`), keyed by Deezer track id, while keeping the legacy
  videoId for playback (playback path unchanged). One canonical
  `TrackCredits.resolve()` orders by position (primary before featured), dedupes
  by UUID → Deezer id → name, and hides non-performing roles. Duro →
  "Skrillex, Young Miko", Noche Without You → "Skrillex, Feid", Thistle →
  "Skrillex, Randomer, Blawan, Mc Dricka". The credit fetch runs in parallel with
  the legacy album call (short-bounded) so it adds no serial latency.
- **Fixed — Search Top Result relevance (issue 1).** The Top Result was
  unconditionally the first name-matching artist, so "Dai Dai" surfaced the
  obscure "DAIDAI" instead of Shakira (the primary artist of the strongest exact
  track/album matches). A new central, tested `SearchRelevance.rankArtists()`
  scores candidates generically (no hardcoded names): primary-of-exact-matching
  tracks/albums and exact/prefix/token name matches, with popularity as a pure
  tie-breaker. Candidates combine the name-match artists with the primary artists
  of exact matches; a derived winner (Shakira) is resolved to a navigable artist.
- **Fixed — blank/"No results" flash on the first uncached search (issue 2).**
  The global loading state was cleared by the first category to return even when
  it was empty, briefly flashing "No results found" while other categories were
  still pending. It now clears only when a non-empty category arrives (or all
  settle). Per-category progressive painting, generation cancellation,
  cache-first and coalescing are preserved.
- **Search result dedup.** Collapse exact duplicate rows (same id, or an id-less
  title+artist+duration match) while preserving legitimate alternate editions
  (distinct ids).
- **Tests** — `flutter analyze` 0 errors; **88 unit tests** (credits, relevance,
  dedup, Top-Result + progressive integration). Adversarial review; H1 (album
  latency), H2 (role denylist), M2 (exact-name weight), M3 (no flicker) fixed.

### Phase 3.3.2 — Player rollback + Drake follower consistency (2026-07-29)

A small, focused stabilization patch for two remaining device-confirmed issues.
No new features / UI / engine / schema changes. **Frontend only — no backend
change, no Railway redeploy.** No DB mutation (verified read-only).

- **Fixed — player UI inconsistent after a failed track (issue 1).** After the
  3.3.1 rollback, tapping an invalid track (JACKBOYS 2 "CHAMPAIN & VAC…", empty
  videoId) correctly showed the error and kept the previous track, but the
  play/pause icon and progress became incoherent (Play shown while the previous
  audio was still sounding). Root cause: the rollback restored track **identity**
  only — `_playCurrent` reset `isPlaying/position/duration` and `_failPlayback`
  left `isPlaying=false`, and `playingStream` never re-asserted (no state change).
  Fix: an **atomic confirmed-playback snapshot** (queue, index, isPlaying,
  position, duration) captured from a dedicated confirmed store (updated only
  while not loading, so a superseded in-flight transaction can't corrupt it) and
  restored fully on failure; the empty-id path never touches the engine or the
  confirmed track's state, and the error path re-cues it (reload + seek + restore
  play/pause). Persistent engine listeners are gated during a transaction so a
  stale event from the failing video can't overwrite the restored state; the
  generation token still discards superseded transactions. +6 playback tests.
- **Fixed — Drake follower count stuck at 0 (issue 2).** Read-only production
  inspection found the DB is **correct** — the canonical Drake row
  (`deezer_id 246791`) has `platform_followers_count = 1 = COUNT(user_followed_artists)`
  (trigger agrees); the four other "Drake" rows are distinct Deezer artists (no
  merge). The bug is a **stale paax-api Redis response**: `/v2/artists/deezer/246791`
  returns `platformFollowersCount = 0` (`X-Cache: hit`) because follows are
  written Flutter→Supabase and never invalidate the API cache (24h TTL), and
  Drake was followed in a prior session so no in-session delta masked the stale
  0. No data mutation needed. Fix: the header pill reconciles the count against
  the live local follow state — `max((base + delta) clamped ≥ 0, isFollowing ? 1 : 0)`
  — so a stale cached 0 never shows "0 Followers" while the user follows, without
  double-counting a fresh count that already includes them. +6 tests.
- **Tests** — `flutter analyze` 0 errors; **66 unit tests** (playback rollback +
  follower reconciliation). Adversarial review; H1 (confirmed-store) + M2
  (duration) fixed. **Audible playback still requires manual on-device QA.**

### Phase 3.3.1 — Catalog integration stabilization (2026-07-27)

Regression-fix phase after Phase 3.3, addressing **four defects confirmed on a
real Android device** (Phase 3.3's API-only smoke tests had not exercised the
runtime paths). No new features; UI and the YouTube IFrame playback engine
preserved. **No schema/DB change** (verified read-only: artwork cached, follower
triggers intact, the affected tracks aren't in the normalized catalog).

- **Fixed — compact artist artwork (§1).** Home circles for followed artists
  (Young Miko, Skrillex) showed the placeholder while the full Artist screen
  showed a photo. Root cause: cloud hydration **skipped** already-followed
  artists, so a Hive entry stored with an empty `picture` (followed before its
  catalog row had an image) was never refreshed. Hydration now **upserts** every
  followed row's resolved artwork + uuid (self-healing on next launch, never
  regressing a good picture). `ArtworkResolver` gains the full §1 priority
  (cached → original → picture_xl → picture_big → picture_medium → picture) and
  treats malformed/`"null"`/non-URL values as absent.
- **Fixed — cold artist load > 40 s (§2).** `getArtist` awaited the legacy
  `/v2/artist/{id}` call, which eagerly YouTube-matches up to 50 top tracks
  (tens of seconds), blocking the Artist Detail global spinner. It now returns
  the fast normalized **core** only (bounded 12 s); top tracks + related artists
  load as a **background section** via `getArtistExtras` (bounded 30 s). Backend
  caps the eager match to a bounded head (`HYBRID_ARTIST_TOP_MATCH_LIMIT`,
  default 15, 12 s each). Legacy fallback is now also bounded (15 s).
- **Fixed — follow/unfollow from Related Artists (§3).** Following an artist
  opened from another's Related list (Drake → Travis Scott) didn't move the
  count. Root cause: the cold artist fell back to legacy, leaving
  `platformFollowers` null, and the pill then showed the static Deezer **fan**
  count and ignored the follow delta. The pill now **always** uses Paax follower
  semantics + the in-session delta (never Deezer fans; seeds from local follow
  state when the platform count is unknown), so following moves 0→1 regardless
  of catalog warmth. The faster core also makes the count reliably available.
- **Fixed — playback display/audio desync (§4).** Tapping some tracks
  (JACKBOYS 2 "CHAMPAIN & VAC…") switched the UI to the new track as "playing"
  while the previous song kept playing. Root cause: `Track.id` **is** the
  videoId and can be empty; `currentTrack` was committed before `load()`, which
  silently no-op'd on an empty id, and iframe `onError` was only logged. New
  **play-transaction state machine**: validate the id, commit the new track only
  after the iframe accepts it (buffering/playing/cued) for the current
  generation, restore/re-cue the previous track on failure, ignore stale
  callbacks, auto-advance past unplayable tracks, and show the safe "Unable to
  play this track" with retry. The IFrame engine and eager videoId resolution
  are unchanged. **Audible playback still requires manual on-device QA** — it
  can't be verified headless.
- **Fixed — search loading truthfulness (§5).** The global spinner no longer
  hides cached/partial results; a cache-miss query clears stale results so the
  previous query's hits never render under new text.
- **Tests** — frontend +9 playback-transaction + expanded artwork fixtures
  (54 unit total); backend 95 pytest. `flutter analyze` 0 errors. Adversarial
  review; all medium findings fixed.

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
