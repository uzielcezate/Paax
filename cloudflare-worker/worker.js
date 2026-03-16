/**
 * Paax Stream Worker — stream.paaxmusic.app
 * v3 — multi-client fallback + redirect-first serving
 *
 * Resolution strategy:
 *   Tries a prioritised list of Innertube clients in sequence.
 *   Stops at first client that returns a playable, non-bot-gated stream.
 *   Format selection mirrors Flutter playback_engine_mobile.dart:
 *     PATH 1: audioOnly mp4/m4a (no sq= DASH)  → highest bitrate
 *     PATH 2: muxed mp4 progressive fallback    → lowest bitrate
 *
 * Serving strategy (redirect-first):
 *   1. CF Cache hit  → 302 redirect to cached CDN URL (< 50 ms)
 *   2. Cache miss    → resolve via Innertube client waterfall
 *   3. On success    → write URL to CF Cache → 302 redirect to CDN URL
 *   4. Proxy fallback → only used if redirect produces a non-2xx/3xx CDN status
 *
 * Logging tags:
 *   [WORKER RESOLVE]        Cold resolution started
 *   [WORKER CLIENT TRY]     Trying a specific Innertube client
 *   [WORKER CLIENT SUCCESS] Client returned a playable stream
 *   [WORKER CLIENT FAIL]    Client failed (bot-check / 403 / no formats)
 *   [WORKER PLAYABILITY]    Playability status from Innertube
 *   [WORKER CACHE HIT]      URL served from CF cache
 *   [WORKER CACHE MISS]     No cache entry — resolving fresh
 *   [WORKER REDIRECT MODE]  Serving via 302 → CDN (redirect-first)
 *   [WORKER PROXY MODE]     Serving via byte-proxy (fallback only)
 *   [WORKER CDN STATUS]     HTTP status returned by the YouTube CDN
 *   [WORKER FINAL ERROR]    All clients failed — giving up
 *   [WORKER ERROR]          Any unexpected error
 */

// ---------------------------------------------------------------------------
// Innertube client profiles
// ---------------------------------------------------------------------------
// Tried in order — first one that returns playabilityStatus=OK wins.
// ANDROID (id=3) is most reliable for pre-signed progressive URLs.
// ANDROID_VR (id=28) and TV_EMBEDDED (id=85) provide useful fallbacks.
// IOS (id=5) uses a different signing path that bypasses some bot gates.
const INNERTUBE_CLIENTS = [
    {
        name: 'ANDROID',
        id: '3',
        version: '20.10.38',
        ua: 'com.google.android.youtube/20.10.38 (Linux; U; Android 12; GB) gzip',
        extra: { androidSdkVersion: 30 },
    },
    {
        name: 'ANDROID_VR',
        id: '28',
        version: '1.60.19',
        ua: 'com.google.android.vr.youtube/1.60.19 (Linux; U; Android 12; GB) gzip',
        extra: { androidSdkVersion: 30 },
    },
    {
        name: 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
        id: '85',
        version: '2.0',
        ua: 'Mozilla/5.0 (SMART-TV; LINUX; Tizen 5.0) AppleWebKit/537.36 ' +
            '(KHTML, like Gecko) SamsungBrowser/2.1 Chrome/56.0.2924.0 TV Safari/537.36',
        extra: {},
    },
    {
        name: 'IOS',
        id: '5',
        version: '19.45.4',
        ua: 'com.google.ios.youtube/19.45.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)',
        extra: { deviceModel: 'iPhone16,2', osName: 'iPhone', osVersion: '18.1.0' },
    },
];

const INNERTUBE_PLAYER_URL = 'https://www.youtube.com/youtubei/v1/player?prettyPrint=false';
const CACHE_TTL_SECONDS = 300;  // 5 min — short TTL to avoid serving expired signed CDN URLs

// Signals that a retry with a different client might help
const BOT_CHECK_SIGNALS = [
    'sign in to confirm',
    'confirm you',
    'not a bot',
    'unusual traffic',
    'please sign in',
];



