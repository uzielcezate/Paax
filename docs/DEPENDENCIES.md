# Dependencies

> **Purpose**: A complete inventory of all direct dependencies across all packages in this project. Documents why each dependency was chosen, its health status, and update notes. Agents must update this file when adding or removing dependencies.
> **Update when**: A dependency is added, removed, or has a major version upgrade.

---

## Dependency Policy

- Every dependency must have a documented reason for inclusion.
- Prefer dependencies with active maintenance, high download counts, and open-source licenses.
- Audit all dependencies for known vulnerabilities on a regular schedule.
- Pin major versions. Use patch/minor auto-updates via Dependabot or Renovate.
- Before adding a new dependency, ask: "Can we implement this ourselves in < 2 hours?"

> **Reality check.** Automated dependency tooling (Dependabot/Renovate) is **not configured** in this repo, and there is no CI vulnerability gate. Audits are manual. This is documented honestly in [tech debt](TECH_DEBT.md); the policy above is the target, not the current state.

---

## Dependency Health Ratings

| Rating | Meaning |
|--------|---------|
| ✅ Healthy | Actively maintained, no known critical issues |
| ⚠️ Watch | Maintenance slowing, known issues, or vulnerability present |
| ❌ Replace | Unmaintained, deprecated, or has critical vulnerability |

---

## Frontend / Mobile Dependencies

Source: `frontend/pubspec.yaml`. Flutter package name is `beaty` (legacy), version `1.0.0+1`, Dart SDK `>=3.3`. The app targets **Android + Web (PWA/TWA)**. See [tech-stack](tech-stack.md) and the Flutter architecture in [architecture](architecture.md).

| Package | Version | Purpose | Health | Notes |
|---------|---------|---------|--------|-------|
| `provider` | ^6.1.5 | State management (ChangeNotifier) | ✅ | The app uses **Provider + ChangeNotifier**, NOT Riverpod/Bloc. 5 global controllers in a `MultiProvider`. |
| `hive` | ^2.2.3 | Local persistent store (the real "database") | ✅ | 5 typed adapters + untyped boxes. All user state lives here. See [database](database.md). |
| `hive_flutter` | ^1.1.0 | Hive Flutter bindings (`initFlutter`) | ✅ | — |
| `youtube_player_iframe` | ^5.1.0 | **Web** playback engine (YouTube IFrame) | ✅ | Web path only; mobile uses `flutter_inappwebview` instead. |
| `flutter_inappwebview` | ^6.1.5 | **Mobile** playback engine + hidden WebView host | ✅ | Chosen over `webview_flutter` for `allowBackgroundAudioPlaying:true`. Runs the YouTube iframe_api with background-audio tricks. |
| `audio_service` | ^0.18.18 | OS media session / foreground service | ✅ | `PaaxAudioHandler` keeps the Android foreground service alive so the WebView is not killed; it does NOT play audio itself. |
| `cached_network_image` | ^3.4.0 | Mobile disk image caching | ✅ | Mobile image path; pulls in `flutter_cache_manager` transitively. |
| `palette_generator` | ^0.3.3 | Extract dominant album-art color | ✅ | Feeds `DominantColorService` → `ThemeState` ambient colors. |
| `google_fonts` | ^8.0.2 | Font loading (Roboto locked globally) | ✅ | Roboto is force-locked to defeat OEM font overrides (code comment says Manrope but uses Roboto). |
| `flutter_svg` | ^2.0.17 | SVG icons (Home/Search nav) | ✅ | — |
| `shimmer` | ^3.0.0 | Loading skeletons | ✅ | — |
| `visibility_detector` | ^0.4.0 | Gate image loads to on-screen widgets | ✅ | Core of the 429 image-throttling defense; see [performance](performance.md). |
| `rxdart` | ^0.28.0 | Stream combinators for playback | ✅ | Used around `PlaybackEngine` streams. |
| `share_plus` | ^13.1.0 | Native share sheet (overflow menus) | ✅ | — |
| `path_provider` | ^2.1.4 | Filesystem paths (Hive/cache dirs) | ✅ | — |
| `intl` | ^0.20.2 | Number/date formatting | ✅ | — |
| `web` | ^1.1.1 | Web platform interop | ✅ | Web build only. |
| `cupertino_icons` | ^1.0.6 | iOS-style icon set | ✅ | — |

### Dev Dependencies (Mobile)

