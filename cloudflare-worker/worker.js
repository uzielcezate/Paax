/**
 * Paax Stream Worker — stream.paaxmusic.app
 * v5 — diverse candidates + exclude-client parameter + precise error codes
 *
 * Key changes vs v4:
 *   - selectBestFormat() now returns ALL playable candidate URLs, not just winner
 *   - ?exclude=ANDROID,IOS skips known-failed clients in the waterfall
 *   - PLAYABILITY_FAILED is now retry=true unless track is truly dead
 *     (removed / doesn't exist). Age-gate, members, region → try next client.
 *   - JSON response includes candidates[] so Flutter can cycle locally
 *     before making another Worker round-trip.
 *   - Cache key bumped to v5.
 *
 * JSON response shape:
 *   {
 *     url, mimeType, sourceType, expiresAt, clientUsed, itag,
 *     candidates: [{ url, itag, mimeType, sourceType, bitrate }]
 *   }
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
const CACHE_TTL_SECONDS = 300; // 5 min

// Signals that indicate a bot/rate-limit gate → retry with next client
const BOT_CHECK_SIGNALS = [
    'sign in to confirm',
    'confirm you',
    'not a bot',
    'unusual traffic',
    'please sign in',
];

// Signals that mean the track is truly dead → do NOT retry other clients
const HARD_UNAVAILABLE_SIGNALS = [
    'no longer available',
    'has been removed',
    'does not exist',
    'been removed',
    'not exist',
    'unavailable in your country', // region-locked is hard-unavailable
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
        err.retry = true; // Always retry on HTTP errors — transient
        throw err;
    }

    const data = await res.json();
    const playStatus = data?.playabilityStatus?.status ?? 'MISSING';
    const playReason = (data?.playabilityStatus?.reason ?? '').toLowerCase();
    const hasSD = !!data?.streamingData;
    const adaptCount = (data?.streamingData?.adaptiveFormats ?? []).length;
    const fmtCount = (data?.streamingData?.formats ?? []).length;

    console.log(
        `[WORKER PLAYABILITY] ${client.name}: status=${playStatus} ` +
        `streamingData=${hasSD} adaptive=${adaptCount} formats=${fmtCount}` +
        (playReason ? ` reason="${playReason}"` : '')
    );

    if (playStatus !== 'OK') {
        const isBotCheck = BOT_CHECK_SIGNALS.some(s => playReason.includes(s));
        const isHardDead = HARD_UNAVAILABLE_SIGNALS.some(s => playReason.includes(s));

        const err = new Error(data?.playabilityStatus?.reason || playStatus);
        if (isBotCheck) {
            err.code = 'PLAYABILITY_BOT_CHECK';
            err.retry = true;
        } else if (isHardDead) {
            // Track is genuinely gone — no point trying other clients
            err.code = 'PLAYABILITY_UNAVAILABLE';
            err.retry = false;
        } else {
            // Members-only, age-gate, private, sign-in-required, etc.
            // A different client may bypass these — always retry
            err.code = 'PLAYABILITY_GATED';
            err.retry = true;
        }
        throw err;
    }

    if (!hasSD) {
        const err = new Error('No streamingData');
        err.code = 'NO_STREAMING_DATA';
        err.retry = true; // Another client might return streamingData
        throw err;
    }

    return data;
}

// ---------------------------------------------------------------------------
// Format helpers
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

/**
 * Select the best format AND collect all other playable candidates.
 * Returns { url, mimeType, sourceType, itag, clientUsed, candidates[] }
 *
 * candidates[] is sorted: audioOnly first (by descending bitrate), then muxed
 * (by ascending bitrate). The first entry is the chosen primary URL.
 */