// ---------------------------------------------------------------------------
// Innertube — single client attempt
// ---------------------------------------------------------------------------
async function tryClient(client, videoId) {
    const ctx = {
        clientName: client.name,
        clientVersion: client.version,
        hl: 'en',
        gl: 'US',
        utcOffsetMinutes: 0,
        ...client.extra,
    };

    const body = {
        videoId,
        contentCheckOk: true,
        racyCheckOk: true,
        context: { client: ctx },
    };

    const res = await fetch(INNERTUBE_PLAYER_URL, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            'User-Agent': client.ua,
            'X-YouTube-Client-Name': client.id,
            'X-YouTube-Client-Version': client.version,
            'Accept-Language': 'en-US,en;q=0.9',
            'Origin': 'https://www.youtube.com',
            'Referer': 'https://www.youtube.com/',
        },
        body: JSON.stringify(body),
    });

    if (!res.ok) {
        const code = res.status === 403 ? 'INNERTUBE_403' : `INNERTUBE_HTTP_${res.status}`;
        const snippet = (await res.text()).substring(0, 150);
        console.log(`[WORKER CLIENT FAIL] ${client.name} HTTP=${res.status}: ${snippet}`);
        const err = new Error(`HTTP ${res.status}`);
        err.code = code;
        err.retry = true; // always retry with next client on HTTP errors
        throw err;
    }

    const data = await res.json();
    const playStatus = data?.playabilityStatus?.status ?? 'MISSING';
    const playReason = data?.playabilityStatus?.reason ?? '';
    const hasSD = !!data?.streamingData;
    const adaptCount = (data?.streamingData?.adaptiveFormats ?? []).length;
    const fmtCount = (data?.streamingData?.formats ?? []).length;

    console.log(
        `[WORKER PLAYABILITY] ${client.name}: status=${playStatus} ` +
        `streamingData=${hasSD} adaptive=${adaptCount} formats=${fmtCount}` +
        (playReason ? ` reason="${playReason}"` : '')
    );

    // Bot-check → retry with next client
    if (playStatus !== 'OK') {
        const isBotCheck = BOT_CHECK_SIGNALS.some(s => playReason.toLowerCase().includes(s));
        const err = new Error(playReason || playStatus);
        err.code = isBotCheck ? 'PLAYABILITY_BOT_CHECK' : 'PLAYABILITY_FAILED';
        err.retry = isBotCheck; // only retry on bot-check; hard failures don't retry
        throw err;
    }

    if (!hasSD) {
        const err = new Error('No streamingData');
        err.code = 'NO_STREAMING_DATA';
        err.retry = false;
        throw err;
    }

    return data;
}

// ---------------------------------------------------------------------------
// Format selection (mirrors Flutter _isDirectPlayable / _isDirectPlayableMuxed)
// ---------------------------------------------------------------------------
function isDashUrl(url) {
    try {
        const u = new URL(url);
        if (u.searchParams.has('sq') || u.searchParams.has('manifest_type')) return true;
        const p = u.pathname.toLowerCase();
        if (p.endsWith('.m3u8') || p.endsWith('.mpd')) return true;
        if (p.includes('manifest') || p.includes('playlist')) return true;
    } catch (_) { return true; }
    return false;
}

function isDirectAudio(fmt) {
    const mime = (fmt.mimeType || '').toLowerCase();
    const url = fmt.url || '';
    if (!url) return false;
    if (!mime.startsWith('audio/')) return false;
    if (!mime.includes('mp4') && !mime.includes('m4a') && !mime.includes('aac')) return false;
    if (mime.includes('webm') || mime.includes('opus')) return false;
    if (isDashUrl(url)) return false;
    return true;
}

function isDirectMuxed(fmt) {
    const mime = (fmt.mimeType || '').toLowerCase();
    const url = fmt.url || '';
    if (!url) return false;
    if (!mime.startsWith('video/mp4')) return false;
    if (isDashUrl(url)) return false;
    return true;
}

function selectBestFormat(playerResponse) {
    const adaptive = playerResponse.streamingData.adaptiveFormats || [];
    const muxed = playerResponse.streamingData.formats || [];

    // PATH 1: audio-only mp4/m4a — highest bitrate
    const audioCandidates = adaptive.filter(isDirectAudio);
    if (audioCandidates.length > 0) {
        audioCandidates.sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0));
        const c = audioCandidates[0];
        const mime = (c.mimeType || 'audio/mp4').split(';')[0].trim();
        console.log(`[WORKER CLIENT SUCCESS] audioOnly itag=${c.itag} mime=${mime} bitrate=${c.bitrate}`);
        return { url: c.url, sourceType: 'audioOnly', mimeType: mime };
    }

    // PATH 2: muxed mp4 — lowest bitrate (audio track is all we need)
    const muxedCandidates = muxed.filter(isDirectMuxed);
    if (muxedCandidates.length > 0) {
        muxedCandidates.sort((a, b) => (a.bitrate || 0) - (b.bitrate || 0));
        const c = muxedCandidates[0];
        console.log(`[WORKER CLIENT SUCCESS] muxed-fallback itag=${c.itag} bitrate=${c.bitrate}`);
        return { url: c.url, sourceType: 'muxed', mimeType: 'video/mp4' };
    }

    const err = new Error(
        `No direct format found (${adaptive.length} adaptive, ${muxed.length} muxed — all DASH or incompatible)`
    );
    err.code = 'NO_AUDIO_FORMAT';
    err.retry = false;
    throw err;
}

