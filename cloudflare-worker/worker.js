/**
 * Paax Stream Worker — stream.paaxmusic.app
 * v4 — multi-client fallback + preferred-client hint + JSON resolve metadata
 *
 * Resolution strategy:
 *   If ?client=X is passed, try that client first, then fall through waterfall.
 *   Otherwise, tries a prioritised list of Innertube clients in sequence.
 *   Stops at first client that returns a playable, non-bot-gated stream.
 *
 * Format selection:
 *   PATH 1: audioOnly mp4/m4a (no sq= DASH) → highest bitrate (prefer itag 140)
 *   PATH 2: muxed mp4 progressive fallback   → lowest bitrate
 *
 * JSON response:
 *   { url, mimeType, sourceType, expiresAt, clientUsed, itag }
 *
 * Logging tags:
 *   [WORKER RESOLVE]        Cold resolution started
 *   [WORKER CLIENT TRY]     Trying a specific Innertube client
 *   [WORKER CLIENT SUCCESS] Client returned a playable stream
 *   [WORKER CLIENT FAIL]    Client failed (bot-check / 403 / no formats)
 *   [WORKER PLAYABILITY]    Playability status from Innertube
 *   [WORKER CACHE HIT]      URL served from CF cache
 *   [WORKER CACHE MISS]     No cache entry — resolving fresh
 *   [WORKER FINAL ERROR]    All clients failed — giving up
 */

// ---------------------------------------------------------------------------
// Innertube client profiles — tried in order, first win stops the loop
// ---------------------------------------------------------------------------
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
        name: 'ANDROID_TESTSUITE',
        id: '30',
        version: '1.9',
        ua: 'com.google.android.youtube/1.9 (Linux; U; Android 12; GB) gzip',
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
const CACHE_TTL_SECONDS = 300;  // 5 min — CDN URLs expire in ~6h; we refresh early

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
        err.retry = true;
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

    if (playStatus !== 'OK') {
        const isBotCheck = BOT_CHECK_SIGNALS.some(s => playReason.toLowerCase().includes(s));
        const err = new Error(playReason || playStatus);
        err.code = isBotCheck ? 'PLAYABILITY_BOT_CHECK' : 'PLAYABILITY_FAILED';
        err.retry = isBotCheck;
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
// Format selection
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

function selectBestFormat(playerResponse, clientName) {
    const adaptive = playerResponse.streamingData.adaptiveFormats || [];
    const muxed = playerResponse.streamingData.formats || [];

    // PATH 1: audio-only mp4/m4a — prefer itag 140 (128kbps AAC), then highest bitrate
    const audioCandidates = adaptive.filter(isDirectAudio);
    if (audioCandidates.length > 0) {
        // Prefer itag=140 (known stable MP4 audio across all clients)
        const preferred = audioCandidates.find(f => f.itag === 140);
        const c = preferred || audioCandidates.sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0))[0];
        const mime = (c.mimeType || 'audio/mp4').split(';')[0].trim();
        console.log(`[WORKER CLIENT SUCCESS] ${clientName} audioOnly itag=${c.itag} mime=${mime} bitrate=${c.bitrate}`);
        return { url: c.url, sourceType: 'audioOnly', mimeType: mime, itag: c.itag, clientUsed: clientName };
    }

    // PATH 2: muxed mp4 — lowest bitrate (audio track is all we need)
    const muxedCandidates = muxed.filter(isDirectMuxed);
    if (muxedCandidates.length > 0) {
        muxedCandidates.sort((a, b) => (a.bitrate || 0) - (b.bitrate || 0));
        const c = muxedCandidates[0];
        console.log(`[WORKER CLIENT SUCCESS] ${clientName} muxed-fallback itag=${c.itag} bitrate=${c.bitrate}`);
        return { url: c.url, sourceType: 'muxed', mimeType: 'video/mp4', itag: c.itag, clientUsed: clientName };
    }

    const err = new Error(
        `No direct format found (${adaptive.length} adaptive, ${muxed.length} muxed — all DASH or incompatible)`
    );
    err.code = 'NO_AUDIO_FORMAT';
    err.retry = false;
    throw err;
}

// ---------------------------------------------------------------------------
// Client waterfall — optionally starts with a preferred client
// ---------------------------------------------------------------------------
async function resolveStream(videoId, preferredClientName) {
    let lastErr = null;

    // Build ordered client list: preferred first (if specified + found), then rest
    let clientList = [...INNERTUBE_CLIENTS];
    if (preferredClientName) {
        const idx = clientList.findIndex(c => c.name === preferredClientName);
        if (idx > 0) {
            const preferred = clientList.splice(idx, 1)[0];
            clientList = [preferred, ...clientList];
            console.log(`[WORKER RESOLVE] Preferred client: ${preferredClientName}`);
        }
    }

    for (const client of clientList) {
        console.log(`[WORKER CLIENT TRY] ${client.name}@${client.version} for ${videoId}`);
        try {
            const playerResponse = await tryClient(client, videoId);
            return selectBestFormat(playerResponse, client.name);
        } catch (err) {
            lastErr = err;
            console.log(
                `[WORKER CLIENT FAIL] ${client.name}: code=${err.code} retry=${err.retry} ` +
                `msg=${err.message}`
            );
            if (!err.retry) break; // hard failure — no point trying other clients
        }
    }

    const finalCode = lastErr?.code || 'ALL_CLIENTS_BLOCKED';
    const isBotBlock = finalCode === 'PLAYABILITY_BOT_CHECK' || finalCode === 'INNERTUBE_403';
    const err = new Error(lastErr?.message || 'All Innertube clients blocked');
    err.code = isBotBlock ? 'ALL_CLIENTS_BLOCKED' : finalCode;
    throw err;
}

