# Release Notes

> **Purpose**: A chronological log of all releases, organized by version. Provides traceability for changes deployed to users. Agents should update this file when preparing or completing a release.
> **Update when**: A new version is released to any environment.

---

## Format

Each release follows [Keep a Changelog](https://keepachangelog.com/) conventions.
Versions follow [Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`.

- **Added**: New features · **Changed**: Existing functionality · **Deprecated**: Scheduled for removal · **Removed** · **Fixed** · **Security**

> **Note on versioning**: The Flutter app is `1.0.0+1` in `pubspec.yaml`, but the only git tag is `v0.1-mobile-stable`. Development has been continuous (163 commits) without formal versioned releases. The entries below reconstruct the trajectory in phases. See [VERSIONING.md](VERSIONING.md) and [CHANGELOG.md](CHANGELOG.md).

---

## Unreleased

### Added
- Full `docs/` documentation set (this pass).

### Changed
- Ongoing "liquid glass" UI polish (slimmer mini player/nav bar, shadow/edge tuning).

### Fixed
- Stale route fades, black-glass artifacts, animation speeds.

---

## Phase 5 — Cinematic Color & Liquid Glass (recent)

### Added
- Dynamic dominant-color "Apple Music-style" backgrounds for artist/album/playlist detail.
- Adaptive contrast (foreground/background derived from artwork via `DominantColorService`).

### Changed
- Removed orange accents; standardized adaptive foregrounds across detail and library screens.
- Flattened dynamic backgrounds to a single solid color; pastel-faithful colors, white Play button, glass secondary buttons.

### Fixed
- Liquid-glass transition artifacts, readability, stale fades, z-order.

---

## Phase 4 — Glass UI System

### Added
- iOS-style glass blur UI system; floating glass navigation (removed traditional top bars).

### Changed
- Lower-opacity glass, fixed double-blur, deeper gradients, stable controls.

---

## Phase 3 — Discography & Playlist Management

### Added
- Artist discography (Latest release / Albums / Singles & EPs) + full discography screen.
- Playlist management: create/rename/delete, drag-to-reorder, pin.
- Full player UI + playback queue with drag-to-reorder.

### Changed
- Enriched artist releases from top tracks via `/album/{id}` fetches.
- Translated UI to English.

### Fixed
- Singles not appearing; playlist Edit-Order/queue-reorder bugs.

---

## v2 — Deezer + YouTube Hybrid Metadata

### Added
- `paax-api` `/v2/*` endpoints: Deezer metadata + YouTube-matched playback IDs (`playback` block).
- Cloudflare Worker Innertube stream resolver; `paax-stream` IPv6 byte proxy (standby).

### Changed
- Metadata source migrated from ytmusicapi-only (`backend`) to the Deezer+YouTube hybrid.

---

## Client-Side Playback & PWA/TWA

### Added
- Client-side YouTube IFrame playback; Web Media Session API.
- Offline-first service worker for TWA cold start; `.well-known/assetlinks.json` (digital asset links); `viewport-fit=cover` for PWA safe areas.

### Fixed
- Mobile playback stability and related UI state issues.

---

## [0.1.0] — Initial (tag `v0.1-mobile-stable`)

> Initial monorepo.

### Added
- Flutter frontend + FastAPI (`ytmusicapi`) backend.
- Redis caching (search/home), environment-based API config, image-caching improvements, Flutter performance optimizations.
- Core browse + playback + Hive library foundation.

---

## Release Checklist

Before tagging a release:

- [ ] `flutter analyze` clean, `dart format` applied
- [ ] [current-state.md](current-state.md) updated
- [ ] [CHANGELOG.md](CHANGELOG.md) "Unreleased" moved to a versioned section
- [ ] Version bumped in `frontend/pubspec.yaml` (+ Android `local.properties`)
- [ ] **Real signing config used** (not debug keys) for Android
- [ ] Env vars verified on target services ([environment.md](environment.md))
- [ ] Git tag created: `git tag -a vX.Y.Z -m "Release vX.Y.Z"`

---

*Last updated: 2026-07-16*
