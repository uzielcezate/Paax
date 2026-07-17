# Feature Requests

> **Purpose**: Tracks requested features from users, stakeholders, and team members that have not yet been formally planned or added to the backlog. A staging area for ideas before they become tasks.
> **Update when**: A new feature request arrives, a request is promoted to the backlog, a request is rejected (with reason), or a request is merged into another.

---

## How to Add a Request

1. Copy the template below.
2. Assign the next sequential `FR-XXX` number.
3. Place it in the appropriate priority section.
4. When a request is moved to the formal backlog, mark it `📌 Promoted`.
5. When rejected, mark it `❌ Rejected` with a reason.

> The requests below are **seeded from the current state of the codebase** on 2026-07-16 — each corresponds to a visible stub, dormant capability, or an explicit gap versus [project goals](PROJECT_GOALS.md). They are marked `📋 New` / `Requested`. See also [tasks](TASKS.md), [tech debt](TECH_DEBT.md), and [ideas](IDEAS.md).

---

## Request Template

```markdown
### FR-XXX — <Title>

**Status**: 📋 New | 📌 Promoted | 🔄 In Discussion | ❌ Rejected | ✅ Shipped
**Requested by**: <!-- User, stakeholder, or team member -->
**Date**: YYYY-MM-DD
**Priority Vote**: 🔥 High demand / 🟡 Some interest / 🟢 Nice to have

**Description**:
**User Story**:
> As a <type of user>, I want <some goal> so that <some reason>.
**Acceptance Criteria** (draft):
**Notes**:
```

---

## 🔥 High Demand

### FR-001 — Functional offline downloads

**Status**: 📋 New (Requested)
**Requested by**: Product (implied by [project goals](PROJECT_GOALS.md) Goal 4)
**Date**: 2026-07-16
**Priority Vote**: 🔥 High demand

**Description**: Let users download tracks for offline listening. Today there is no download capability; `previewUrl` exists on `Track` but nothing persists audio for offline use, and playback is a live YouTube IFrame.

**User Story**:
> As a listener on a commute with no signal, I want to save tracks for offline playback so that I can listen without a network.

**Acceptance Criteria** (draft):
- Download queue with progress + per-track state (queued/downloading/done/failed).
- Offline library section; offline tracks playable without network.
- Storage management (see downloaded size, delete downloads).

**Notes**: Non-trivial — the live playback path is a YouTube IFrame, not a file player. Real downloads likely require a resolver (paax-stream/Worker) to fetch audio bytes and a local file-based player, a substantial architectural change. Relates to FR-007. See [architecture](architecture.md), [known issues](KNOWN_ISSUES.md).

---

### FR-002 — Real per-user authentication + cloud library sync

**Status**: 📋 New (Requested)
**Requested by**: Product ([project goals](PROJECT_GOALS.md) Goal 5)
**Date**: 2026-07-16
**Priority Vote**: 🔥 High demand

**Description**: Replace the local demo-auth stub (`AuthController` hardcodes `user@gmail.com`/`12345`, `signup` always succeeds, profile stored in Hive) with real accounts, and sync the Hive-held library/playlists across devices.

**User Story**:
> As a user with a phone and a laptop, I want to log in and see the same library everywhere so that my music follows me.

**Acceptance Criteria** (draft):
- Real signup/login with a token-based session.
- Server-side (or third-party) storage of library/playlists behind per-user auth.
- Conflict resolution / merge for offline edits; "works without account" remains the default.

**Notes**: Directly addresses [known issues](KNOWN_ISSUES.md) ISSUE-003 (no per-user auth on write endpoints). Must not force accounts (see [project goals](PROJECT_GOALS.md) Non-Goals). See [security](security.md).

---

## 🟡 Under Consideration

### FR-003 — Working Settings screen

**Status**: 📋 New (Requested)
**Requested by**: Users (implied)
**Date**: 2026-07-16
**Priority Vote**: 🟡 Some interest

**Description**: There is no real settings surface. Provide audio/quality preferences, cache/storage controls, data management (currently only "clear data" on Profile), and playback options.