// ---------------------------------------------------------------------------
// CF Cache helpers  (key version bumped to v4 to invalidate old format)
// ---------------------------------------------------------------------------
function cacheKey(videoId) {
    return `https://stream.paaxmusic.app/_cache/v4/${videoId}`;
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
    MISSING_VIDEO_ID: 400,
    INVALID_VIDEO_ID: 400,
};
const ERROR_MSG = {
    ALL_CLIENTS_BLOCKED: 'Stream temporarily unavailable — try again shortly',
    INNERTUBE_403: 'Stream service rate-limited — try again',
    PLAYABILITY_BOT_CHECK: 'Stream temporarily unavailable — try again shortly',
    PLAYABILITY_FAILED: 'This track is no longer available',
    NO_STREAMING_DATA: 'Playback is not available right now',
    NO_AUDIO_FORMAT: 'No compatible audio stream found for this track',
    MISSING_VIDEO_ID: 'Missing video ID',
    INVALID_VIDEO_ID: 'Invalid video ID',
};

function jsonError(code, extra) {
    const status = ERROR_HTTP[code] || 502;
    const message = ERROR_MSG[code] || 'Playback is not available right now';
    return new Response(JSON.stringify({ error: message, code, ...extra }), {
        status,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function extractExpiresAt(cdnUrl) {
    try {
        const u = new URL(cdnUrl);
        const v = u.searchParams.get('expire');
        return v ? parseInt(v, 10) : 0;
    } catch (_) { return 0; }
}

/** Build the standard JSON resolve response with CORS headers. */
function jsonResolveResponse(data) {
    return new Response(JSON.stringify(data), {
        status: 200,
        headers: {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Cache-Control': 'no-store',
        },
    });
}

// ---------------------------------------------------------------------------
// Main handler
// ---------------------------------------------------------------------------
async function handleRequest(request) {
    const url = new URL(request.url);
    const path = url.pathname;

    // CORS preflight
    if (request.method === 'OPTIONS') {
        return new Response(null, {
            status: 204,
            headers: {
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Methods': 'GET, OPTIONS',
                'Access-Control-Allow-Headers': 'Accept, Range',
                'Access-Control-Max-Age': '86400',
            },
        });
    }

    // Extract videoId from  /{videoId}  or  /resolve/{videoId}
    const segments = path.slice(1).split('/');
    const videoId = (segments[segments.length - 1] || '').trim();
    if (!videoId) return jsonError('MISSING_VIDEO_ID');
    if (!/^[a-zA-Z0-9_-]{11}$/.test(videoId)) return jsonError('INVALID_VIDEO_ID');

    // Optional preferred client hint from Flutter (e.g. ?client=ANDROID_VR)
    const preferredClient = url.searchParams.get('client') || null;

    // --- 1. CF Cache lookup --------------------------------------------------
    // Skip cache if a specific client is requested (force fresh resolve)
    if (!preferredClient) {
        const cached = await cacheRead(videoId);
        if (cached?.url) {
            console.log(`[WORKER CACHE HIT] ${videoId} sourceType=${cached.sourceType} client=${cached.clientUsed ?? '?'}`);
            return jsonResolveResponse(cached);
        }
    }
    console.log(`[WORKER CACHE MISS] ${videoId}${preferredClient ? ` (forced client=${preferredClient})` : ''}`);

    // --- 2. Resolve via Innertube client waterfall ---------------------------
    console.log(`[WORKER RESOLVE] Starting resolution for ${videoId}`);
    let resolved;
    try {
        resolved = await resolveStream(videoId, preferredClient);
    } catch (err) {
        const code = err?.code || 'ALL_CLIENTS_BLOCKED';
        console.error(`[WORKER FINAL ERROR] ${videoId}: code=${code} msg=${err.message}`);
        return jsonError(code);
    }

    const expiresAt = extractExpiresAt(resolved.url);
    const payload = {
        url: resolved.url,
        mimeType: resolved.mimeType,
        sourceType: resolved.sourceType,
        expiresAt,
        clientUsed: resolved.clientUsed,
        itag: resolved.itag,
    };

    // --- 3. Cache the resolved metadata (only for full resolved, not client-hint requests) ---
    if (!preferredClient) {
        await caches.default.put(
            cacheKey(videoId),
            new Response(JSON.stringify(payload), {
                headers: {
                    'Content-Type': 'application/json',
                    'Cache-Control': `public, max-age=${CACHE_TTL_SECONDS}`,
                },
            })
        );
    }

    console.log(`[WORKER RESOLVE RESULT] ${videoId} client=${resolved.clientUsed} itag=${resolved.itag} sourceType=${resolved.sourceType} expiresAt=${expiresAt}`);

    return jsonResolveResponse(payload);
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
