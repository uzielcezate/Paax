# Ideas

> **Purpose**: An unconstrained space to capture raw ideas, experiments, and speculative concepts that aren't ready to be feature requests. No filtering — quantity over quality here. Ideas can be rough, half-formed, or aspirational.
> **Update when**: Anytime. Add ideas immediately before they're forgotten. Review and prune during planning sessions.

---

## How to Use This File

- Add ideas without judgment — even half-formed ones.
- Tag each idea with a category and maturity level.
- During planning, promote good ideas to `FEATURE_REQUESTS.md` or the backlog.
- Mark dead ideas as `💀 Discarded` with a brief reason.
- Review this file at the start of every new planning cycle.

---

## Maturity Levels

| Tag | Meaning |
|-----|---------|
| 💭 Raw | Just a thought, needs more exploration |
| 🌱 Seedling | Has some shape, worth exploring |
| 🔬 Hypothesis | Has a clear premise, ready to validate |
| 🚀 Ready | Fleshed out enough to become a feature request |
| 💀 Discarded | Explored and decided against |

---

## Categories

`UX` · `Feature` · `Performance` · `Infrastructure` · `Monetization` · `AI/ML` · `Integration` · `DevEx` · `Security` · `Data`

---

## Active Ideas

---

### IDEA-001 — Adopt a real design-token / spacing scale

**Category**: UX / DevEx
**Maturity**: 🚀 Ready
**Added by**: Documentation pass
**Date**: 2026-07-16

Today the theme has `AppColors` + `BeatyGlassTokens`, but spacing is **ad-hoc numeric literals** everywhere and there is no central text/spacing scale (the `.claude/rules/ui.md` 4px-base scale is not implemented). Introduce a `Spacing` (4/8/12/16/24/32/48/64) and typography scale, then migrate literals. Reduces inconsistency and makes global tuning trivial. Relates to [tech debt](TECH_DEBT.md) (ad-hoc spacing) and [`.claude/rules/ui.md`](../.claude/rules/ui.md).

---

### IDEA-002 — Consolidate the two image-cache generations

**Category**: Performance / DevEx
**Maturity**: 🚀 Ready
**Added by**: Documentation pass
**Date**: 2026-07-16

`core/image/*` and `core/network/*` are two overlapping generations of image loading/throttling (`ImageRequestQueue` + `HostThrottleState` + `Lh3UrlBuilder` + `ImagePipeline` vs `ThrottledHttpClient` + `ImageLoadQueue`). Merge into one canonical pipeline routed through `app_image.dart`; delete the legacy variants (`network_image_with_fallback`, `smart_network_image`, `queued_network_image`, deprecated `thumbnail_prefetcher`). Reduces the surface that fights HTTP 429. See [known issues](KNOWN_ISSUES.md) ISSUE-008 and [optimization log](OPTIMIZATION_LOG.md) OPT-002.

---

### IDEA-003 — Same-origin image proxy to kill 429s at the source

**Category**: Infrastructure / Performance
**Maturity**: 🔬 Hypothesis
**Added by**: Documentation pass
**Date**: 2026-07-16

Rather than fighting `lh3-lh6.googleusercontent.com` / Deezer 429s on the client, proxy+cache artwork through our own edge (Cloudflare) with a long TTL and one hostname. Web would then load from a friendly origin with a warm cache, removing the biggest source of image flakiness on the web build. Trade-off: bandwidth cost + another moving part.

---

### IDEA-004 — Real signing config + final Paax `applicationId`

**Category**: Infrastructure / Security
**Maturity**: 🚀 Ready
**Added by**: Documentation pass
**Date**: 2026-07-16

Release currently signs with **debug keys** and `applicationId` is still `com.beaty.music.beaty`. Create a real keystore + `signingConfigs.release`, decide the final `app.paax…` id, and update `AndroidManifest` label + TWA `assetlinks.json` fingerprints together (these must change as one atomic unit before first publish). See [known issues](KNOWN_ISSUES.md) ISSUE-006/007/010 and [deployment](deployment.md).

---

### IDEA-005 — Add an automated test suite + CI

**Category**: DevEx
**Maturity**: 🚀 Ready
**Added by**: Documentation pass
**Date**: 2026-07-16

