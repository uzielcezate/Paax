/**
 * Paax Stream Worker — stream.paaxmusic.app
 *
 * Worker-first playback resolver: no Railway in the critical path.
 *
 * Resolution strategy (mirrors Flutter playback_engine_mobile.dart):
 *   PATH 1 — audioOnly:  adaptiveFormats filtered for audio/mp4, no sq= (DASH)
 *             Sort: highest bitrate first.
 *   PATH 2 — muxed mp4 fallback: if all audio-only are DASH-segmented.
 *             Sort: lowest bitrate first (we only need the audio track).
 *
 * Caching:
 *   CF Cache API keyed on https://stream.paaxmusic.app/_cache/{videoId}
 *   TTL: 1800 s (30 min). Cache stores the resolved stream URL as plain text.
 *   Cache hit → 302 redirect directly to the YouTube CDN URL.
 *   Cache miss → resolve via Innertube → proxy bytes → prime cache.
 *
 * Logging tags:
 *   [WORKER RESOLVE]      Cold resolution attempt started
 *   [WORKER CACHE HIT]    Resolved URL served from CF cache
 *   [WORKER CACHE MISS]   No cache entry, resolving fresh
 *   [WORKER STREAM FETCH] Proxying audio bytes from CDN
 *   [WORKER ERROR]        Any failure with code + detail
 */

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const CACHE_TTL_SECONDS = 1800; // 30 minutes

// Innertube endpoint — no API key required for public videos
const INNERTUBE_PLAYER_URL =
    'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';

// ANDROID_EMBEDDED_PLAYER client returns pre-signed CDN URLs —
// no JS signature deciphering required.
const INNERTUBE_CLIENT = {
    clientName: 'ANDROID_EMBEDDED_PLAYER',
    clientVersion: '17.36.4',
    androidSdkVersion: 31,
    userAgent:
        'com.google.android.youtube/17.36.4 (Linux; U; Android 12; GB) gzip',
    hl: 'en',
    gl: 'US',
};

// Headers forwarded to the YouTube CDN when proxying.
const PROXY_REQUEST_HEADERS = [
    'range',
    'if-range',
    'if-modified-since',
];

// Headers forwarded from the CDN to the client.
const PROXY_RESPONSE_HEADERS = [
    'content-type',
    'content-length',
    'content-range',
    'accept-ranges',
    'last-modified',
    'etag',
];

// ---------------------------------------------------------------------------
// Innertube resolver
// ---------------------------------------------------------------------------

/**
 * Call YouTube's internal Innertube /player endpoint.
 * Returns the raw playerResponse JSON.
 */
async function fetchPlayerResponse(videoId) {
    const body = {
        videoId,
        context: {
            client: INNERTUBE_CLIENT,
        },
    };

    const response = await fetch(INNERTUBE_PLAYER_URL, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'User-Agent': INNERTUBE_CLIENT.userAgent,
            'X-YouTube-Client-Name': '56', // ANDROID_EMBEDDED_PLAYER numeric id
            'X-YouTube-Client-Version': INNERTUBE_CLIENT.clientVersion,
            Origin: 'https://www.youtube.com',
        },
        body: JSON.stringify(body),
    });

    if (!response.ok) {
        throw new Error(`Innertube ${response.status}: ${await response.text()}`);
    }

    return response.json();
}

// ---------------------------------------------------------------------------
// Format selection (mirrors Flutter _isDirectPlayable / _isDirectPlayableMuxed)
// ---------------------------------------------------------------------------

/** Return true if a format URL is a DASH segment (not a full progressive file). */
function isDashUrl(url) {
    try {
        const u = new URL(url);
        if (u.searchParams.has('sq') || u.searchParams.has('manifest_type')) return true;
        const path = u.pathname.toLowerCase();
        if (path.endsWith('.m3u8') || path.endsWith('.mpd')) return true;
        if (path.includes('manifest') || path.includes('playlist')) return true;
    } catch (_) {
        // malformed URL — treat as unsafe
        return true;
    }
    return false;
}

/** Return true if format is a direct, progressive audio-only mp4/m4a stream. */
function isDirectAudio(fmt) {
    const mime = (fmt.mimeType || '').toLowerCase();
    const url = fmt.url || '';

    if (!url) return false;
    // Must be audio/* (adaptiveFormat without video track)
    if (!mime.startsWith('audio/')) return false;
    // mp4 / m4a / AAC only — reject webm / opus
    if (!mime.includes('mp4') && !mime.includes('m4a') && !mime.includes('aac')) return false;
    if (mime.includes('webm') || mime.includes('opus')) return false;
    // Reject DASH segments
    if (isDashUrl(url)) return false;
    return true;
}

