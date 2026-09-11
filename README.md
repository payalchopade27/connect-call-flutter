# ConnectCall

ConnectCall is a 1-to-1 audio and video calling application built with Flutter, Firebase Authentication, WebRTC, and a FastAPI signaling backend.

## Repository Structure

```text
connectcall/
├── app/                         # Flutter client application
│   ├── lib/
│   ├── android/
│   ├── ios/
│   └── ...
│
├── backend/                     # FastAPI signaling backend
│   ├── app/
│   │   ├── auth/                # Firebase authentication
│   │   ├── calls/               # Call session management
│   │   ├── signaling/           # WebSocket signaling
│   │   └── core/                # Configuration
│   ├── tests/                   # Backend unit/integration tests
│   ├── requirements.txt
│   ├── .env.example
│   └── README.md
│
└── docs/
    ├── architecture.md
    ├── authentication.md
    ├── call_sessions.md
    └── signaling_protocol.md