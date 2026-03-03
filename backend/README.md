# Beaty Backend — FastAPI

YouTube Music API wrapper powered by `ytmusicapi`.

## Running Locally

```bash
python -m venv venv
# Windows: venv\Scripts\activate
pip install -r requirements.txt

# With local oauth.json (authenticated):
uvicorn main:app --reload --host 0.0.0.0 --port 8000

# Unauthenticated (public content only):
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `YTMUSIC_OAUTH_JSON` | **Production** | Full JSON content of `oauth.json`. On startup the backend writes it to a temp file and initialises YTMusic with it. |
| `FRONTEND_ORIGINS` | Optional | Comma-separated list of allowed frontend origins for CORS. Example: `https://beaty.vercel.app,https://beaty.netlify.app`. Localhost/127.0.0.1/10.0.2.2 are always allowed. |
| `PORT` | Railway sets automatically | Port for uvicorn to listen on. |

### How to get YTMUSIC_OAUTH_JSON

1. Run `ytmusicapi oauth` locally and complete the OAuth flow.
2. This creates `oauth.json` in your working directory.
3. Copy the full content of that file.
4. In Railway → Variables → Add `YTMUSIC_OAUTH_JSON` → paste the full JSON.

> ⚠️ Never commit `oauth.json` to git. It is in `.gitignore`.

## Endpoints

| Method | Path | Auth Required | Description |
|---|---|---|---|
| GET | `/health` | No | Health check + auth status |
| GET | `/` | No | Service info |
| GET | `/auth/status` | No | Is backend authenticated? |
| GET | `/search` | No | Search (songs, albums, artists…) |
| GET | `/home` | Recommended | Home feed |
| GET | `/charts` | No | Top charts by country |
| GET | `/moods` | No | Mood categories |
| GET | `/genre/{slug}` | No | Genre page |
| GET | `/artist/{id}` | No | Artist info |
| GET | `/album/{id}` | No | Album tracks |
| GET | `/song/{id}` | No | Song info |
| GET | `/lyrics/{id}` | No | Lyrics |
| GET | `/watch` | No | Watch playlist / radio |
| GET | `/library/liked` | **Yes** | Liked songs |
| GET | `/library/playlists` | **Yes** | Library playlists |
| POST | `/rate` | **Yes** | Rate a song |

## Railway Deploy

- **Root Directory**: `backend`
- **Start Command**: `uvicorn main:app --host 0.0.0.0 --port $PORT`
- See `../docs/RAILWAY_DEPLOY_STEPS_ES.txt` for the full step-by-step guide.