function selectBestFormat(playerResponse, clientName) {
    const adaptive = playerResponse.streamingData.adaptiveFormats || [];
    const muxed = playerResponse.streamingData.formats || [];

    const audioCandidates = adaptive.filter(isDirectAudio);
    const muxedCandidates = muxed.filter(isDirectMuxed);

    if (audioCandidates.length === 0 && muxedCandidates.length === 0) {
        const err = new Error(
            `No direct format (${adaptive.length} adaptive, ${muxed.length} muxed — all DASH/incompatible)`
        );
        err.code = 'NO_AUDIO_FORMAT';
        err.retry = true; // A different client might have non-DASH formats
        throw err;
    }

    // Sort audio candidates: prefer itag=140 (stable AAC MP4), then highest bitrate
    audioCandidates.sort((a, b) => {
        if (a.itag === 140 && b.itag !== 140) return -1;
        if (b.itag === 140 && a.itag !== 140) return 1;
        return (b.bitrate || 0) - (a.bitrate || 0);
    });
    muxedCandidates.sort((a, b) => (a.bitrate || 0) - (b.bitrate || 0));

    // All candidates: audioOnly first, then muxed
    const allCandidates = [
        ...audioCandidates.map(f => ({
            url: f.url,
            itag: f.itag,
            mimeType: (f.mimeType || 'audio/mp4').split(';')[0].trim(),
            sourceType: 'audioOnly',
            bitrate: f.bitrate || 0,
        })),
        ...muxedCandidates.map(f => ({
            url: f.url,
            itag: f.itag,
            mimeType: 'video/mp4',
            sourceType: 'muxed',
            bitrate: f.bitrate || 0,
        })),
    ];

    const primary = allCandidates[0];
    console.log(
        `[WORKER CLIENT SUCCESS] ${clientName} chose itag=${primary.itag} ` +
        `mime=${primary.mimeType} sourceType=${primary.sourceType} ` +
        `bitrate=${primary.bitrate} totalCandidates=${allCandidates.length}`
    );

    return {
        url: primary.url,
        mimeType: primary.mimeType,
        sourceType: primary.sourceType,
        itag: primary.itag,
        clientUsed: clientName,
        candidates: allCandidates, // all available playable URLs
    };
}

// ---------------------------------------------------------------------------
// Client waterfall — optional preferred client + exclude list
// ---------------------------------------------------------------------------
async function resolveStream(videoId, preferredClientName, excludeClients) {
    let lastErr = null;

    // Build ordered client list
    let clientList = INNERTUBE_CLIENTS.filter(c => !excludeClients.includes(c.name));

    // Preferred client first
    if (preferredClientName && !excludeClients.includes(preferredClientName)) {
        const idx = clientList.findIndex(c => c.name === preferredClientName);
        if (idx > 0) {
            const preferred = clientList.splice(idx, 1)[0];
            clientList = [preferred, ...clientList];
            console.log(`[WORKER RESOLVE] Preferred client: ${preferredClientName}`);
        }
    }

    if (clientList.length === 0) {
        const err = new Error('All clients excluded by caller');
        err.code = 'ALL_CLIENTS_EXCLUDED';
        throw err;
    }

    for (const client of clientList) {
        console.log(`[WORKER CLIENT TRY] ${client.name}@${client.version} for ${videoId}`);
        try {
            const playerResponse = await tryClient(client, videoId);
            return selectBestFormat(playerResponse, client.name);
        } catch (err) {
            lastErr = err;
            console.log(
                `[WORKER CLIENT FAIL] ${client.name}: code=${err.code} retry=${err.retry} msg=${err.message}`
            );
            if (!err.retry) break; // Hard failure — skip remaining clients
        }
    }

    const finalCode = lastErr?.code || 'ALL_CLIENTS_BLOCKED';
    const err = new Error(lastErr?.message || 'All Innertube clients blocked');
    err.code = finalCode;
    throw err;
}

// ---------------------------------------------------------------------------
// CF Cache helpers — v5
// ---------------------------------------------------------------------------
function cacheKey(videoId) {
    return `https://stream.paaxmusic.app/_cache/v5/${videoId}`;
}

async function cacheRead(videoId) {
    const res = await caches.default.match(cacheKey(videoId));
    if (!res) return null;
    try { return await res.json(); } catch (_) { return null; }
}