There are **zero** automated tests (no `test/` dir; backends have only gitignored probe scripts). Start with the highest-value, lowest-flakiness units: `deezer_mapper` normalization, the YouTube match scorer, Hive dedup migrations, and `MusicRepositoryImpl` v2 mappers; add a couple of widget tests for the player/progress bar. Wire `flutter analyze` + `flutter test` (+ Python `pytest`) into GitHub Actions as a merge gate. See [testing](testing.md) and [`.claude/rules/testing.md`](../.claude/rules/testing.md).

---

### IDEA-006 — Unify streaming: pick Worker vs IPv6 proxy (retire the rest)

**Category**: Infrastructure
**Maturity**: 🔬 Hypothesis
**Added by**: Documentation pass
**Date**: 2026-07-16

There are effectively **four** streaming generations: live YouTube IFrame (in use), Cloudflare Worker Innertube resolver (deployed, unused by app), paax-stream IPv6 byte proxy (deployed, unused by app), and the legacy backend `/stream` (broken). Plus paax-stream's entire orphaned multi-provider `resolve/` pipeline. Decide ONE server-side strategy (Worker for URL resolution vs paax-stream for full byte-proxying), harden it, and delete the others. This is a prerequisite for downloads (FR-001). Record the decision in [decisions](decisions.md). See [architecture](architecture.md).

---

### IDEA-007 — Crossfade / gapless playback

**Category**: Feature / UX
**Maturity**: 🌱 Seedling
**Added by**: Documentation pass
**Date**: 2026-07-16

The player already prefetches the next track (`prefetchNext`, prefetch next 1). Building on that, add crossfade / gapless transitions. Caveat: hard to do well through a YouTube IFrame — may depend on IDEA-006 (a real audio path) to control buffers.

---

### IDEA-008 — Lyrics improvements

**Category**: Feature / UX
**Maturity**: 🌱 Seedling
**Added by**: Documentation pass
**Date**: 2026-07-16

Lyrics already prefer LRCLIB (synced) with a ytmusicapi plain-text fallback, rendered by `synced_lyrics_view` (auto-advance, glow, center-scroll). Extend: tap-a-line-to-seek, translation/romanization, share-a-lyric-snippet, and better fuzzy matching when LRCLIB lacks an exact hit. See [api](api.md) lyrics section.

---

### IDEA-009 — Mount or remove `DynamicBackground`

**Category**: UX
**Maturity**: 🌱 Seedling
**Added by**: Documentation pass
**Date**: 2026-07-16

The Phase-5 "Apple Music-style color environment" driver (`DynamicBackground`, extracts a `CinematicColor` → `ThemeState`) is fully implemented but **mounted by no screen**. Either mount it at the shell level to realize the original vision, or delete it and rely solely on the per-widget `foregroundColor` contrast flow. See [known issues](KNOWN_ISSUES.md) ISSUE-011.

---

### IDEA-010 — Cache hit-rate + performance observability

**Category**: Data / Performance
**Maturity**: 🌱 Seedling
**Added by**: Documentation pass
**Date**: 2026-07-16

There is no metrics pipeline. Aggregate the existing `X-Cache: HIT/MISS` headers (and `X-Provider`/`X-Proxy-IPv6`) into a lightweight dashboard, and capture app cold-start / player-jank baselines with Flutter DevTools. Turns [optimization log](OPTIMIZATION_LOG.md) "no formal metrics captured" into real before/after numbers.

---

### IDEA-011 — Retire the legacy backend and dead client config

**Category**: DevEx
**Maturity**: 🚀 Ready
**Added by**: Documentation pass
**Date**: 2026-07-16

Delete the superseded `backend/` monolith (its `/stream` is broken anyway) and the dead client config/data files (`app_config.dart`, `api_constants.dart`, `deezer_api_client.dart`, `media_session_web.dart`, orphaned `artist_items` screen). Pure subtraction — reduces confusion with no behavior change. See [tech debt](TECH_DEBT.md).

---

## 🚀 Promoted to Feature Requests

| Idea | Feature Request | Promoted On |
|------|----------------|-------------|
| *(none promoted yet — several ideas overlap with existing FRs; see [feature requests](FEATURE_REQUESTS.md))* | — | — |

---

## 💀 Discarded Ideas

| Idea | Title | Reason | Date |
|------|-------|--------|------|
| — | *(none discarded yet)* | — | — |

---

*Last updated: 2026-07-16*
