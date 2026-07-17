# Repositories

> **Purpose**: Documents all repository classes/modules — their role as the data access layer, the operations they expose, and their database/data-source dependencies.
> **Update when**: A new repository is created, a method is added or removed, or the data source changes.

> **See also**: [`services.md`](services.md), [`database-schema.md`](database-schema.md) (why there is no server DB), [`cache.md`](cache.md), and [`../frontend/state-management.md`](../frontend/state-management.md) for the *client-side* repository.

---

## What is a Repository?

The template defines a repository as "the only layer that talks to the database." **On the Paax backend there is no database and no classic repository layer.** The servers are stateless proxies (see [`database-schema.md`](database-schema.md)). Be honest about this: do not invent `UserRepository`/`PlaylistRepository` — they do not exist server-side.

What *does* play the "data access layer" role is the set of **external-API client modules** that own all outbound calls to third-party sources. They match the *spirit* of a repository — they are the only place upstream I/O happens and they return normalized objects — without the DB semantics (no CRUD, no ownership, no migrations).

There are **two** places a repository-shaped thing lives:
1. **Server-side data-access clients** (this doc, below) — read-only proxies to Deezer/YouTube/ytmusicapi.
2. **Client-side `MusicRepositoryImpl`** in the Flutter app — a real repository implementation over the Hive store + the API. Documented in [`../frontend/state-management.md`](../frontend/state-management.md); summarized at the bottom here.

---

## Repository Inventory

Server-side "repositories" = external data-access clients. All are **read-only** (except the shared-account ytmusicapi mutations, which are not user-scoped).

| "Repository" (data-access module) | File | Data Source | Responsibility |
|-----------|------|------------|----------------|
| `deezer_client` | `paax-api/services/deezer/deezer_client.py` | Deezer public API (`api.deezer.com`, no key) | Catalog metadata: tracks, albums, artists, search, chart |
| `youtube_matcher` (yt-dlp) | `paax-api/services/youtube/youtube_matcher.py` | YouTube via `yt-dlp ytsearch` | Resolve best `videoId` for a track (playback key) |
| ytmusicapi client | `paax-api/main.py`, `backend/main.py` | YouTube Music (ytmusicapi) | v1 discovery + shared-account library/playlist ops |
| LRCLIB client | `paax-api/main.py` (`/lyrics` handler) | LRCLIB (`lrclib.net`) | Synced/plain lyrics |
| IPv6 httpx transport pool | `paax-stream/app/` | YouTube CDN (`*.googlevideo.com`) | Byte-level audio access via bound source IPv6 |
| Innertube fetcher | `cloudflare-worker/` | YouTube `youtubei/v1/player` | Direct progressive audio URL (edge; see [`workers.md`](workers.md)) |

> These are **not** classic repositories: they have no `create/update/delete` over owned rows, no primary keys we mint, no pagination contract we control (Deezer/YouTube dictate paging), and no transactions. They are **outbound adapters**.

---

## Repository Specs

---

### `deezer_client` — the primary "repository"

**File**: `paax-api/services/deezer/deezer_client.py`
**Data Source**: Deezer public API (unauthenticated).

**Methods** (module functions; representative):

| Method | Returns | Description |
|--------|---------|-------------|
| `search(q, type, limit)` | raw Deezer list | `/search/{tracks\|albums\|artists}` |
| `get_track(id)` | raw Deezer track | `/track/{id}` (id is Deezer integer) |
| `get_album(id)` | raw Deezer album + tracklist | `/album/{id}` |
| `get_artist(id)` | raw Deezer artist | `/artist/{id}` |
| `get_artist_top(id, limit)` | tracks | `/artist/{id}/top` |
| `get_artist_albums(id, limit)` | albums | `/artist/{id}/albums` |
| `get_chart()` | chart payload | `/chart` |

Raw payloads are handed to `deezer_mapper` for normalization ([`services.md`](services.md)).

**Caching**: not in the client itself — caching wraps the *service/endpoint* layer (Redis + in-memory), see [`cache.md`](cache.md).

> **Security flag**: this client sets `verify=False` (TLS validation off). See [`services.md`](services.md), [`security.md`](../security.md).

---

### ytmusicapi client (v1 / legacy)

**File**: `paax-api/main.py`, `backend/main.py`
**Data Source**: YouTube Music via the `ytmusicapi` library.

Backs the v1 discovery surface (search/home/charts/moods/genre/artist/album/song/watch) and the **shared-account** library/playlist mutations. Auth resolution: `YTMUSIC_OAUTH_JSON` env → temp file → else local `oauth.json` → else unauthenticated. This is a **single shared account**, not per-user data access — see [`auth.md`](auth.md).

---

### IPv6 httpx transport pool (paax-stream)

**File**: `paax-stream/app/`
**Data Source**: YouTube progressive-audio CDN.

The "data access" here is byte streaming, not records: 16 source-IPv6-bound httpx transports, sticky per-address fingerprints in Redis (`paax:session:<ipv6>`, TTL 1800s). Details in [`services.md`](services.md) and [`cache.md`](cache.md).

---

## Repository Rules

Mapped to reality:
- **Repositories must not call other repositories** — holds trivially; the clients are independent.
- **Parameterized inputs, never string interpolation** — there is no SQL, but the same principle applies to the **paax-stream host allowlist**: it validates the CDN host suffix before fetching to prevent SSRF ([`security.md`](../security.md)). Query params to Deezer/YouTube are passed as httpx params, not concatenated.
- **Paginate all lists** — pagination is dictated by the upstream (`limit` params on Deezer, `ctoken` on v1 ytmusicapi). We forward it; we do not own it.
- **Translate errors to domain exceptions** — only partly done: the legacy yt-dlp path uses `_classify_yt_error` → stable codes; paax-api leaks `str(e)` ([`ERROR_CODES.md`](../ERROR_CODES.md), [`controllers.md`](controllers.md)).
- **Cache invalidation** — TTL-only; there are no mutations to invalidate around (read-only proxy). See [`cache.md`](cache.md).

---

## Pagination Contract

There is **no Paax-owned pagination contract** on the server — we do not page over rows we store. Upstream pagination is passed through:

- **Deezer (v2)**: `limit` query param, forwarded to Deezer; no offset cursor exposed to clients beyond `limit`.
- **ytmusicapi (v1)**: continuation tokens via `ctoken` on `/artist/{channelId}/albums/page?params&ctoken`.

The template's `PaginatedResult<T>` shape does **not** exist server-side. The nearest client-side analog (in-memory list handling) lives in `MusicRepositoryImpl` — see [`../frontend/state-management.md`](../frontend/state-management.md).

---

## The Real Repository: client-side `MusicRepositoryImpl`

The one place a **genuine repository pattern** exists is the **Flutter client**, not the server:

- `MusicRepositoryImpl implements MusicRepository` (domain interface) — `frontend/lib/data/repositories/`.
- Owns a `YouTubeMusicDataSource` (HTTP to paax-api) + an in-memory album-detail cache.
- v2 mappers set `Track.id = playback.videoId` (the playback key), so the client can play tracks straight through the IFrame.
- `enrichArtistReleases` is a **no-op in v2** (Deezer already returns dates/types).
- The actual *persistence* backing user state (library, playlists, liked, followed, recently played, settings) is **Hive**, not any server store — see [`database-schema.md`](database-schema.md) and [`../database.md`](../database.md).

Full detail: [`../frontend/state-management.md`](../frontend/state-management.md).

---

*Last updated: 2026-07-16*