// ---------------------------------------------------------------------------
// Client waterfall
// ---------------------------------------------------------------------------
async function resolveStream(videoId) {
    let lastErr = null;

    for (const client of INNERTUBE_CLIENTS) {
        console.log(`[WORKER CLIENT TRY] ${client.name}@${client.version} for ${videoId}`);
        try {
            const playerResponse = await tryClient(client, videoId);
            return selectBestFormat(playerResponse);
        } catch (err) {
            lastErr = err;
            console.log(
                `[WORKER CLIENT FAIL] ${client.name}: code=${err.code} retry=${err.retry} ` +
                `msg=${err.message}`
            );
            if (!err.retry) {
                // Hard failure (video gone, DRM, etc.) — no point trying other clients
                break;
            }
            // retry=true → try next client
        }
    }

    // All clients failed or hard failure hit
    const finalCode = lastErr?.code || 'ALL_CLIENTS_BLOCKED';
    const isBotBlock = finalCode === 'PLAYABILITY_BOT_CHECK' ||
        finalCode === 'INNERTUBE_403';
    const err = new Error(lastErr?.message || 'All Innertube clients blocked');
    err.code = isBotBlock ? 'ALL_CLIENTS_BLOCKED' : finalCode;
    throw err;
}

// ---------------------------------------------------------------------------
// Serving — proxy streaming (ExoPlayer needs bytes, not a 302 redirect)
// ---------------------------------------------------------------------------

/**
 * Fetch audio bytes from the YouTube CDN and pipe them directly to the client.
 * Forwards Range headers so ExoPlayer can seek within the track.
 */
async function serveStream(streamUrl, request) {
    const rangeHeader = request.headers.get('range') || '';

    console.log(`[WORKER PROXY MODE] Starting CDN fetch`);
    if (rangeHeader) {
        console.log(`[WORKER RANGE] Forwarding Range: ${rangeHeader}`);
    }

    // Build outbound CDN request — only forward range + standard browser headers
    const cdnHeaders = new Headers();
    if (rangeHeader) cdnHeaders.set('Range', rangeHeader);
    cdnHeaders.set(
        'User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
        '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
    );
    cdnHeaders.set('Referer', 'https://www.youtube.com/');
    cdnHeaders.set('Origin', 'https://www.youtube.com');

    console.log(`[WORKER CDN FETCH] ${streamUrl.substring(0, 90)}...`);

    const upstream = await fetch(new Request(streamUrl, {
        method: 'GET',
        headers: cdnHeaders,
    }));

    console.log(`[WORKER CDN FETCH] CDN responded: ${upstream.status}`);

    if (!upstream.ok && upstream.status !== 206) {
        const err = new Error(`CDN ${upstream.status}`);
        // Tag 403 distinctly so handleRequest can decide to re-resolve
        err.code = upstream.status === 403 ? 'CDN_403' : 'STREAM_PROXY_FAILED';
        throw err;
    }

    // Build clean response — only forward audio-relevant headers
    const respHeaders = new Headers();
    respHeaders.set('Content-Type', upstream.headers.get('content-type') || 'audio/mp4');
    respHeaders.set('Accept-Ranges', 'bytes');

    const contentLength = upstream.headers.get('content-length');
    if (contentLength) respHeaders.set('Content-Length', contentLength);

    const contentRange = upstream.headers.get('content-range');
    if (contentRange) respHeaders.set('Content-Range', contentRange);

    respHeaders.set('Access-Control-Allow-Origin', '*');
    respHeaders.set('Cache-Control', 'no-store');

    console.log(`[WORKER STREAM OK] Piping to client — status=${upstream.status}`);

    return new Response(upstream.body, {
        status: upstream.status,
        headers: respHeaders,
    });
}

// ---------------------------------------------------------------------------
// CF Cache helpers
// ---------------------------------------------------------------------------
function cacheKey(videoId) {
    return `https://stream.paaxmusic.app/_cache/v3/${videoId}`;
}

async function cacheRead(videoId) {
    const res = await caches.default.match(cacheKey(videoId));
    if (!res) return null;
    try { return await res.json(); } catch (_) { return null; }
}

async function cacheWrite(videoId, data) {
    const res = new Response(JSON.stringify(data), {
        headers: {
            'Content-Type': 'application/json',
            'Cache-Control': `public, max-age=${CACHE_TTL_SECONDS}`,
        },
    });
    await caches.default.put(cacheKey(videoId), res);
}