/** Return true if format is a direct, progressive muxed mp4 stream. */
function isDirectMuxed(fmt) {
    const mime = (fmt.mimeType || '').toLowerCase();
    const url = fmt.url || '';

    if (!url) return false;
    if (!mime.startsWith('video/mp4')) return false;
    if (isDashUrl(url)) return false;
    return true;
}

/**
 * Given a parsed playerResponse, select the best direct stream URL.
 * Returns { url, sourceType, mimeType } or throws if nothing is playable.
 */
function selectBestFormat(playerResponse) {
    const status = playerResponse?.playabilityStatus?.status;
    if (status && status !== 'OK') {
        throw new Error(`Video not playable: ${status}`);
    }

    const streamingData = playerResponse?.streamingData;
    if (!streamingData) {
        throw new Error('No streamingData in playerResponse');
    }

    // adaptiveFormats → audio-only tracks
    const adaptive = streamingData.adaptiveFormats || [];
    // formats → muxed video+audio (lower quality but always progressive)
    const muxed = streamingData.formats || [];

    // --- PATH 1: audio-only mp4/m4a ---
    const audioCandidates = adaptive.filter(isDirectAudio);
    if (audioCandidates.length > 0) {
        // Prefer highest bitrate
        audioCandidates.sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0));
        const chosen = audioCandidates[0];
        const mime = (chosen.mimeType || 'audio/mp4').split(';')[0].trim();
        console.log(
            `[WORKER RESOLVE] audioOnly selected: itag=${chosen.itag} ` +
            `mime=${mime} bitrate=${chosen.bitrate}`
        );
        return { url: chosen.url, sourceType: 'audioOnly', mimeType: mime };
    }

    // --- PATH 2: muxed mp4 fallback ---
    const muxedCandidates = muxed.filter(isDirectMuxed);
    if (muxedCandidates.length > 0) {
        // Prefer lowest bitrate — we only need the audio track
        muxedCandidates.sort((a, b) => (a.bitrate || 0) - (b.bitrate || 0));
        const chosen = muxedCandidates[0];
        const mime = 'video/mp4';
        console.log(
            `[WORKER RESOLVE] muxed fallback selected: itag=${chosen.itag} ` +
            `bitrate=${chosen.bitrate}`
        );
        return { url: chosen.url, sourceType: 'muxed', mimeType: mime };
    }

    throw new Error('No direct playable stream found — all formats are DASH-segmented or incompatible');
}

// ---------------------------------------------------------------------------
// Audio proxy
// ---------------------------------------------------------------------------

/**
 * Proxy the YouTube CDN response back to the client.
 * Forwards Range headers so the client can seek.
 */
async function proxyStream(streamUrl, clientRequest) {
    console.log(`[WORKER STREAM FETCH] Proxying: ${streamUrl.substring(0, 80)}…`);

    const cdnRequest = new Request(streamUrl, {
        method: 'GET',
        headers: buildProxyRequestHeaders(clientRequest.headers),
    });

    const cdnResponse = await fetch(cdnRequest);

    if (!cdnResponse.ok && cdnResponse.status !== 206) {
        throw new Error(`CDN fetch failed: ${cdnResponse.status}`);
    }

    // Build clean response — only forward safe headers to the client
    const responseHeaders = new Headers();
    for (const key of PROXY_RESPONSE_HEADERS) {
        const val = cdnResponse.headers.get(key);
        if (val) responseHeaders.set(key, val);
    }
    // Ensure CORS is open (Flutter WebView / debug)
    responseHeaders.set('Access-Control-Allow-Origin', '*');
    responseHeaders.set('Cache-Control', 'no-store'); // client should not cache raw proxy bytes

    return new Response(cdnResponse.body, {
        status: cdnResponse.status,
        statusText: cdnResponse.statusText,
        headers: responseHeaders,
    });
}

/** Build headers for the outbound CDN fetch from the client's headers. */
function buildProxyRequestHeaders(clientHeaders) {
    const h = new Headers();
    for (const key of PROXY_REQUEST_HEADERS) {
        const val = clientHeaders.get(key);
        if (val) h.set(key, val);
    }
    // Required by YouTube CDN to serve progressive audio
    h.set(
        'User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
        '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
    );
    h.set('Referer', 'https://www.youtube.com/');
    h.set('Origin', 'https://www.youtube.com');
    return h;
}

