# Glossary

> **Purpose**: Canonical definitions of the domain, architecture, and project-specific terms used throughout the documentation and code. When a doc uses one of these terms, it means exactly what is written here.
> **Update when**: A new term of art is introduced, or a definition changes.

Terms are grouped by area. Cross-references point to the doc that owns the full detail.

---

## Product & catalog

| Term | Definition |
|------|------------|
| **Paax** | The product/brand — a cross-platform (Android + Web/PWA/TWA) music app. |
| **beaty** | The Flutter **package name** (`pubspec.yaml`) and legacy brand. Imports are `package:beaty/…`; Android `applicationId` is `com.beaty.music.beaty`. Being migrated to Paax. |
| **Deezer** | Third-party source of **catalog metadata** (artists/albums/tracks/cover art) via the keyless public API `api.deezer.com`. The "what to show." See [tech-stack.md](tech-stack.md). |
| **YouTube / videoId** | Third-party source of **audio**. A `videoId` is an 11-char YouTube identifier; Paax matches each Deezer track to one and plays it. The "what to play." |
| **Innertube** | YouTube's internal player API (`youtubei/v1/player`) used by the [Cloudflare Worker](#components) to resolve a direct CDN stream URL. |
| **LRCLIB** | Third-party lyrics source (`lrclib.net`), primary provider for synced/plain lyrics. See [api.md](api.md#endpoints--lyrics). |

## Architecture & components {#components}

| Term | Definition |
|------|------------|
| **paax-api** | The metadata/discovery API the app calls. Deezer metadata + YouTube playback matching. `api.paaxmusic.app`. See [api.md](api.md), [backend/services.md](backend/services.md). |
| **paax-stream** | An IPv6-rotating audio **byte proxy** (`resolver.paaxmusic.app`). Deployed but **not on the live playback path**. See [backend/workers.md](backend/workers.md). |
| **Cloudflare Worker** | Edge **stream-URL resolver** (`stream.paaxmusic.app`) using Innertube. A parallel streaming generation. See [backend/workers.md](backend/workers.md). |
| **legacy backend** | The original FastAPI monolith (`backend/`, "Beaty …") doing ytmusicapi metadata + yt-dlp streaming. **Superseded** by paax-api. See [decisions.md](decisions.md#adr-001). |
| **hybrid "v2" pipeline** | paax-api's core flow: fetch Deezer metadata, match each track to a YouTube `videoId`, return both. Endpoints are prefixed `/v2/`. See [api.md](api.md). |
| **`playback` block** | The JSON object attached to every v2 track: `{provider, engine, videoId, matchConfidence, matchStatus, matchReason}`. The client sets `Track.id = playback.videoId`. |
| **v1 (legacy) endpoints** | paax-api's unprefixed ytmusicapi-backed endpoints, kept for compatibility. See [api.md](api.md#endpoints--paax-api-v1-legacy-ytmusicapi). |

## Playback

| Term | Definition |
|------|------------|
| **IFrame playback** | The **live** audio path: the matched `videoId` plays in an embedded YouTube IFrame — mobile via `flutter_inappwebview`, web via `youtube_player_iframe`. **Not** `just_audio`. See [features/player.md](features/player.md). |
| **PlaybackEngine** | The abstract Dart interface (`core/playback/`) with a platform factory returning the IFrame implementation. Isolates "how sound is made." |
| **PlaybackController** | The `ChangeNotifier` that owns the queue, current index, shuffle/loop, and transport logic — the UI's source of truth for playback. |
| **PaaxAudioHandler** | The `audio_service` handler that runs the Android **foreground service** and OS media session. It **does not play audio**; it keeps the WebView alive and shows the notification. |
| **PaaxBridge** | The JS↔Dart channel between the WebView's YouTube IFrame and the Dart engine. |
| **HiddenVideoPlayer** | A 300×300 offscreen `InAppWebView` mounted in the app's root stack that hosts the audio engine so navigation never disposes it. |
| **matchStatus / matchConfidence** | Outcome of YouTube matching: `matched` (confidence ≥ 0.5), `low_confidence`, `failed`, `timeout`, or `pending`. See [backend/services.md](backend/services.md). |

## Client state & data

| Term | Definition |
|------|------------|
| **Hive** | The embedded, on-device, key-value store that is Paax's **only** user datastore. There is no server database. See [database.md](database.md). |
| **Box** | A Hive collection (the analog of a table), e.g. `liked_tracks`, `playlists`, `saved_albums`. |
| **`@HiveType` / `@HiveField`** | Annotations defining the on-disk wire format. `typeId` and field indices are permanent — **never renumber** them. See [database.md](database.md#naming-conventions). |
| **Provider + ChangeNotifier** | The state-management approach (via the `provider` package). Mutable controllers, not Riverpod/Bloc/freezed. See [frontend/state-management.md](frontend/state-management.md), [decisions.md](decisions.md#adr-003). |
| **MainWrapper / shellKey** | The app shell: an `IndexedStack` of four tab `Navigator`s, controlled app-wide through the static `MainWrapper.shellKey`. The full player is an overlay, not a route. See [frontend/navigation.md](frontend/navigation.md). |
| **MusicRepository / MusicRepositoryImpl** | The client-side interface + implementation that maps paax-api responses to domain entities (`data/repositories/`). |
| **demo auth** | The current login: hardcoded `user@gmail.com` / `12345`, always-succeed signup, local `UserProfile`. Not real authentication. See [features/authentication.md](features/authentication.md). |

## Design & UI

| Term | Definition |
|------|------------|
| **Cinematic black / "liquid glass"** | The dark-only visual language. Despite the "glass" name, runtime `BackdropFilter` blur is **disabled** everywhere except the full player; depth is simulated with solid dark surfaces, gradient edge fades, and static blurred-artwork headers. See [design/design-system.md](design/design-system.md), [decisions.md](decisions.md#adr-007). |
| **DominantColorService / CinematicColor** | Extracts an adaptive color from artwork to tint chrome/contrast; feeds `ThemeState`. |
| **DynamicBackground** | A `RouteAware` widget implementing live album-color backgrounds. Implemented but **currently dormant** (not mounted by any screen). |
| **`Lh3UrlBuilder` / image throttling** | The layer that sizes image URLs and spreads/queues requests to survive Google/Deezer **HTTP 429** rate limits. See [performance.md](performance.md), [decisions.md](decisions.md#adr-005). |

## Infrastructure

| Term | Definition |
|------|------------|
| **Railway** | Host for the three Python services (NIXPACKS builder). See [deployment.md](deployment.md). |
| **Cloudflare** | Edge host for the Worker + DNS/CDN for `*.paaxmusic.app`. |
| **PWA / TWA** | Progressive Web App / Trusted Web Activity — the web build doubles as an installable app and an Android wrapper (`assetlinks.json` + service worker). |
| **NIXPACKS** | Railway's zero-config builder that turns each service's `requirements.txt` + start command into a deploy. |
| **`YTMUSIC_OAUTH_JSON`** | Env var holding a single shared YouTube Music OAuth credential for paax-api's authenticated ytmusicapi endpoints. Not per-user. See [environment.md](environment.md), [security.md](security.md). |

## Status labels used in these docs

| Label | Meaning |
|-------|---------|
| **dormant** | Implemented but not currently wired/mounted (e.g. `DynamicBackground`). |
| **orphaned / dead** | Present in the repo but unreferenced/unrunnable (e.g. `deezer_api_client.dart`, the paax-stream resolver stack). |
| **superseded** | Replaced by a newer component but still present (e.g. legacy `backend`). |
| **stub / not implemented** | A placeholder or missing feature (e.g. Settings, downloads, offline, push notifications). |
| **aspirational** | Described by the rules/templates but not built (e.g. Supabase/Postgres, the test suite). |

See [AI_NOTES.md](AI_NOTES.md) for the full inventory of dormant/dead/superseded items.

---

*Last updated: 2026-07-16*
