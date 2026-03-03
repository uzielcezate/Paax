# 🎵 Beaty — YouTube Music Client

A full-stack music streaming app: **Flutter** frontend + **FastAPI** backend powered by `ytmusicapi`.

```
BeatyRepo/
├── frontend/        # Flutter app (web + android)
├── backend/         # FastAPI app (Railway-ready)
├── docs/            # Deployment guides & references
├── .gitignore
└── README.md
```

---

## 🚀 Quick Start

### 1. Backend (FastAPI)

```bash
cd backend
python -m venv venv
# Windows:
venv\Scripts\activate
# macOS/Linux:
source venv/bin/activate

pip install -r requirements.txt
uvicorn main:app --reload --host 0.0.0.0 --port 8000
```

**Health check:** <http://localhost:8000/health>

> **Auth (local):** Place your `oauth.json` in `backend/` for authenticated endpoints.  
> **Auth (production):** Set `YTMUSIC_OAUTH_JSON` env var to the file's JSON content.

### 2. Frontend (Flutter)

```bash
cd frontend
flutter pub get

# Web — local dev (fast iteration in Chrome)
flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8000

# Web — test from a real phone via LAN (replace with YOUR PC's local IP)
flutter run -d chrome --dart-define=API_BASE_URL=http://192.168.x.x:8000

# Android emulator — backend on same machine
flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:8000

# Production — point to Railway deployment
flutter run -d chrome --dart-define=API_BASE_URL=https://beaty.up.railway.app
```

> `API_BASE_URL` defaults to `http://localhost:8000` when `--dart-define` is omitted.

---

## 📱 Testing from a Real Phone (LAN)

1. Find your PC IP: `ipconfig` → IPv4 Address (e.g. `192.168.1.10`).
2. Make sure Windows Firewall allows port `8000` inbound.
3. Run backend: `uvicorn main:app --host 0.0.0.0 --port 8000`
4. Run Flutter with: `--dart-define=API_BASE_URL=http://192.168.1.10:8000`

---

## 🔧 Environment Variables (Backend)

| Variable | Required | Description |
|---|---|---|
| `YTMUSIC_OAUTH_JSON` | Production only | Full content of `oauth.json` |
| `FRONTEND_ORIGINS` | Optional | Comma-separated frontend URLs for CORS e.g. `https://beaty.vercel.app` |
| `PORT` | Railway auto-sets | Port uvicorn listens on |

---

## 🚂 Railway Deployment

See [`docs/RAILWAY_DEPLOY_STEPS_ES.txt`](docs/RAILWAY_DEPLOY_STEPS_ES.txt) for the full Spanish guide.

**Quick reference:**
- Root Directory: `backend`
- Start command: `uvicorn main:app --host 0.0.0.0 --port $PORT`
- Variables: `YTMUSIC_OAUTH_JSON`, `FRONTEND_ORIGINS`

---

## 🌐 Frontend Deploy (Vercel/Netlify) — Coming Soon

High-level plan:
1. Build: `flutter build web --dart-define=API_BASE_URL=https://<railway-url>`
2. Deploy `frontend/build/web/` to Vercel or Netlify.
3. Set `FRONTEND_ORIGINS` in Railway to the deployed frontend URL.