| Package | Purpose |
|---------|---------|
| `flutter_lints` ^6.0.0 | Lint rules — the primary quality gate (`flutter analyze`) |
| `build_runner` ^2.4.9 | Code generation runner (for Hive adapters) |
| `hive_generator` ^2.0.1 | Generates Hive `TypeAdapter`s (`*.g.dart`) |
| `flutter_test` (SDK) | Widget/unit test framework — **currently unused** (no `test/` dir; see [testing](testing.md)) |

### Commonly-assumed libraries that Paax does NOT use

Templates and `.claude/rules/*` assume a different stack. To prevent wrong-track work, the following are **explicitly absent** from `pubspec.yaml`:

- **`just_audio`** — no. Playback is a YouTube IFrame inside a WebView, not a native audio player. Only a stale factory comment references it.
- **`riverpod` / `bloc` / `freezed`** — no. State is Provider + mutable `ChangeNotifier`.
- **`go_router` / `auto_route`** — no. Navigation is manual `Navigator` + a custom `IndexedStack` shell with per-tab nested navigators.
- **`supabase_flutter`** — **not yet**. A Supabase project is now deployed ([decisions.md](decisions.md) ADR-009) but the app does not consume it; the live auth is still the local demo stub. `supabase_flutter` will be added at Phase 3 (Flutter integration) — do not add it before then.
- **`youtube_explode_dart`** — not in `pubspec` (an earlier Phase-10 experiment referenced it; it is not a current dependency).
- **`dio`** — no. HTTP uses the `http` package via a throttled client.

---

## Backend Dependencies

Three Python 3.11 / FastAPI services. See [architecture](architecture.md), [api](api.md), and [environment](environment.md).

### paax-api (`paax-api/requirements.txt`) — LIVE metadata service

| Package | Version | Purpose | Health | Notes |
|---------|---------|---------|--------|-------|
| `fastapi` | 0.115.0 | API framework | ✅ | Serves both v1 (ytmusicapi) and v2 (Deezer+YouTube hybrid) surfaces. |
| `uvicorn[standard]` | 0.30.6 | ASGI server | ✅ | Railway sets `PORT` (default 8080). |
| `ytmusicapi` | 1.7.4 | v1 metadata + authenticated library ops | ✅ | Uses a single shared YTMusic OAuth account. |
| `yt-dlp` | >=2024.1.0 | YouTube match (`ytsearch`) → `videoId` | ⚠️ | Unpinned lower-bound; `yt-dlp` breaks often as YouTube changes. Core of the v2 pipeline. |
| `httpx` | 0.27.0 | Async HTTP client (Deezer, LRCLIB) | ⚠️ | Deezer client runs with `verify=False` — TLS validation disabled. See [security](security.md) / [known issues](KNOWN_ISSUES.md). |
| `redis` | 5.0.8 | Two-tier cache (async) | ✅ | Optional (`REDIS_URL`); falls back to in-memory LRU. See [cache strategy](CACHE_STRATEGY.md). |
| `python-multipart` | 0.0.9 | Form parsing | ✅ | — |

### paax-stream (`paax-stream/requirements.txt`) — byte proxy (deployed, not consumed by live app)

| Package | Version | Purpose | Health | Notes |
|---------|---------|---------|--------|-------|
| `fastapi` | 0.115.0 | API framework | ✅ | Only `/`, `/health`, `/stream` mount. |
| `uvicorn[standard]` | 0.30.6 | ASGI server | ✅ | — |
| `httpx` | 0.27.2 | CDN byte proxy with IPv6 source binding | ✅ | `AsyncHTTPTransport(local_address=ipv6)`, HTTP/2 on, Range support. |
| `pydantic` | 2.7.1 | Config/data models | ✅ | — |
| `pydantic-settings` | >=2.2.0 | Env-var settings loading | ✅ | — |
| `redis` | >=5.0.0 | Per-IPv6 device session store | ✅ | `paax:session:<ipv6>` TTL 1800s. |
| `python-dotenv` | (unpinned) | Local `.env` loading | ✅ | — |

> **Missing dependency, by design of the debt:** `yt_dlp` is **NOT** in paax-stream's requirements, so the entire orphaned `resolve/` provider pipeline (`youtube_ipv6_proxy`, `cobalt`, `piped`, `invidious`, `youtube_local_mp4`) cannot run even if it were mounted. It is dead scaffolding. See [tech debt](TECH_DEBT.md) and [known issues](KNOWN_ISSUES.md).

### backend (`backend/requirements.txt`) — legacy monolith (SUPERSEDED)