// ---------------------------------------------------------------------------
// Error helpers
// ---------------------------------------------------------------------------
const ERROR_HTTP = {
    ALL_CLIENTS_BLOCKED: 503,
    ALL_CLIENTS_EXCLUDED: 503,
    INNERTUBE_403: 503,
    PLAYABILITY_BOT_CHECK: 503,
    PLAYABILITY_GATED: 503,
    PLAYABILITY_UNAVAILABLE: 404,
    NO_STREAMING_DATA: 502,
    NO_AUDIO_FORMAT: 502,
    MISSING_VIDEO_ID: 400,
    INVALID_VIDEO_ID: 400,
};
const ERROR_MSG = {
    ALL_CLIENTS_BLOCKED: 'Stream temporarily unavailable — try again shortly',
    ALL_CLIENTS_EXCLUDED: 'Stream temporarily unavailable — all clients exhausted',
    INNERTUBE_403: 'Stream service rate-limited — try again',
    PLAYABILITY_BOT_CHECK: 'Stream temporarily unavailable — try again shortly',
    PLAYABILITY_GATED: 'Stream temporarily unavailable — try again shortly',
    PLAYABILITY_UNAVAILABLE: 'This track is no longer available',
    NO_STREAMING_DATA: 'Playback is not available right now',
    NO_AUDIO_FORMAT: 'No compatible audio stream found for this track',
    MISSING_VIDEO_ID: 'Missing video ID',
    INVALID_VIDEO_ID: 'Invalid video ID',
};

function jsonError(code, message) {
    const status = ERROR_HTTP[code] || 502;
    const msg = message || ERROR_MSG[code] || 'Playback is not available right now';
    return new Response(JSON.stringify({ error: msg, code }), {
        status,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
}

function extractExpiresAt(cdnUrl) {
    try {
        const u = new URL(cdnUrl);
        const v = u.searchParams.get('expire');
        return v ? parseInt(v, 10) : 0;
    } catch (_) { return 0; }
}

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

    const segments = path.slice(1).split('/');
    const videoId = (segments[segments.length - 1] || '').trim();
    if (!videoId) return jsonError('MISSING_VIDEO_ID');
    if (!/^[a-zA-Z0-9_-]{11}$/.test(videoId)) return jsonError('INVALID_VIDEO_ID');

    // Preferred-client hint (e.g. ?client=ANDROID_VR)
    const preferredClient = url.searchParams.get('client') || null;
    // Excluded clients from Flutter retry blacklist (e.g. ?exclude=ANDROID,IOS)
    const excludeParam = url.searchParams.get('exclude') || '';
    const excludeClients = excludeParam ? excludeParam.split(',').map(s => s.trim()).filter(Boolean) : [];

    const forceResolve = !!preferredClient || excludeClients.length > 0;

    // --- 1. CF Cache lookup (skip if forced to resolve with specific params) --
    if (!forceResolve) {
        const cached = await cacheRead(videoId);
        if (cached?.url) {
            console.log(`[WORKER CACHE HIT] ${videoId} client=${cached.clientUsed ?? '?'} itag=${cached.itag ?? '?'}`);
            return jsonResolveResponse(cached);
        }
    }
    console.log(`[WORKER CACHE MISS] ${videoId}${forceResolve ? ` (forced: client=${preferredClient} exclude=${excludeParam})` : ''}`);

    // --- 2. Resolve --------------------------------------------------------
    console.log(`[WORKER RESOLVE] Starting for ${videoId} exclude=[${excludeClients.join(',')}]`);
    let resolved;
    try {
        resolved = await resolveStream(videoId, preferredClient, excludeClients);
    } catch (err) {
        const code = err?.code || 'ALL_CLIENTS_BLOCKED';
        console.error(`[WORKER FINAL ERROR] ${videoId}: code=${code} msg=${err.message}`);
        return jsonError(code, err.message);
    }

    const expiresAt = extractExpiresAt(resolved.url);
    const payload = {
        url: resolved.url,
        mimeType: resolved.mimeType,
        sourceType: resolved.sourceType,
        expiresAt,
        clientUsed: resolved.clientUsed,
        itag: resolved.itag,
        candidates: resolved.candidates,  // all playable URLs from this client
    };

    // --- 3. Cache (only for non-forced resolves) ---------------------------
    if (!forceResolve) {
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

    console.log(`[WORKER RESOLVE RESULT] ${videoId} client=${resolved.clientUsed} itag=${resolved.itag} candidates=${resolved.candidates.length}`);
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
