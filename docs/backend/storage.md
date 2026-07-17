# Storage

> **Purpose**: Documents all file storage — how files are uploaded, stored, served, and deleted. Covers bucket configuration, access policies, and URL management.
> **Update when**: A new bucket is created, access policies change, or the storage provider changes.

> **See also**: [`../database.md`](../database.md) (both persistence layers), [`database-schema.md`](database-schema.md) (Supabase reference incl. Storage), [`auth.md`](auth.md) (`oauth.json` handling), [`cache.md`](cache.md), [`repositories.md`](repositories.md).

---

## Storage Provider

> **Status (2026-07-16)**: **Supabase Storage buckets + policies are deployed (Phase 1, ADR-009) but nothing uploads to or reads from them yet.** The live app still stores no files server-side: artwork is **hotlinked from Deezer/Google CDNs**, there are no upload endpoints in any service, and no client integration exists. Caching artwork into `music-images` is Phase 2; avatars/stories arrive with Phases 3–4.

- **Provider**: **Supabase Storage** (project `jecgmiuypuathhvjuhea`) — provisioned, not yet consumed.
- **SDK**: None yet — no `supabase_flutter` / `supabase-js` dependency exists ([`../DEPENDENCIES.md`](../DEPENDENCIES.md)).
- **CDN (live path)**: unchanged — artwork/covers are served **directly from third-party CDNs** (Deezer and Google), never proxied or stored by us. The Cloudflare edge fronts the stream Worker, but that resolves URLs — it stores no files.

---

## Where "storage" actually happens

| Asset | Where it lives | Stored by Paax? | Reference |
|-------|----------------|-----------------|-----------|
| User library, playlists, liked, followed, settings | **Client-side Hive** (on-device) | Yes — on the device only | [`../database.md`](../database.md) |
| Album/artist/track cover art | **Deezer CDN** (`cover_xl`/`cover_big` URLs) & **Google** (`lh3–lh6.googleusercontent.com`) | No — hotlinked, cached at the client only | below + [`../performance.md`](../performance.md) |
| Audio bytes | **YouTube CDN** (`*.googlevideo.com`) | No — streamed/proxied, never persisted | [`services.md`](services.md), [`workers.md`](workers.md) |
| Shared YouTube Music credential | `oauth.json` / `YTMUSIC_OAUTH_JSON` env → temp file | Ephemeral, server-only | [`auth.md`](auth.md) |

---

## Buckets (deployed, not yet consumed)

Three buckets exist (migrations `20260716090900_storage_buckets` + `20260716091000_storage_tighten_listing`; see [`database-schema.md`](database-schema.md)):

| Bucket | Visibility | Object paths | Writes |
|--------|-----------|--------------|--------|
| `music-images` | Public **read via URL only** (no listing) | `artists/{artist_id}/profile.webp` · `albums/{album_id}/cover.webp` · `genres/{genre_id}/cover.webp` · `playlists/{playlist_id}/cover.webp` | **service-role only** (Phase 2 ingestion caches artwork here) |
| `user-avatars` | Public **read via URL only** (no listing) | `{user_id}/avatar.webp` | Own-folder: users write only under their own `{user_id}/` prefix |
| `story-media` | **Private** | `{user_id}/{story_id}/{filename}` | Own-folder CRUD; others read via **backend-signed URLs** only |

---

## Bucket Policies

- **Public buckets serve via URL without listing**: `music-images` and `user-avatars` are readable by direct object URL, but bucket **listing is denied** (advisor-driven tightening) — objects are addressable, not enumerable.
- **Avatar upsert needs three policies**: own-folder `INSERT` + `SELECT` + `UPDATE` on `user-avatars` (Storage upsert reads-then-writes, so `SELECT` is required for the client's own folder).
- **`story-media` is private with backend-signed URLs** — deliberately: stories are **ephemeral + friends-only**, and that visibility rule (friendship + 24 h expiry) cannot be cheaply authorized on public CDN paths, so the backend authorizes and mints short-lived signed URLs instead.

The nearest *live* access-control analog remains **paax-stream's host allowlist**: the byte proxy only fetches from URLs whose host ends in `.googlevideo.com` / `.youtube.com` / `.ytimg.com` / `.ggpht.com`, preventing open-SSRF relay use ([`services.md`](services.md), [`../security.md`](../security.md)). That is an *egress* allowlist, not a storage bucket policy.

---

## File Upload Flow

**Not applicable — nothing is ever uploaded.** There is no `POST /uploads/presign`, no `POST /uploads/confirm`, and no server code that accepts a file body. The signed-upload flow in the template has no counterpart in this codebase.

---

## Accepted File Types

**Not applicable — no uploads are accepted.**

For completeness, the *image formats the client consumes* (never stores server-side) are the JPEG/WebP cover URLs Deezer and Google return; the *audio format* the stream path targets is progressive **mp4/m4a/AAC** (itag 140), rejecting webm/opus/DASH ([`workers.md`](workers.md), [`services.md`](services.md)).

---

## File Processing

**Not applicable — no server-side file processing.** No resizing, no compression, no format conversion happens on any backend.

The only image *transformation* is client-side and URL-based, not file-based: `Lh3UrlBuilder` rewrites Google image URLs with `=w{W}-h{H}` sizing hints and shards across `lh3–lh6` subdomains to avoid 429s ([`../performance.md`](../performance.md)). No bytes are processed server-side.

---

## Storage Cleanup

**Not applicable — nothing to clean up server-side.**

- **On user deletion**: local Hive data is cleared client-side (`HiveStorage.clearAll()`); no server files exist to remove ([`auth.md`](auth.md), [`../database.md`](../database.md)).
- **On content deletion**: N/A — no stored cover art or media.
- **Orphan scan**: N/A — no object store to scan. The only server-side ephemeral artifacts are Redis cache entries (TTL-expired automatically, [`cache.md`](cache.md)) and the transient `oauth.json` temp file.

---

## URL Format

We serve **no storage URLs**. The URLs in play are all third-party or resolved-on-demand:

```
Cover art (Deezer):   https://{e-cdns-images...}.dzcdn.net/images/cover/{hash}/{WxH}.jpg
Cover art (Google):   https://lh{3-6}.googleusercontent.com/{id}=w{W}-h{H}
Audio (resolved):     https://{r}---sn-{...}.googlevideo.com/videoplayback?...   (short-lived, signed by YouTube)
```

The audio URLs are YouTube-signed and short-lived; Paax neither mints nor stores them — it resolves them per play ([`workers.md`](workers.md)) or proxies their bytes ([`services.md`](services.md)).

---

## `oauth.json` handling (the one server-side file)

The single file the backend touches on disk is the shared ytmusicapi credential:
- Preferred: `YTMUSIC_OAUTH_JSON` env var → materialized to a **temp file** at startup.
- Fallback: a local `oauth.json` next to the service.
- It is **server-only**, must never be committed or shipped to clients, and should be rotated if leaked ([`auth.md`](auth.md), [`../security.md`](../security.md)). This is credential handling, not "file storage" in the product sense.

---

## Supabase Storage status

**Provisioned (Phase 1), unconsumed.** The three buckets and their RLS policies above are live in the Supabase project, but no application code uploads, reads, or signs URLs yet. Live artwork still hotlinks Deezer/Google; caching it into `music-images` is Phase 2, avatars/stories land with client integration (Phases 3–4). See [`database-schema.md`](database-schema.md) and [`../decisions.md`](../decisions.md) ADR-009.

---

*Last updated: 2026-07-16*