**User Story**:
> As a user, I want a settings screen so that I can manage storage, playback, and my data.

**Acceptance Criteria** (draft): a Settings screen reachable from Profile with at least storage/cache controls, playback prefs, and about/version info.

**Notes**: Ties into FR-001 (downloads storage) and versioning display.

---

### FR-004 — Wire a server-side streaming path into playback

**Status**: 📋 New (Requested)
**Requested by**: Engineering (implied by dormant infra)
**Date**: 2026-07-16
**Priority Vote**: 🟡 Some interest

**Description**: The app currently plays `videoId` directly via the YouTube IFrame; `ApiConfig.streamBaseUrl` / `getStreamUrl` are defined but unused. Two server resolvers exist and are unused by the live app: the **Cloudflare Worker** (`stream.paaxmusic.app`, Innertube) and **paax-stream** (`resolver.paaxmusic.app`, IPv6 byte proxy). Consider adopting one for a more controllable playback path (and as a prerequisite for downloads).

**User Story**:
> As the team, we want a first-party streaming path so that playback is more resilient and downloadable.

**Acceptance Criteria** (draft): the app can play a real audio stream (not just the IFrame) via a chosen resolver, with graceful fallback; a decision recorded in [decisions](decisions.md).

**Notes**: Must pick ONE strategy (see [ideas](IDEAS.md) "unify streaming"). Enables FR-001. See [architecture](architecture.md).

---

### FR-005 — Personalized recommendations

**Status**: 📋 New (Requested)
**Requested by**: Product ([project goals](PROJECT_GOALS.md) long-term)
**Date**: 2026-07-16
**Priority Vote**: 🟡 Some interest

**Description**: Home's "For You" is currently derived from recent searches. Build genuine personalization (based on listening history / library, which already lives in Hive).

**User Story**:
> As a listener, I want recommendations based on what I actually play so that I discover music I'll like.

**Acceptance Criteria** (draft): a recommendations rail driven by play history/library, refreshed periodically.

**Notes**: History (`recently_played`) and library already exist locally, so a client-side heuristic is feasible without a server.

---

### FR-006 — Push notifications

**Status**: 📋 New (Requested)
**Requested by**: Product (implied)
**Date**: 2026-07-16
**Priority Vote**: 🟡 Some interest

**Description**: New-release alerts for followed artists, and re-engagement notifications.

**User Story**:
> As a fan, I want to be notified when an artist I follow releases something so that I don't miss it.

**Acceptance Criteria** (draft): opt-in notifications, delayed until after the user experiences value (per [`.claude/rules/ux.md`](../.claude/rules/ux.md)).

**Notes**: Requires a server component to detect releases and deliver pushes — depends on FR-002-style infrastructure.

---

## 🟢 Nice to Have

### FR-007 — iOS build

**Status**: 📋 New (Requested)
**Requested by**: Users (implied)
**Date**: 2026-07-16
**Priority Vote**: 🟢 Nice to have

**Description**: Ship an iOS build reaching parity with Android. Currently targets are Android + Web only; there is no iOS project/signing.

**User Story**:
> As an iPhone user, I want Paax on iOS so that I can use it too.

**Acceptance Criteria** (draft): an iOS build with working background audio and the same feature set as Android.

**Notes**: Background-audio-via-WebView will need an iOS-specific approach; App Store review of a YouTube-backed client is a risk. Explicitly a future item per [project goals](PROJECT_GOALS.md) Non-Goals.

---

## 📌 Promoted to Backlog

| FR # | Title | Backlog Task | Promoted On |
|------|-------|-------------|-------------|
| — | *(none promoted yet)* | — | — |

---

## ❌ Rejected

| FR # | Title | Reason | Date |
|------|-------|--------|------|
| — | *(none rejected yet)* | — | — |

---

## ✅ Shipped

| FR # | Title | Version | Date |
|------|-------|---------|------|
| — | *(track here as requests ship)* | — | — |

---

*Last updated: 2026-07-16*
