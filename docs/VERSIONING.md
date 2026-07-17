# Versioning

> **Purpose**: Documents the versioning strategy, release cadence, and version number conventions for all artifacts in this project (app, API, schema, etc.).
> **Update when**: The versioning strategy changes, a new artifact type is added, or the release cadence changes.

---

## Versioning Strategy

This project follows [Semantic Versioning 2.0.0](https://semver.org/):

```
MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]

Examples:
  1.0.0          → First stable release
  1.1.0          → New backward-compatible feature
  1.1.1          → Bug fix
  2.0.0          → Breaking change
  2.0.0-beta.1   → Pre-release version
  2.0.0-rc.1     → Release candidate
```

| Version Part | When to Increment | Examples |
|-------------|-------------------|---------|
| **MAJOR** | Breaking changes — API contract changes, removed features, incompatible behavior | `1.x.x → 2.0.0` |
| **MINOR** | New backward-compatible features | `1.0.x → 1.1.0` |
| **PATCH** | Backward-compatible bug fixes | `1.0.0 → 1.0.1` |

> **Reality check.** SemVer is the *policy*. In practice Paax's history is not yet driven by it: there are **163 commits and exactly one tag, `v0.1-mobile-stable`**, and `pubspec.yaml` sits at `1.0.0+1` (a placeholder, not a shipped 1.0). Release engineering — real tags per release, an automated bump, CI — is aspirational (see [tech debt](TECH_DEBT.md) DEBT-001/002). This document defines where the project is going; the "Current Versions" table records where it actually is.

---

## Current Versions (as of 2026-07-16)

| Artifact | Current | Source of truth |
|----------|---------|-----------------|
| Flutter app | `1.0.0+1` (placeholder) | `frontend/pubspec.yaml` → `version:` (package name `beaty`) |
| Mobile milestone tag | `v0.1-mobile-stable` | Only git tag; marks the mobile-stable checkpoint |
| paax-api | `1.0.0` (FastAPI app title "paax-api" v1.0.0) | `paax-api/main.py` |
| paax-api HTTP namespaces | `v1` (legacy) + `v2` (live) | URL path prefixes `/…` and `/v2/…` |
| paax-stream | `4.0.0` ("Phase 8 Hybrid Proxy") | `paax-stream/app/` app metadata |
| Cloudflare Worker | "v6" (informal, in comments) | `cloudflare-worker/` |
| legacy backend | v1 surface (superseded) | `backend/` — "Beaty YouTube Music Backend" |

---

## What Gets Versioned

| Artifact | Version Location | Scheme |
|----------|-----------------|--------|
| Mobile App (Flutter) | `frontend/pubspec.yaml` → `version:` field | `MAJOR.MINOR.PATCH+BUILD_NUMBER` |
| HTTP API (paax-api) | URL path prefix (`/v1` implicit legacy, `/v2/…`) | Major version only, namespace-in-path |
| Python services | FastAPI app `version=` string (paax-api 1.0.0, paax-stream 4.0.0) | `MAJOR.MINOR.PATCH` (informal) |
| Database schema | **N/A — no server database.** Client state schema is versioned by **Hive `typeId`s** (0–4) + one-time in-`init()` dedup migrations | Hive `typeId` + ad-hoc migration steps |

> **No database schema versioning.** There is no Postgres/Supabase and no migration tool. The closest analog is Hive: each entity has a stable integer `typeId` (Track=0, Playlist=1, SavedAlbum=2, UserProfile=3, Artist=4), and schema evolution is handled by imperative migrations that run once during `HiveStorage.init()` (e.g. dedup liked/recently-played, re-key by id). Adding/removing a persisted field must preserve `typeId` compatibility. See [database](database.md).

---

## Mobile App Versioning

Format: `MAJOR.MINOR.PATCH+BUILD`

- **Version name** (`MAJOR.MINOR.PATCH`): user-visible in stores.
- **Build number** (`BUILD`): integer, must increase on every store upload, never reset.

```yaml
# frontend/pubspec.yaml (current)
version: 1.0.0+1
# 1.0.0 = version name (placeholder — not a shipped 1.0)
# 1     = build number
```

On Android, `versionCode`/`versionName` derive from `local.properties` (defaults 1 / 1.0) via `build.gradle`. Note the two open Android blockers before any real store release: **debug signing** and the **`com.beaty.music.beaty` applicationId** (see [known issues](KNOWN_ISSUES.md) ISSUE-006/007 and [tech debt](TECH_DEBT.md)).

---

## API Versioning

paax-api uses **namespace-in-path** major versioning, and **runs two generations side by side** in the same service:

- **v1** (legacy, ytmusicapi-backed): unprefixed paths — `/search`, `/home`, `/charts`, `/artist/{channelId}`, `/album/{browseId}`, `/lyrics`, `/library/*`, etc.
- **v2** (Deezer + YouTube hybrid, the **live** path): `/v2/*` — `/v2/search`, `/v2/artist/{id}`, `/v2/album/{id}`, `/v2/track/{id}`, `/v2/chart`, `/v2/match`.

Rationale for coexistence rather than a hard cutover: v2 changed the *data source* (Deezer metadata + YouTube match) and the *identifier space* (`/v2/*` uses integer Deezer ids; v1 used YouTube/Innertube ids like `channelId`/`browseId`/`videoId`). They are not drop-in compatible, so v2 was added as a new namespace and the client migrated to it, leaving v1 in place. See [api](api.md).

Divergences from [`.claude/rules/api.md`](../.claude/rules/api.md), stated honestly: there are **no `Deprecation` headers**, no formal 90-day deprecation clock, and no automated contract tests. Treat v1 as "legacy, still mounted, not extended."

---

## Pre-Release Labels

| Label | Meaning | Example |
|-------|---------|---------|
| `alpha` | Internal testing only, unstable | `1.0.0-alpha.1` |
| `beta` | External testing, feature-complete but may have bugs | `1.0.0-beta.3` |
| `rc` | Release candidate, final testing before stable | `1.0.0-rc.1` |

The single existing tag `v0.1-mobile-stable` predates adopting these labels; it functions as an informal milestone marker, not a SemVer pre-release.

---

## Release Cadence

There is no fixed cadence today — development is continuous, merged to `main`, with web/PWA deployed on push (Vercel) and Python services on Railway. Target cadence:

| Release Type | Cadence | Trigger |
|-------------|---------|---------|
| Patch | As needed | Critical bug merged to `main` |
| Minor | When a feature set lands | Feature phase completed (e.g. the Phase 3/4/5 UI arcs) |
| Major | Rare, deliberate | A breaking change (e.g. new API namespace, streaming architecture switch) approved in [decisions](decisions.md) |

---

## Tagging Convention

```bash
# Annotated tag — preferred
git tag -a v1.2.3 -m "Release v1.2.3"
git push origin v1.2.3

# Tag format: v followed by full semver
# v1.0.0, v1.0.0-beta.1, v2.0.0-rc.2
```

Follow the branch/commit conventions in [`.claude/rules/git.md`](../.claude/rules/git.md) and [contributing](CONTRIBUTING.md).

---

## Version Bump Checklist

When creating a new version:

- [ ] Determine the correct bump type (major/minor/patch) per SemVer.
- [ ] Update `frontend/pubspec.yaml` `version:` (bump build number too) and any service `version=` strings.
- [ ] For an API change: decide whether it fits `/v2` or needs a new namespace; never break an existing namespace's contract (see [api](api.md)).
- [ ] Update [`docs/CHANGELOG.md`](CHANGELOG.md) — move `[Unreleased]` into the new version section.
- [ ] Update [`docs/release-notes.md`](release-notes.md) (user-facing).
- [ ] Resolve Android release blockers (real signing, final `applicationId`) before any Play Store build.
- [ ] Create an annotated git tag and push it.

---

*Last updated: 2026-07-16*
