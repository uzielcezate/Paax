# In Progress

> **Purpose**: Tracks tasks that are actively being worked on. A task should be here from when work begins until it is merged and verified.
> **Update when**: A task is started (move from `backlog.md`), updated with progress, or completed (move to `completed.md`).

---

## Reading Note

Paax is a single-maintainer project, so "in progress" means the threads with recent commits or partially-landed work — not tickets assigned across a team. The **Assignee** column is always the solo maintainer (uzielcezate). For finished work see [`completed.md`](completed.md); for what has not been started see [`backlog.md`](backlog.md); for the debt these threads are paying down see [`../TECH_DEBT.md`](../TECH_DEBT.md); and for where they lead see [`../roadmap.md`](../roadmap.md) and [`../current-state.md`](../current-state.md).

> **Supabase status (2026-07-16)**: Phase 1 (foundation) is **complete** — see [`completed.md`](completed.md) TASK-C15 and ADR-009. Phase 2 (backend ingestion/jobs) is **not started** and lives in [`backlog.md`](backlog.md) (TASK-B14…B21); it is not listed below because no integration work is actively in progress.

---

## Active Tasks

---

### TASK-IP01 — Branding migration: Beaty → Paax

**Type**: Chore (rebrand)
**Priority**: Medium
**Assignee**: Solo maintainer (uzielcezate)
**Started**: Phase 6 (ongoing)
**Target Completion**: Before first public release cut
**Branch**: `main` (incremental, no dedicated branch)

**Status Update**:
> 2026-07-16 — Product/brand is now "Paax" across UI, API hostnames (`paaxmusic.app`, `api.paaxmusic.app`), and service names. The Flutter package is still `beaty` and several `beaty`/`com.beaty.music.beaty` identifiers remain in native config and internal token names. This is deliberately deferred because renaming the Android `applicationId` after any Play Store / TWA install would break update continuity and Digital Asset Links, so it must be sequenced with the release-signing work.

**Progress**:
- [x] Brand name, copy, and product identity switched to Paax
- [x] Production hostnames migrated to `paaxmusic.app`
- [x] Service directories renamed (`paax-api`, `paax-stream`)
- [/] Internal token/class names still carry `Beaty` (e.g. `BeatyGlassTokens`, `PaaxAudioHandler` alongside legacy names)
- [ ] Android `applicationId` still `com.beaty.music.beaty` (`frontend/android/app/build.gradle`)
- [ ] Android manifest `label` still `beaty`
- [ ] Flutter package name still `beaty` in `pubspec.yaml`

**Blockers**:
- `applicationId` rename is coupled to release signing + TWA `assetlinks.json` — cannot land in isolation without breaking install/update identity. See [`backlog.md`](backlog.md) TASK-B04 (release signing).

**Notes**:
Low functional risk, medium coordination risk. Safe to finish the cosmetic renames (labels, internal class names) now; the `applicationId` change is a one-shot that should ride with the release-signing change.

---

### TASK-IP02 — Liquid-glass UI polish

**Type**: Feature (design system refinement)
**Priority**: Medium
**Assignee**: Solo maintainer (uzielcezate)
**Started**: Phase 5 (continuous)
**Target Completion**: Rolling — no fixed date
**Branch**: `main` (incremental)

**Status Update**:
> 2026-07-16 — This is the most recently active thread. The last several commits (`224eb0f` match OC Liquid Glass reference settings + fix shadow artifacts, `4293f28` partial glass rim lightband / slimmer mini player & nav bar, `c7c282c` final liquid glass edge & shadow depth polish, `a10dc8f` fix stale fades / black glass artifacts / animation speeds, `d546d6f` fix transition artifact & readability) are all edge, rim, shadow, and fade tuning on the Cinematic Black glass system. Real `BackdropFilter` blur remains disabled everywhere except the full player; "glass" is simulated with solid `#111` surfaces + hairline borders + gradient edge fades.

**Progress**:
- [x] Cinematic Black surface treatment (solid glass, blur disabled)
- [x] Slimmer mini player (67px) and nav bar
- [x] Shadow-artifact and stale-fade fixes across surfaces
- [/] Rim/lightband and edge-depth tuning (matching an external "OC Liquid Glass" reference)
- [ ] Decide the fate of `DynamicBackground` (implemented, RouteAware, but mounted by no screen — either wire it in or remove it)

