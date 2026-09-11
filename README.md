# ConnectCall

ConnectCall is a 1-to-1 WebRTC audio and video calling platform.

## Repository Overview

```
connectcall/
├── backend/                  # FastAPI WebRTC signaling backend
│   ├── app/                  # Application code (auth, calls, signaling)
│   ├── tests/                # Automated pytest suite (unit & integration)
│   ├── requirements.txt      # Python dependencies
│   ├── .env.example          # Environment variable template
│   └── README.md             # Backend setup & deployment guide
└── docs/                     # Architecture & Protocol Specifications
    ├── architecture.md       # High-level system architecture
    ├── authentication.md     # Firebase token verification & auth lifecycle
    ├── call_sessions.md      # CallSessionManager state machine specification
    └── signaling_protocol.md # Frozen WebSocket signaling protocol specification
```

## Quick Start (Backend)

```bash
cd backend
python -m venv .venv

# On Windows:
.\.venv\Scripts\Activate.ps1
# On Linux/macOS:
source .venv/bin/activate

pip install -r requirements.txt
cp .env.example .env

# Run locally:
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

## WebSocket Signaling Endpoints
- **Local**: `ws://<BACKEND_HOST>:8000/ws/signaling`
- **Production**: `wss://<BACKEND_HOST>/ws/signaling`

## Health Check
- `GET /health` -> `{"status": "ok"}` (HTTP 200)

## Documentation Reference
- [Architecture Documentation](docs/architecture.md)
- [Authentication Specification](docs/authentication.md)
- [Call Session State Machine](docs/call_sessions.md)
- [Signaling Protocol Specification](docs/signaling_protocol.md)
