# Project Goals

> **Purpose**: Defines the project's purpose, target users, success criteria, and strategic goals. Every agent should read this before making product decisions. When in doubt about whether to build something, check if it serves the goals here.
> **Update when**: Product strategy shifts, target audience changes, or success metrics are revised.

---

## Mission Statement

> *"Give anyone a free, beautiful, streaming-service-class music player — clean Deezer metadata with YouTube-backed playback — on their phone and in their browser, without a subscription."*

Paax is a cross-platform music streaming **client**. It does not own or license a catalog; it composes two free public sources — **Deezer** for clean metadata (titles, artists, albums, covers, explicitness, track/disc numbers) and **YouTube** for actual audio playback (matched `videoId` played through a YouTube IFrame). See [architecture](architecture.md) and the hybrid pipeline in [api](api.md).

---

## Problem Statement

**Problem**: Polished, ad-free, cross-platform music listening is paywalled. Free tiers are deliberately degraded (ads, shuffle-only, no offline), and the genuinely free source of nearly everything — YouTube — has a player built for video, not for a music library.

**Who has it**: Listeners who want a Spotify/Apple-Music-grade experience (fast search, artist/album pages, playlists, a real full-screen player with synced lyrics) but do not want, or cannot afford, a subscription.

**Why existing solutions fall short**:
- Spotify/Apple Music: excellent UX, but subscription-gated and closed.
- YouTube / YT Music free: the audio is there, but the UX is video-first, ad-heavy, and background playback is restricted.
- Third-party YouTube front-ends: often bare-bones, unstable against YouTube's anti-bot changes, and lacking clean catalog metadata.

Paax's bet is that **Deezer's clean metadata + YouTube's audio, wrapped in a cinematic native-feeling client**, delivers most of the premium experience for free.

---

## Target Users

### Primary User

- **Who**: Music listeners on Android (and modern browsers) who currently tolerate free YouTube/YT Music or cannot justify a paid subscription.
- **Needs**: Fast search, browsable artist/album pages, personal library and playlists, a beautiful full-screen player with synced lyrics, reliable background audio.
- **Pain points**: Ads, subscription cost, video-first UX, no offline on free tiers, clunky library management.

### Secondary User

- **Who**: Web/PWA users who want to install a lightweight music app (`paaxmusic.app`) without going through an app store, plus the maintainer/tinkerer who values a self-hostable, DB-free architecture.
- **Needs**: Installable PWA/TWA, quick cold start, parity with the mobile experience.

---

## Strategic Goals

| # | Goal | Success Metric | Timeline |
|---|------|----------------|----------|
| 1 | Deliver a cinematic, native-feeling client on Android + Web | Smooth 60fps player, instant tab switches, no black-flash transitions; qualitative "feels premium" bar | Ongoing (Phases 3–5 shipped) |
| 2 | Reliable free playback via the Deezer→YouTube hybrid | High match rate (`matchStatus:matched`), background audio survives on Android, playback resilient to YouTube changes | Ongoing (v2 hybrid is live) |
| 3 | Zero-server-cost user data | All library/playlists/settings persist client-side in Hive; backends stay stateless caches | ✅ Achieved (no DB anywhere) |
| 4 | Ship offline downloads | Users can save tracks for offline listening | Planned (not started) |
| 5 | Real per-user accounts + cloud sync | Library syncs across devices behind real auth | Planned (currently a local demo stub) |

---

## Non-Goals

- **Owning or licensing a music catalog.** Paax is a client over Deezer + YouTube; it will not negotiate rights or host audio itself.
- **Being a social network.** No feeds, following-of-users, comments, or sharing-as-a-platform. (Native OS share via `share_plus` is fine; social graph is out.)
- **Music creation / recording / DJ tooling.** Out of scope.
- **A server-side user database right now.** The DB-free, client-owned-state design is intentional (Goal 3). Cloud sync (Goal 5), when built, must not compromise the "works fully offline-of-account" default.
- **iOS, currently.** Targets are Android + Web today; iOS is a future request, not a committed goal (see [feature requests](FEATURE_REQUESTS.md)).

---

## Success Criteria (MVP)

The MVP is considered successful when:

- [x] Users can search (tracks/albums/artists), browse artist/album pages, and play audio — **done** (v2 hybrid).
- [x] Users can build a local library: like tracks, create/edit/pin playlists, save albums, follow artists — **done** (Hive-backed).
- [x] A full-screen player with queue, shuffle/loop, artwork swipe, and synced lyrics exists — **done**.
- [x] The app runs on Android and as an installable Web PWA/TWA — **done**.
- [x] Background audio works on Android — **done** (foreground service + WebView tricks).
- [ ] Offline downloads work — **not started**.
- [ ] Real per-user auth replaces the demo stub — **not started**.

---

## Success Criteria (Long-term)

- [ ] Offline-first: core listening works without a network for saved content.
- [ ] Cross-device library sync behind real authentication.
- [ ] Resilient streaming: a unified, self-healing path against YouTube's anti-bot changes (pick and harden one of the resolver strategies).
- [ ] iOS build reaching parity with Android.
- [ ] Personalized recommendations beyond "For You from recent searches".
- [ ] A real quality bar: automated tests + CI, real signing, consistent Paax branding.

---

## Guiding Principles

1. **Cinematic and fast beats feature-dense.** A gorgeous, 60fps, instant-feeling player is the product's identity (Phases 4–5: liquid glass, dynamic color environments). Polish is a feature.
2. **The user owns their data, locally.** Library and settings live on-device in Hive; no account required to get full value. Sync is additive, never mandatory.
3. **Keep the backends thin and stateless.** Servers are metadata/stream proxies with caches only — no DB, no per-user server state. This keeps hosting cheap and the system easy to reason about.
4. **Compose free sources honestly.** Deezer for metadata, YouTube for audio; be transparent (including in docs) about what is real, dormant, or dead.
5. **Dark, cohesive, accessible.** Dark-only by design, theme-token-driven, adaptive contrast from album art.

---

## Competitive Context

| Competitor | Strength | Our Differentiator |
|-----------|---------|-------------------|
| Spotify | Huge catalog, best-in-class recommendations, mature apps | Free, no subscription; installable PWA without a store; clean Deezer metadata over free YouTube audio |
| Apple Music | Premium UX, lossless, deep ecosystem | Free and cross-platform beyond Apple; cinematic color-environment UI inspired by (not locked to) Apple's aesthetic |
| YouTube Music (free) | The same underlying audio source Paax uses | Music-first UX (not video-first), background audio, clean metadata, personal library and playlists, synced lyrics |
| Third-party YT front-ends | Free access to YouTube audio | Polished native/PWA client, real library management, and a maintained metadata pipeline |

See also [roadmap](roadmap.md), [current-state](current-state.md), and [decisions](decisions.md).

---

*Last updated: 2026-07-16*
