# ConnectCall Backend

Signaling backend for the **ConnectCall** 1-to-1 WebRTC calling application.

> **Architecture Notice**: This FastAPI server functions strictly as a **signaling and call state relay**. It handles WebSocket signaling, Firebase ID token verification, user-to-connection mapping, call lifecycle management, and WebRTC SDP/ICE relaying. It is **not** a media server—audio and video streams travel peer-to-peer directly between Flutter clients via WebRTC.

---

## 1. Prerequisites

- Python 3.10+
- Firebase Project with Firebase Authentication enabled
- Firebase Admin SDK service account key JSON file

---

## 2. Local Setup & Execution

### Step 1: Virtual Environment Setup
From the `backend/` directory:

#### On Windows (PowerShell):
```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```

#### On Linux / macOS:
```bash
python3 -m venv .venv
source .venv/bin/activate
```

### Step 2: Install Dependencies
```bash
pip install -r requirements.txt
```

### Step 3: Environment Configuration
Copy `.env.example` to create `.env`:
```powershell
Copy-Item .env.example .env
```
*(or on Linux/macOS: `cp .env.example .env`)*

Configure the environment variables in `.env`:
- `PROJECT_NAME`: Service display name (default: `"ConnectCall Signaling Server"`).
- `ENVIRONMENT`: `"development"` or `"production"`.
- `HOST`: Bind host address (default: `"0.0.0.0"`).
- `PORT`: Bind port (default: `8000`).
- `CORS_ORIGINS`: Comma-separated or JSON list of allowed origins (e.g. `["*"]` or `*`).
- `FIREBASE_CREDENTIALS_PATH`: Relative or absolute path to your Firebase service account private key JSON file.
- `AUTH_TIMEOUT_SECONDS`: Timeout for client to complete auth handshake upon connection (default: `10.0`).

### Step 4: Run Locally
```bash
uvicorn app.main:app --host 0.0.0.0 --port 8000
```
For auto-reload during local development:
```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

---

## 3. Firebase Admin Credentials Setup

The ConnectCall backend requires Firebase Admin SDK credentials to verify client ID tokens:

1. Open the [Firebase Console](https://console.firebase.google.com/).
2. Select your Firebase project -> **Project Settings** (gear icon) -> **Service accounts**.
3. Under **Firebase Admin SDK**, select Python and click **Generate new private key**.
4. Download the generated JSON file and place it in an uncommitted location, e.g. `backend/secrets/firebase-service-account.json`.
5. Point `FIREBASE_CREDENTIALS_PATH` in your `.env` to this file path.

> [!CAUTION]
> **SECURITY INVARIANTS**:
> - Never commit your Firebase service-account JSON file or `.env` file to version control.
> - `.gitignore` is configured to ignore all `*firebase*.json`, `serviceAccountKey.json`, `*credentials*.json`, and `.env` files.
> - The backend uses this service account purely to verify user ID tokens and retrieve canonical UIDs. It never leaks credentials or internal exceptions to clients.

---

## 4. Production Deployment

The backend is cloud-agnostic and runs with standard ASGI server commands.

### Production ASGI Command
Configure your container or process supervisor to run:
```bash
uvicorn app.main:app --host 0.0.0.0 --port $PORT
```
*(where `$PORT` is the environment variable assigned by your hosting platform, typically 8080, 8000, or 443).*

### Production Deployment Checklist
1. **Provide Firebase Credentials Securely**: Mount the service-account JSON file into the container securely via a secret volume or secure file path, and set `FIREBASE_CREDENTIALS_PATH` to that location.
2. **Environment Variables**:
   - `ENVIRONMENT="production"`
   - `CORS_ORIGINS`: Specific client domain(s) or origins.
   - `AUTH_TIMEOUT_SECONDS=10.0`
3. **TLS Termination / HTTPS & WSS**:
   - Expose the HTTP/WebSocket service over HTTPS / WSS through an ingress, reverse proxy (e.g. Nginx, Caddy), or cloud load balancer.
4. **Health Check**:
   - Configure platform readiness/liveness probes to target `GET /health`.
   - Returns HTTP 200 `{"status": "ok"}` unconditionally without requiring authentication or Firebase credentials.

---

## 5. WebSocket Signaling Endpoints

The signaling endpoint path is `/ws/signaling`.

- **Local Development**:
  ```
  ws://<BACKEND_HOST>:8000/ws/signaling
  ```
- **Production (TLS-encrypted)**:
  ```
  wss://<BACKEND_HOST>/ws/signaling
  ```

> [!NOTE]
> The Flutter client must make `BACKEND_HOST` configurable so it can target local development (`ws://...`) or production deployments (`wss://...`).

### Authentication Flow
1. Connect to `/ws/signaling` (no token in query string or URL).
2. Within 10 seconds, send the auth payload:
   ```json
   {
     "type": "auth",
     "token": "<FIREBASE_ID_TOKEN>"
   }
   ```
3. Receive success confirmation:
   ```json
   {
     "type": "auth.success",
     "userId": "<VERIFIED_FIREBASE_UID>"
   }
   ```

---

## 6. Automated Testing

Run the complete test suite:
```powershell
pytest tests/ -v --tb=short
```
All unit and integration tests mock Firebase Admin SDK calls to ensure isolation and zero external dependency during test runs.

---

## 7. Frozen Protocol Specification

See [`docs/signaling_protocol.md`](../docs/signaling_protocol.md) for the complete frozen protocol specification, message envelopes, and WebRTC relay contracts.
