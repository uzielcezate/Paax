from fastapi import FastAPI, HTTPException, Body, Query
from fastapi.middleware.cors import CORSMiddleware
from ytmusicapi import YTMusic
from typing import Optional, List, Dict, Any
from contextlib import asynccontextmanager
import os
import json
import tempfile
from ytmusicapi.navigation import nav, SINGLE_COLUMN_TAB, SECTION_LIST_ITEM, GRID_ITEMS, GRID, CAROUSEL_CONTENTS
from ytmusicapi.parsers.library import parse_albums
try:
    from ytmusicapi.continuations import get_continuation_params
except ImportError:
    pass

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------
yt: YTMusic = None  # type: ignore
_tmp_oauth_path: str | None = None
_is_authenticated: bool = False


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize YTMusic on startup; clean up temp files on shutdown."""
    global yt, _tmp_oauth_path, _is_authenticated

    oauth_json_str = os.environ.get("YTMUSIC_OAUTH_JSON")

    if oauth_json_str:
        # Production: env var contains the full oauth.json content
        try:
            tmp = tempfile.NamedTemporaryFile(
                mode="w", suffix=".json", delete=False
            )
            tmp.write(oauth_json_str)
            tmp.close()
            _tmp_oauth_path = tmp.name
            yt = YTMusic(_tmp_oauth_path)
            _is_authenticated = True
            print("[Beaty] YTMusic initialized with OAuth via env var ✓")
        except Exception as e:
            print(f"[Beaty] OAuth env init failed: {e}. Falling back to unauthenticated.")
            yt = YTMusic()
    elif os.path.exists("oauth.json"):
        # Local dev: oauth.json file present
        try:
            yt = YTMusic("oauth.json")
            _is_authenticated = True
            print("[Beaty] YTMusic initialized with local oauth.json ✓")
        except Exception as e:
            print(f"[Beaty] Local oauth.json failed: {e}. Falling back to unauthenticated.")
            yt = YTMusic()
    else:
        # Unauthenticated — public content only
        yt = YTMusic()
        print("[Beaty] YTMusic running unauthenticated (public content only)")

    yield  # App runs here

    # Cleanup
    if _tmp_oauth_path and os.path.exists(_tmp_oauth_path):
        os.unlink(_tmp_oauth_path)
        print("[Beaty] Cleaned up temp oauth file.")


# ---------------------------------------------------------------------------
# App + CORS
# ---------------------------------------------------------------------------
app = FastAPI(lifespan=lifespan)

# CORS: always allow localhost/127.0.0.1 (local dev + Android emulator via 10.0.2.2).
# For production, set FRONTEND_ORIGINS env var to a comma-separated list of
# your deployed frontend origin(s), e.g.:
#   FRONTEND_ORIGINS=https://beaty.vercel.app,https://beaty.netlify.app
_local_origins_regex = r"https?://(localhost|127\.0\.0\.1|10\.0\.2\.2)(:\d+)?"
_extra_origins_raw = os.environ.get("FRONTEND_ORIGINS", "")
_extra_origins = [o.strip() for o in _extra_origins_raw.split(",") if o.strip()]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_extra_origins,        # exact production origins
    allow_origin_regex=_local_origins_regex,  # local dev (always)
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health")
def health():
    """Railway / uptime health check."""
    return {"ok": True, "authenticated": _is_authenticated}


@app.get("/")
def read_root():
    return {"status": "running", "service": "Beaty YouTube Music Backend"}


@app.get("/auth/status")
def get_auth_status():
    """Check if the backend is running in authenticated mode."""
    return {"authenticated": _is_authenticated}

@app.post("/auth/reload")
def reload_auth():
    """Reload the YTMusic instance from local oauth.json (local dev only)."""
    global yt, _is_authenticated
    if os.path.exists("oauth.json"):
        try:
            yt = YTMusic("oauth.json")
            _is_authenticated = True
            return {"status": "reloaded", "authenticated": True}
        except Exception as e:
            return {"status": "error", "detail": str(e)}
    yt = YTMusic()
    _is_authenticated = False
    return {"status": "reloaded", "authenticated": False}

# --- Search ---

@app.get("/search")
def search(q: str, filter: str = None, limit: int = 20):
    """
    Search for content.
    filter options: songs, videos, albums, artists, playlists, community_playlists, featured_playlists, uploads
    """
    try:
        results = yt.search(query=q, filter=filter, limit=limit)
        return {"data": results}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# --- Home / Discovery ---

@app.get("/home")
def get_home():
    try:
        return yt.get_home()
    except Exception as e:
         # get_home can be fickle unauthenticated or with certain locales
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/charts")
def get_charts(country: str = 'US'):
    try:
        return yt.get_charts(country=country)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/moods")
def get_moods():
    try:
        return yt.get_mood_categories()
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/moods/{params}")
def get_mood_playlists(params: str):
    try:
        return yt.get_mood_playlists(params)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# --- Artist ---

# --- Artist ---

@app.get("/home/discover")
def get_home_discover():
    # ... existing code ...
    try:
        home = yt.get_home(limit=3) 
        # Usually home has sections like "New releases", "Quick picks", etc.
        # We need to parse this into a format our app understands
        return home
    except Exception as e:
        print(f"Error fetching home: {e}")
        return []

@app.get("/home/charts")
def get_home_charts(country: str = 'US'):
    try:
        # Fetch charts for specific country
        c_code = country if country != 'Global' else 'ZZ'
        charts = yt.get_charts(country=c_code)
        
        response = {
            "tracks": [],
            "albums": [],
            "artists": []
        }

        # 1. Top Songs -> Tracks
        if 'songs' in charts and 'items' in charts['songs']:
            for item in charts['songs']['items']:
                # Ensure it's a song, not a video/playlist
                response['tracks'].append(item)
        elif 'videos' in charts and 'items' in charts['videos']:
             # Sometimes charts return videos as top songs
             # We treat them as tracks if they have videoId
             for item in charts['videos']['items']:
                 if 'videoId' in item:
                     response['tracks'].append(item)

        # 2. Top Albums -> Albums
        # ytmusicapi charts sometimes have 'albums' key, sometimes 'trending'
        # We might need to fetch trending albums separately if not in get_charts?
        # get_charts usually has 'trending' section which might be albums
        # For now, if 'albums' exists use it.
        if 'albums' in charts and 'items' in charts['albums']:
            response['albums'] = charts['albums']['items']
        
        # 3. Top Artists -> Artists
        if 'artists' in charts and 'items' in charts['artists']:
            response['artists'] = charts['artists']['items']
            
        return response

    except Exception as e:
        print(f"Error fetching charts for {country}: {e}")
        return {"tracks": [], "albums": [], "artists": []}

# Genre Params Mapping (derived from yt.get_mood_categories)
GENRE_PARAMS = {
    "pop": "ggMPOg1uX3d4cnZHdWxmd2ZP",
    "rock": "ggMPOg1uX0xRR3hPZDlIWjd6",
    # "latin": "ggMPOg1uX1FXZWMwYTdTRlRh", # Pop Latino
    "hip hop": "ggMPOg1uXzdzb2Rub29zaGdl",
    "indie": "ggMPOg1uX21NWWpBbU01SDgy",
    "r&b": "ggMPOg1uX2JxQ2hxc2J5UFhR",
    "k-pop": "ggMPOg1uX0JrbjBDOFFPSzJW",
    "jazz": "ggMPOg1uX3lPcDFRaE9wM1BS",
    "metal": "ggMPOg1uXzdlSXhKZ0hMV1Z4",
    "classical": "ggMPOg1uXzNiX3JjZndocTZy", 
    # Add others as needed or rely on search
}

@app.get("/genre/{slug}")
def get_genre_page(slug: str, country: str = 'US'):
    try:
        response = {
            "title": slug.title(),
            "playlists": [],
            "tracks": [],
            "artists": []
        }
        
        lower_slug = slug.lower()
        
        # 1. Fetch Playlists (Prefer direct legacy params if known, else search)
        if lower_slug in GENRE_PARAMS:
            try:
                # fetch specific mood playlists
                playlists = yt.get_mood_playlists(GENRE_PARAMS[lower_slug])
                response['playlists'] = playlists
            except Exception as e:
                print(f"Error fetching mood playlists for {slug}: {e}")
                
        # If no playlists found via params (or no params), search for them
        if not response['playlists']:
             search_res = yt.search(f"{slug} playlists", filter="playlists", limit=10)
             response['playlists'] = search_res

        # 2. Fetch Top Tracks (Search)
        response['tracks'] = yt.search(f"{slug} top songs", filter="songs", limit=10)

        # 3. Fetch Top Artists (Search)
        response['artists'] = yt.search(f"{slug} artists", filter="artists", limit=10)
        
        return response

    except Exception as e:
        print(f"Error fetching genre page for {slug}: {e}")
        return {"title": slug, "playlists": [], "tracks": [], "artists": []}

@app.get("/home/top")
def get_home_top(genre: str, country: str = 'US'):
    try:
        # Search for top content in this genre
        # We perform 3 searches to get structured data
        
        limit = 10
        
        # 1. Top Tracks
        tracks_results = yt.search(f"{genre} top songs", filter="songs", limit=limit)
        
        # 2. Top Albums
        albums_results = yt.search(f"{genre} top albums", filter="albums", limit=limit)
        
        # 3. Top Artists
        artists_results = yt.search(f"{genre} top artists", filter="artists", limit=limit)
        
        return {
            "tracks": tracks_results,
            "albums": albums_results,
            "artists": artists_results
        }
        
    except Exception as e:
        print(f"Error fetching top for {genre}: {e}")
        return {"tracks": [], "albums": [], "artists": []}
        
    except Exception as e:
        print(f"Error fetching category {category}: {e}")
        return []

@app.get("/artist/{channelId}")
def get_artist(channelId: str):
    try:
        # Standard fetch
        artist = yt.get_artist(channelId)
        return artist
    except Exception as e:
        print(f"Error fetching artist {channelId}: {e}")
        # Fallback: return minimal structure to prevent 500 in app
        # We could try to fetch just the header?
        # For now, return a valid empty structure so app shows "Unknown" but doesn't crash
        return {
            "name": "Artist (Error)",
            "channelId": channelId,
            "thumbnails": [],
            "songs": {"results": []},
            "albums": {"results": []},
            "singles": {"results": []},
            "related": {"results": []}
        }

@app.get("/artist/{channelId}/albums")
def get_artist_albums(channelId: str, params: str = None):
    try:
        # get_artist_albums usually requires the 'browseId' and sometimes 'params' from the artist details
        # If the client only has channelId, they might need to fetch artist first to get params for "See All"
        # However, ytmusicapi has a method get_artist_albums(channelId, params)
        return yt.get_artist_albums(channelId=channelId, params=params)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/artist/{channelId}/albums/page")
def get_artist_albums_page(channelId: str, params: str = None, ctoken: str = None):
    try:
        endpoint = "browse"
        # Note: If ctoken is present, we treat it as a continuation request.
        # But we still need channelId to form the basic body? 
        # Actually ytmusicapi sends the same body for continuations sometimes, but mainly the additionalParams matter.
        
        if ctoken:
            additionalParams = "&ctoken=" + ctoken + "&continuation=" + ctoken
            body = {"browseId": channelId, "params": params}
            response = yt._send_request(endpoint, body, additionalParams)
            
            # Parse continuation
            if "continuationContents" in response:
                contents = response["continuationContents"]
                if "gridContinuation" in contents:
                    results = contents["gridContinuation"]
                elif "musicShelfContinuation" in contents:
                     results = contents["musicShelfContinuation"]
                else:
                    results = {}
            else:
                 results = {}
            
            items_raw = results.get('items') or results.get('contents') or []
            container = results

        else:
            # First page
            body = {"browseId": channelId, "params": params}
            response = yt._send_request(endpoint, body)
            
            # Parse first page using nav helpers
            # access standard tab > section list > item
            results_root = nav(response, SINGLE_COLUMN_TAB + SECTION_LIST_ITEM)
            
            # Identify container (Grid or MusicShelf)
            grid = nav(results_root, GRID, True)
            musicShelf = nav(results_root, ['musicShelfRenderer'], True)
            
            if grid:
                 items_raw = grid.get('items', [])
                 container = grid
            elif musicShelf:
                 items_raw = musicShelf.get('contents', [])
                 container = musicShelf
            else:
                 # Fallback for Carousel?
                 carousel = nav(results_root, CAROUSEL_CONTENTS, True)
                 if carousel:
                     items_raw = carousel
                     container = {} # Carousels typically don't have continuations this way?
                 else:
                     items_raw = []
                     container = {}

        # Parse items using library parser
        albums = parse_albums(items_raw)
        
        # Extract next token
        next_token = None
        if "continuations" in container:
            try:
                # continuations is a list
                next_token = container["continuations"][0]["nextContinuationData"]["continuation"]
            except:
                pass
                
        return {"items": albums, "nextPageToken": next_token}

    except Exception as e:
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

# --- Album ---

@app.get("/album/{browseId}")
def get_album(browseId: str):
    try:
        data = None
        try:
            data = yt.get_album(browseId)
        except Exception:
            # Fallback to playlist
            try:
                data = yt.get_playlist(browseId)
                # Normalize playlist to look like album for frontend
                # Playlists have 'author' dict usually, albums have 'artists' list
                if 'author' in data and 'artists' not in data:
                    data['artists'] = [data['author']] if isinstance(data['author'], dict) else [{'name': str(data['author']), 'id': ''}]
            except Exception as e2:
                raise Exception(f"Failed to fetch album or playlist: {e2}")

        # Ensure tracks have duration_seconds
        if 'tracks' in data:
            for track in data['tracks']:
                if 'duration_seconds' not in track or track['duration_seconds'] is None:
                    if 'duration' in track and track['duration']:
                        try:
                            parts = track['duration'].strip().split(':')
                            val = 0
                            for part in parts:
                                val = val * 60 + int(part)
                            track['duration_seconds'] = val
                        except:
                            track['duration_seconds'] = 0
                    else:
                        track['duration_seconds'] = 0
                        
        return data
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# --- Track ---

@app.get("/song/{videoId}")
def get_song(videoId: str):
    try:
        return yt.get_song(videoId)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/song/{videoId}/related")
def get_song_related(videoId: str):
    try:
         # Note: get_song_related might require get_watch_playlist effectively
         # there isn't a direct "get_song_related" in all versions, 
         # but get_watch_playlist gives related tracks.
         # Actually ytmusicapi has get_song_related(browseId) but input is typically from get_song trackingUrl?
         # Let's check api docs. `get_song_related(browseId)` where browseId is from get_song().
         # If client only has videoId, we might need to get_song first or use get_watch_playlist.
         # For simplicity, let's try get_watch_playlist as it is the standard "radio".
         return yt.get_watch_playlist(videoId=videoId)
    except Exception as e:
         raise HTTPException(status_code=500, detail=str(e))

@app.get("/lyrics/{videoId}")
def get_lyrics(videoId: str):
    try:
        # Need browseId for lyrics. Usually obtained from get_watch_playlist
        watch = yt.get_watch_playlist(videoId=videoId)
        if 'lyrics' in watch and watch['lyrics']:
             return yt.get_lyrics(browseId=watch['lyrics'])
        return {"error": "No lyrics found"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# --- Queue / Radio ---

@app.get("/watch")
def get_watch_playlist(videoId: str = None, playlistId: str = None):
    try:
        return yt.get_watch_playlist(videoId=videoId, playlistId=playlistId)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# --- Library (Authenticated) ---

@app.get("/library/liked")
def get_liked_songs(limit: int = 100):
    try:
        return yt.get_liked_songs(limit=limit)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/library/playlists")
def get_library_playlists(limit: int = 25):
    try:
        return yt.get_library_playlists(limit=limit)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/rate")
def rate_song(videoId: str = Body(...), rating: str = Body(...)):
    """rating: 'LIKE', 'INDIFFERENT', 'DISLIKE'"""
    try:
        return yt.rate_song(videoId, rating)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/playlists")
def create_playlist(title: str = Body(...), description: str = Body("")):
    try:
        return yt.create_playlist(title, description)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.delete("/playlists/{playlistId}")
def delete_playlist(playlistId: str):
    try:
        return yt.delete_playlist(playlistId)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/playlists/{playlistId}/items")
def add_playlist_items(playlistId: str, videoIds: List[str] = Body(...)):
    try:
        return yt.add_playlist_items(playlistId, videoIds)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.delete("/playlists/{playlistId}/items")
def remove_playlist_items(playlistId: str, videoIds: List[str] = Body(...)):
    try:
        return yt.remove_playlist_items(playlistId, videoIds)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