async function cacheDelete(videoId) {
    await caches.default.delete(cacheKey(videoId));
}

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------
const ERROR_HTTP = {
    ALL_CLIENTS_BLOCKED: 503,
    INNERTUBE_403: 503,
    PLAYABILITY_BOT_CHECK: 503,
    PLAYABILITY_FAILED: 404,
    NO_STREAMING_DATA: 502,
    NO_AUDIO_FORMAT: 502,
    STREAM_REDIRECT_FAILED: 502,
    STREAM_PROXY_FAILED: 502,
};
const ERROR_MSG = {
    ALL_CLIENTS_BLOCKED: 'Stream temporarily unavailable — try again shortly',
    INNERTUBE_403: 'Stream service rate-limited — try again',
    PLAYABILITY_BOT_CHECK: 'Stream temporarily unavailable — try again shortly',
    PLAYABILITY_FAILED: 'This track is no longer available',
    NO_STREAMING_DATA: 'Playback is not available right now',
    NO_AUDIO_FORMAT: 'No compatible audio stream found for this track',
    STREAM_REDIRECT_FAILED: 'Stream redirect failed — try again',
    STREAM_PROXY_FAILED: 'Stream proxy failed — try again',
};

function jsonError(code, extra) {
    const status = ERROR_HTTP[code] || 502;
    const message = ERROR_MSG[code] || 'Playback is not available right now';
    return new Response(JSON.stringify({ error: message, code, ...extra }), {
        status,
        headers: {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
        },
    });
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------
async function handleRequest(request) {
    const url = new URL(request.url);
    const path = url.pathname;
    const useProxy = url.searchParams.get('proxy') === '1'; // debug override

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

    // Extract and validate videoId
    const videoId = path.slice(1).split('/')[0].trim();
    if (!videoId) {
        return jsonError('MISSING_VIDEO_ID');
    }
    if (!/^[a-zA-Z0-9_-]{11}$/.test(videoId)) {
        return jsonError('INVALID_VIDEO_ID');
    }

    // --- 1. CF Cache lookup --------------------------------------------------
    const cached = await cacheRead(videoId);
    if (cached?.url) {
        console.log(`[WORKER CACHE URL HIT] ${videoId} sourceType=${cached.sourceType}`);
        try {
            return await serveStream(cached.url, request);
        } catch (err) {
            if (err?.code === 'CDN_403') {
                // Signed URL has expired or been invalidated — discard and re-resolve
                console.log(`[WORKER CACHE URL INVALIDATED] ${videoId} — cached URL returned 403`);
                await cacheDelete(videoId);
                // Fall through to fresh resolution below
            } else {
                // Non-403 proxy failure — surface immediately
                const code = err?.code || 'STREAM_PROXY_FAILED';
                console.error(`[WORKER FINAL ERROR] ${videoId} cached proxy failed: code=${code}`);
                return jsonError(code);
            }
        }
        console.log(`[WORKER RE-RESOLVE AFTER 403] ${videoId} — fetching fresh stream URL`);
    } else {
        console.log(`[WORKER CACHE MISS] ${videoId}`);
    }

    // --- 2. Resolve via Innertube client waterfall ---------------------------
    console.log(`[WORKER RESOLVE] Starting multi-client resolution for ${videoId}`);
    let resolved;
    try {
        resolved = await resolveStream(videoId);
    } catch (err) {
        const code = err?.code || 'ALL_CLIENTS_BLOCKED';
        console.error(`[WORKER FINAL ERROR] ${videoId}: code=${code} msg=${err.message}`);
        return jsonError(code);
    }

    // --- 3. Prime CF cache (best-effort, background) -------------------------
    const cacheWritePromise = cacheWrite(videoId, {
        url: resolved.url,
        sourceType: resolved.sourceType,
        mimeType: resolved.mimeType,
    });

    // --- 4. Serve the stream -------------------------------------------------
    // If we got here via cache-invalidation, log the retry clearly.
    const isCacheRetry = cached?.url != null;
    if (isCacheRetry) {
        console.log(`[WORKER RETRY CDN FETCH] ${videoId} — using fresh URL after 403 invalidation`);
    }
    let response;
    try {
        response = await serveStream(resolved.url, request);
    } catch (err) {
        const code = err?.code || 'STREAM_PROXY_FAILED';
        console.error(`[WORKER FINAL ERROR] ${videoId} proxy: code=${code}`);
        await cacheWritePromise;
        return jsonError(code);
    }

    await cacheWritePromise;
    return response;
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
            return new Response(
                JSON.stringify({ error: 'Internal server error', code: 'INTERNAL_ERROR' }),
                { status: 500, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' } }
            );
        }
    },
};