// ---------------------------------------------------------------------------
// CF Cache helpers
// ---------------------------------------------------------------------------

/** Build a canonical cache key URL for a videoId. */
function cacheKey(videoId) {
    return `https://stream.paaxmusic.app/_cache/${videoId}`;
}

/** Read cached stream URL. Returns the URL string or null. */
async function cacheRead(videoId) {
    const cache = caches.default;
    const response = await cache.match(cacheKey(videoId));
    if (!response) return null;
    const data = await response.json();
    return data || null; // { url, sourceType, mimeType }
}

/** Write resolved stream metadata to CF Cache. */
async function cacheWrite(videoId, data) {
    const cache = caches.default;
    const response = new Response(JSON.stringify(data), {
        headers: {
            'Content-Type': 'application/json',
            'Cache-Control': `public, max-age=${CACHE_TTL_SECONDS}`,
        },
    });
    await cache.put(cacheKey(videoId), response);
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------

async function handleRequest(request) {
    const url = new URL(request.url);
    const path = url.pathname;        // e.g. "/dQw4w9WgXcQ"

    // CORS preflight
    if (request.method === 'OPTIONS') {
        return new Response(null, {
            status: 204,
            headers: {
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': 'GET, OPTIONS',
                'Access-Control-Allow-Headers': 'Range',
                'Access-Control-Max-Age': '86400',
            },
        });
    }

    // Extract videoId from path (strip leading /)
    const videoId = path.slice(1).split('/')[0].trim();
    if (!videoId) {
        return jsonError(400, 'MISSING_VIDEO_ID', 'Missing videoId in path — use /{videoId}');
    }

    // Validate: YouTube videoIds are 11 chars, alphanumeric + - _
    if (!/^[a-zA-Z0-9_-]{11}$/.test(videoId)) {
        return jsonError(400, 'INVALID_VIDEO_ID', 'Invalid videoId format');
    }

    // --- 1. CF Cache lookup --------------------------------------------------
    const cached = await cacheRead(videoId);
    if (cached?.url) {
        console.log(`[WORKER CACHE HIT] ${videoId} → ${cached.sourceType}`);
        // Redirect directly to CDN — avoids proxy bandwidth cost
        return Response.redirect(cached.url, 302);
    }
    console.log(`[WORKER CACHE MISS] ${videoId}`);

    // --- 2. Fresh resolution via Innertube ----------------------------------
    console.log(`[WORKER RESOLVE] Starting Innertube resolution for ${videoId}`);
    let resolved;
    try {
        const playerResponse = await fetchPlayerResponse(videoId);
        resolved = selectBestFormat(playerResponse);
    } catch (err) {
        const msg = err?.message || String(err);
        console.error(`[WORKER ERROR] resolve failed for ${videoId}: ${msg}`);

        const isUnavailable = msg.toLowerCase().includes('not playable') ||
            msg.toLowerCase().includes('no streamingdata');
        return jsonError(
            502,
            isUnavailable ? 'VIDEO_UNAVAILABLE' : 'RESOLVE_FAILED',
            isUnavailable ? 'This track is no longer available' : 'Playback is not available right now'
        );
    }

    // --- 3. Prime CF cache (fire-and-forget) --------------------------------
    // We don't await this — let it race in the background.
    const cacheWritePromise = cacheWrite(videoId, {
        url: resolved.url,
        sourceType: resolved.sourceType,
        mimeType: resolved.mimeType,
    });

    // --- 4. Proxy stream to client ------------------------------------------
    let proxyResponse;
    try {
        proxyResponse = await proxyStream(resolved.url, request);
    } catch (err) {
        const msg = err?.message || String(err);
        console.error(`[WORKER ERROR] proxy failed for ${videoId}: ${msg}`);
        return jsonError(502, 'PROXY_FAILED', 'Stream proxy failed — try again');
    }

    // Ensure cache write is flushed before the handler returns
    await cacheWritePromise;

    return proxyResponse;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function jsonError(status, code, message) {
    return new Response(JSON.stringify({ error: message, code }), {
        status,
        headers: {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
        },
    });
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

export default {
    async fetch(request, env, ctx) {
        try {
            return await handleRequest(request);
        } catch (err) {
            const msg = err?.message || String(err);
            console.error(`[WORKER ERROR] Unhandled: ${msg}`);
            return jsonError(500, 'INTERNAL_ERROR', 'Internal server error');
        }
    },
};