**Blockers**:
- None (pure client-side visual work).

**Blast radius**:
Touches many screens/widgets simultaneously (`glass_surface.dart`, `black_glass_blur_surface.dart`, `dynamic_background.dart`, most screen files, theme). Because there is near-zero automated test coverage, each pass is verified manually via `flutter analyze` + on-device inspection. See [`backlog.md`](backlog.md) TASK-B08 (test suite).

**Notes**:
Open design debt: no central spacing scale or design-token file beyond `AppColors` + `BeatyGlassTokens`, so spacing is ad-hoc numeric literals — a source of the "stale fade / artifact" fixes. Tokenizing spacing (backlog TASK-B10) would reduce future polish churn.

---

### TASK-IP03 — Consolidate the streaming approach

**Type**: Refactor / Architecture decision
**Priority**: High
**Assignee**: Solo maintainer (uzielcezate)
**Started**: Phase 8 (open question)
**Target Completion**: Undecided — pending a decision
**Branch**: TBD

**Status Update**:
> 2026-07-16 — Three streaming generations currently coexist, and the live app uses **none** of the server-side resolvers: it plays the `videoId` directly through the YouTube IFrame. `ApiConfig.streamBaseUrl` and `MusicRepository.getStreamUrl` (`/stream/{videoId}`) are defined but unused. The open work is to pick a single strategy and delete the rest.

**The three generations**:
1. **YouTube IFrame direct** — the live path (mobile `flutter_inappwebview`, web `youtube_player_iframe`). Simple, no server byte cost, but constrained by IFrame behavior and harder to control quality/seek.
2. **Cloudflare Worker** (`stream.paaxmusic.app`) — deployed, Innertube → direct CDN URL (itag 140). Cheap edge compute, but bare CDN URLs get bot-blocked from datacenter IPs.
3. **paax-stream IPv6 proxy** (`resolver.paaxmusic.app`) — deployed, proxies bytes through rotating IPv6 sources with sticky fingerprints. Robust against bot-blocking, but pays full egress bandwidth and operational complexity.

**Progress**:
- [x] All three generations exist and (except the legacy `backend/` resolver) are deployed/working
- [/] Evaluating IFrame-direct vs Worker+proxy (quality, seek control, cost, block-resilience)
- [ ] Choose one path of record
- [ ] Wire the chosen resolver into playback **or** commit to IFrame-only and remove `getStreamUrl`/`streamBaseUrl`
- [ ] Delete the orphaned `paax-stream/resolve/` provider pipeline (dead: not mounted, imports missing modules, `yt_dlp` absent from requirements)
- [ ] Retire the broken legacy `backend/` resolver (`_FORMAT_FALLBACKS` NameError)

**Blockers**:
- Decision blocker, not a technical one: the tradeoff is playback control/quality (proxy) vs. cost/simplicity (IFrame). Needs a real listening-quality + cost comparison.

**Notes**:
This is the highest-leverage cleanup on the board — see [`../TECH_DEBT.md`](../TECH_DEBT.md) "streaming generations" and [`backlog.md`](backlog.md) TASK-B07 (wire/remove stream resolver). Until resolved, dead streaming code inflates surface area and confuses onboarding.

---

## Waiting / Blocked

| Task ID | Title | Blocker | Waiting On |
|---------|-------|---------|------------|
| TASK-IP01 | Android `applicationId` rename | Coupled to release signing + TWA asset links | Solo maintainer (sequence with release work) |
| TASK-IP03 | Streaming path decision | Needs quality/cost comparison before committing | Solo maintainer (decision) |

---

## Review / QA

> No formal PR review process — solo maintainer commits to `main`. "QA" is `flutter analyze` + `dart format` + manual on-device verification (see [`../TECH_DEBT.md`](../TECH_DEBT.md), near-zero automated coverage).

| Task ID | Title | PR Link | Reviewer |
|---------|-------|---------|----------|
| TASK-IP02 | Liquid-glass polish | n/a (direct to `main`) | Self (manual on-device) |

---

*Last updated: 2026-07-16*
