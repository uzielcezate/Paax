/**
 * Paax Stream Worker — stream.paaxmusic.app
 * v6 — diverse candidates + exclude-client parameter + precise error codes
 *      + debug metadata in every response (attemptedClients, excludedClients,
 *        chosenClient, chosenItag, candidateCount, resolvePath, clientErrors)
 *
 * Retry logic change: PLAYABILITY_GATED / BOT_CHECK → retry=true (per client)
 * 400 from Innertube → retry=true, surfaces in clientErrors[]
 */

// ---------------------------------------------------------------------------
// Innertube client profiles
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
const CACHE_TTL_SECONDS = 300;

const BOT_CHECK_SIGNALS = [
    'sign in to confirm', 'confirm you', 'not a bot', 'unusual traffic', 'please sign in',
];
const HARD_UNAVAILABLE_SIGNALS = [
    'no longer available', 'has been removed', 'does not exist', 'been removed', 'not exist',
    'unavailable in your country',
];

// ---------------------------------------------------------------------------
// Innertube — single client attempt
// Returns { playerResponse, clientErrors: [{client, code, msg}] }
// ---------------------------------------------------------------------------
async function tryClient(client, videoId) {
    const ctx = {
        clientName: client.name, clientVersion: client.version,
        hl: 'en', gl: 'US', utcOffsetMinutes: 0, ...client.extra,
    };
    const body = {
        videoId, contentCheckOk: true, racyCheckOk: true,
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
        // 400 = bad client config or malformed request — transient, try next client
        // 403 = rate-limited — transient
        const code = `INNERTUBE_HTTP_${res.status}`;
        let snippet = '';
        try { snippet = (await res.text()).substring(0, 200); } catch (_) { }
        console.log(`[WORKER CLIENT FAIL] ${client.name} HTTP=${res.status}: ${snippet}`);
        const err = new Error(`${client.name}: HTTP ${res.status} — ${snippet.substring(0, 80)}`);
        err.code = code;
        err.retry = true; // Always retry on HTTP errors
        err.clientName = client.name;
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
        const originalReason = data?.playabilityStatus?.reason || playStatus;

        const err = new Error(`${client.name}: ${originalReason}`);
        err.clientName = client.name;
        if (isHardDead) {
            err.code = 'PLAYABILITY_UNAVAILABLE';
            err.retry = false;
        } else {
            // Bot-check, gated (members/age), sign-in, private — retry with next client
            err.code = isBotCheck ? 'PLAYABILITY_BOT_CHECK' : 'PLAYABILITY_GATED';
            err.retry = true;
        }
        throw err;
    }

    if (!hasSD) {
        const err = new Error(`${client.name}: No streamingData`);
        err.code = 'NO_STREAMING_DATA';
        err.retry = true;
        err.clientName = client.name;
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
    if (!url || !mime.startsWith('audio/')) return false;
    if (!mime.includes('mp4') && !mime.includes('m4a') && !mime.includes('aac')) return false;
    if (mime.includes('webm') || mime.includes('opus')) return false;
    return !isDashUrl(url);
}

function isDirectMuxed(fmt) {
    const mime = (fmt.mimeType || '').toLowerCase();
    const url = fmt.url || '';
    if (!url || !mime.startsWith('video/mp4')) return false;
    return !isDashUrl(url);
}

function selectBestFormat(playerResponse, clientName) {
    const adaptive = playerResponse.streamingData.adaptiveFormats || [];
    const muxed = playerResponse.streamingData.formats || [];

    const audioCandidates = adaptive.filter(isDirectAudio);
    const muxedCandidates = muxed.filter(isDirectMuxed);

    if (audioCandidates.length === 0 && muxedCandidates.length === 0) {
        const err = new Error(`${clientName}: No direct format (${adaptive.length} adaptive, ${muxed.length} muxed — all DASH/incompatible)`);
        err.code = 'NO_AUDIO_FORMAT';
        err.retry = true;
        err.clientName = clientName;
        throw err;
    }

    audioCandidates.sort((a, b) => {
        if (a.itag === 140 && b.itag !== 140) return -1;
        if (b.itag === 140 && a.itag !== 140) return 1;
        return (b.bitrate || 0) - (a.bitrate || 0);
    });
    muxedCandidates.sort((a, b) => (a.bitrate || 0) - (b.bitrate || 0));

    const allCandidates = [
        ...audioCandidates.map(f => ({
            url: f.url, itag: f.itag,
            mimeType: (f.mimeType || 'audio/mp4').split(';')[0].trim(),
            sourceType: 'audioOnly', bitrate: f.bitrate || 0,
        })),
        ...muxedCandidates.map(f => ({
            url: f.url, itag: f.itag,
            mimeType: 'video/mp4', sourceType: 'muxed', bitrate: f.bitrate || 0,
        })),
    ];

    const primary = allCandidates[0];
    console.log(
        `[WORKER CLIENT SUCCESS] ${clientName} chose itag=${primary.itag} ` +
        `mime=${primary.mimeType} sourceType=${primary.sourceType} ` +
        `candidates=${allCandidates.length}`
    );

    return { primary, allCandidates, clientUsed: clientName };
}

// ---------------------------------------------------------------------------
// resolveStream — client waterfall with per-client error tracking
// Returns { primary, allCandidates, clientUsed, attemptedClients, clientErrors }
// ---------------------------------------------------------------------------
async function resolveStream(videoId, preferredClientName, excludeClients) {
    let lastErr = null;
    const attemptedClients = [];
    const clientErrors = []; // [{client, code, msg}]

    let clientList = INNERTUBE_CLIENTS.filter(c => !excludeClients.includes(c.name));

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
        attemptedClients.push(client.name);
        console.log(`[WORKER CLIENT TRY] ${client.name}@${client.version} videoId=${videoId}`);
        try {
            const playerResponse = await tryClient(client, videoId);
            const result = selectBestFormat(playerResponse, client.name);
            return {
                primary: result.primary,
                allCandidates: result.allCandidates,
                clientUsed: client.name,
                attemptedClients,
                clientErrors,
            };
        } catch (err) {
            lastErr = err;
            clientErrors.push({
                client: err.clientName || client.name,
                code: err.code || 'UNKNOWN',
                msg: err.message,
            });
            console.log(`[WORKER CLIENT FAIL] ${client.name}: code=${err.code} retry=${err.retry} msg=${err.message}`);
            if (!err.retry) break;
        }
    }

    const finalErr = new Error(lastErr?.message || 'All Innertube clients blocked');
    finalErr.code = lastErr?.code || 'ALL_CLIENTS_BLOCKED';
    finalErr.attemptedClients = attemptedClients;
    finalErr.clientErrors = clientErrors;
    throw finalErr;
}