| Package | Version | Purpose | Health | Notes |
|---------|---------|---------|--------|-------|
| `fastapi` | 0.115.0 | API framework | ⚠️ | Superseded by paax-api; kept for history. |
| `uvicorn[standard]` | 0.30.6 | ASGI server | ⚠️ | — |
| `ytmusicapi` | 1.7.4 | v1 metadata | ⚠️ | — |
| `yt-dlp` | 2024.10.7 | In-process streaming | ❌ | `/stream/{videoId}` is BROKEN (`NameError: _FORMAT_FALLBACKS`). Do not resurrect. |
| `python-multipart` | 0.0.9 | Form parsing | ⚠️ | — |
| `redis` | 5.0.8 | Response + stream cache | ⚠️ | — |

### Cloudflare Worker (`cloudflare-worker/`)

No package manifest / no npm dependencies. Pure Workers JS calling YouTube Innertube (`youtubei/v1/player`). No env vars. See [api](api.md) and [error codes](ERROR_CODES.md).

---

## Infrastructure / DevOps

| Tool | Version | Purpose | Notes |
|------|---------|---------|-------|
| **Supabase** (hosted Postgres / Auth / Storage) | — | Persistent foundation — schema, identity, buckets (Phase 1, ADR-009) | **New platform dependency (2026-07-16), deployed but consumed by nothing yet.** Project `jecgmiuypuathhvjuhea`; migrations in `supabase/migrations/`. See [database](database.md), [backend/database-schema.md](backend/database-schema.md). |
| Postgres extensions: `pg_trgm`, `pgcrypto` | — | Trigram similarity search on normalized names; `gen_random_uuid()` PKs | Installed in the Supabase `extensions` schema (migration `20260716090000`). |
| `scripts/bootstrap-owner.mjs` | Node ≥ 18 | Owner account bootstrap against Supabase Auth | **Zero-dependency** (built-in `fetch`/`readline` only) — adds no npm packages. Env-driven; see [environment](environment.md). |
| Railway (NIXPACKS) | — | Hosts all 3 Python services | `restartPolicyType=ON_FAILURE`, max 5 retries. See [deployment](deployment.md). |
| Cloudflare Workers | — | Edge stream-URL resolver | `stream.paaxmusic.app`. |
| Redis (Railway plugin) | 5.x | Cache + IPv6 sessions | Optional for paax-api, required-ish for paax-stream. |
| Vercel | — | Web/PWA hosting (`paaxmusic.app`) | Flutter web build. |
| GitHub Actions | — | CI/CD | **Not configured** — no CI pipeline exists yet. See [tech debt](TECH_DEBT.md). |
| Docker | — | Containerization | **Not used** — Railway builds via NIXPACKS. |

> **Supabase client SDKs are NOT dependencies yet.** `supabase-js` / `@supabase/ssr` appear in no manifest; they arrive when the backend integrates (Phase 2+). Flutter will use `supabase_flutter` at Phase 3. The Stripe Edge Function scaffolds in `supabase/functions/` are undeployed and pull Deno imports at deploy time, not via a repo manifest.

---

## Dependency Audit Schedule

- **Automated**: Not configured (no Dependabot/Renovate). Target: weekly.
- **Manual review**: Ad hoc, before notable releases.
- **Command**: `flutter pub outdated` / `flutter pub audit` (frontend); `pip list --outdated` / `pip-audit` (Python services).

---

## Dependency Upgrade History

Notable movements from git history (see [changelog](CHANGELOG.md)):

| Package | From | To | Date | Notes |
|---------|------|----|------|-------|
| `flutter_inappwebview` | ^5.8.0 | ^6.1.5 | 2026 (client-side playback phase) | Introduced for hidden-WebView identity/playback, later bumped to v6. |
| `CardTheme` API | `CardTheme` | `CardThemeData` | — | Flutter SDK compatibility fix (commit `938cf07`). |

*(History is approximate — the repo predates this changelog and dates are inferred from commit ordering, not tags.)*

---

## Pending Upgrades

| Package | Current | Available | Blocking | Priority |
|---------|---------|-----------|----------|----------|
| `yt-dlp` (paax-api) | >=2024.1.0 | rolling | Should be pinned to a known-good build; unpinned lower bound risks silent breakage | High |
| `yt-dlp` (backend) | 2024.10.7 | rolling | Legacy service is superseded/broken — do not upgrade, retire instead | Low |

---

*Last updated: 2026-07-16*