// ---------------------------------------------------------------------------
// CF Cache helpers — v6
// ---------------------------------------------------------------------------
function cacheKey(videoId) {
    return `https://stream.paaxmusic.app/_cache/v6/${videoId}`;
}

async function cacheRead(videoId) {
    const res = await caches.default.match(cacheKey(videoId));
    if (!res) return null;
    try { return await res.json(); } catch (_) { return null; }
}

// ---------------------------------------------------------------------------
// Error maps
// ---------------------------------------------------------------------------
const ERROR_HTTP = {
    ALL_CLIENTS_BLOCKED: 503,
    ALL_CLIENTS_EXCLUDED: 503,
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
    PLAYABILITY_BOT_CHECK: 'Stream temporarily unavailable — try again shortly',
    PLAYABILITY_GATED: 'Stream temporarily unavailable — try again shortly',
    PLAYABILITY_UNAVAILABLE: 'This track is no longer available',
    NO_STREAMING_DATA: 'Playback is not available right now',
    NO_AUDIO_FORMAT: 'No compatible audio stream found',
    MISSING_VIDEO_ID: 'Missing video ID',
    INVALID_VIDEO_ID: 'Invalid video ID',
};

function jsonError(code, message, extra) {
    const status = ERROR_HTTP[code] || 502;
    const msg = message || ERROR_MSG[code] || 'Playback is not available right now';
    return new Response(JSON.stringify({ error: msg, code, ...extra }), {
        status,
        headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
    });
}

function extractExpiresAt(cdnUrl) {
    try {
        const v = new URL(cdnUrl).searchParams.get('expire');
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

    const preferredClient = url.searchParams.get('client') || null;
    const excludeParam = url.searchParams.get('exclude') || '';
    const excludeClients = excludeParam
        ? excludeParam.split(',').map(s => s.trim()).filter(Boolean)
        : [];

    const forceResolve = !!preferredClient || excludeClients.length > 0;

    // --- Cache hit (skip for forced resolves) --------------------------------
    if (!forceResolve) {
        const cached = await cacheRead(videoId);
        if (cached?.url) {
            console.log(`[WORKER CACHE HIT] ${videoId} client=${cached.chosenClient ?? '?'} itag=${cached.chosenItag ?? '?'}`);
            return jsonResolveResponse({ ...cached, resolvePath: 'cache' });
        }
    }

    console.log(`[WORKER CACHE MISS] ${videoId} exclude=[${excludeClients.join(',')}]`);

    // --- Fresh resolve -------------------------------------------------------
    let resolved;
    try {
        resolved = await resolveStream(videoId, preferredClient, excludeClients);
    } catch (err) {
        const code = err?.code || 'ALL_CLIENTS_BLOCKED';
        console.error(`[WORKER FINAL ERROR] ${videoId}: code=${code} msg=${err.message}`);
        return jsonError(code, err.message, {
            attemptedClients: err.attemptedClients || [],
            excludedClients: excludeClients,
            clientErrors: err.clientErrors || [],
        });
    }

    const primary = resolved.primary;
    const expiresAt = extractExpiresAt(primary.url);

    const payload = {
        // Core playback
        url: primary.url,
        mimeType: primary.mimeType,
        sourceType: primary.sourceType,
        expiresAt,
        clientUsed: resolved.clientUsed,
        itag: primary.itag,
        candidates: resolved.allCandidates,
        // Debug metadata
        chosenClient: resolved.clientUsed,
        chosenItag: primary.itag,
        candidateCount: resolved.allCandidates.length,
        attemptedClients: resolved.attemptedClients,
        excludedClients: excludeClients,
        clientErrors: resolved.clientErrors,
        resolvePath: 'fresh',
    };

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

    console.log(`[WORKER RESULT] ${videoId} client=${resolved.clientUsed} itag=${primary.itag} candidates=${resolved.allCandidates.length} attempted=[${resolved.attemptedClients.join(',')}]`);
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
