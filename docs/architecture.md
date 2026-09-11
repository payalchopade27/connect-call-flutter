# ConnectCall Architecture Specification

This document details the system components, responsibilities, and connection routing model for the **ConnectCall** backend.

---

## 1. System Overview & Boundaries

ConnectCall is a 1-to-1 WebRTC audio/video calling system consisting of:
1. **Flutter Client**: Handles UI, Firebase Authentication login, and WebRTC media streams via `flutter_webrtc`.
2. **FastAPI Backend**: Acts strictly as a **signaling and control plane**.

> [!IMPORTANT]
> **FastAPI is NOT a media server.**
> Audio and video media flows directly peer-to-peer between the two Flutter clients using WebRTC.
> The backend never processes, decodes, relays, or records audio/video packets.

---

## 2. Component Responsibility Matrix

| Component | Responsibility | NOT Responsible For |
|---|---|---|
| **Firebase Auth** | User credential management, phone/email auth, token issuance | Signaling, call state |
| **Flutter Client** | User sign-in, WebRTC P2P media, UI/UX | Token verification, routing other users |
| **FastAPI Backend** | Token verification, connection tracking, WebRTC signaling relay, call lifecycle | Media handling, user registration, database persistence |
| **Signaling Router (`router.py`)** | WebSocket lifecycle, initial auth handshake, message loop | Media handling, long-term persistence |
| **ConnectionManager (`manager.py`)** | In-memory mapping: `Firebase UID → WebSocket` | Authentication, call logic, WebRTC negotiation |

---

## 3. WebSocket Routing & Handshake Layer

The signaling router (`app.signaling.router`) coordinates connection lifecycle and message dispatch:
- Exposes `websocket("/ws/signaling")`.
- Accepts connections and enforces a strict **10-second authentication timeout** using `asyncio.timeout()`.
- Validates the initial handshake: the first message must be an `auth` message containing a non-empty Firebase ID token.
- Verifies tokens through `app.auth.firebase_auth.verify_firebase_token()`.
- Obtains the canonical `userId` directly from the verified Firebase UID (`decoded_token["uid"]`).
- Registers active connections into `ConnectionManager`.
- Provides clean error masking: internal exceptions and stack traces are never exposed to clients.
- Post-authentication: maintains the persistent bidirectional WebSocket loop for incoming call signaling messages.
- On disconnect: cleans up connections safely in a `finally` block, passing the socket instance to preserve stale-connection protection.

---

## 4. WebSocket ConnectionManager Architecture

The `ConnectionManager` (`app.signaling.manager.ConnectionManager`) is an in-memory component residing entirely within the backend process.

### Core Purpose:
```
Authenticated Firebase UID  ──────▶  Active Signaling WebSocket
```

### What ConnectionManager Does:
- Registers active WebSocket connections keyed strictly by the verified Firebase UID (`decoded_token["uid"]`).
- Retrieves the active WebSocket for routing messages to a recipient user.
- Sends JSON-serialized signaling messages via `WebSocket.send_json()`.
- Automatically evicts dead or broken connections upon failed send attempts.
- Provides concurrency safety via `asyncio.Lock`.

### What ConnectionManager Does NOT Do:
- Does **NOT** authenticate users (handled by `app.auth.firebase_auth`).
- Does **NOT** create, manage, or validate call sessions.
- Does **NOT** negotiate or parse WebRTC SDP or ICE candidates.
- Does **NOT** persist call logs or user history.
- Does **NOT** handle or touch media packets.

---

## 5. Connection Policies

### Policy 1: One User → One Active Signaling Connection
For deterministic 1-to-1 call routing, a single authenticated Firebase UID corresponds to at most **one active signaling WebSocket connection**.
- When a user connects from a new tab, device, or network reconnection:
  - Any previously active WebSocket for that Firebase UID is cleanly closed with code `4000` (reason: `"Superseded by new connection"`).
  - The new WebSocket becomes the registered active connection.
- This prevents orphan connections, ambiguous routing, and split-brain states.

### Policy 2: Stale Disconnect Safety
In network reconnection scenarios, an older socket's disconnect event often fires *after* a newer socket has already connected.
- `disconnect(user_id, websocket)` requires the terminating socket instance.
- The manager only removes the user entry if the disconnecting socket instance matches the currently registered socket.
- If a newer socket has already replaced it, the stale disconnect is safely ignored.

---

## 6. Integration Contract with Flutter

The Flutter client developer interacts with clean, stable network protocols and does **not** need to understand internal Python classes or backend storage mechanisms:

1. **Canonical Identity**:
   `userId` is always the authenticated Firebase UID.
2. **WebSocket Authentication**:
   Authentication occurs as the first message over `/ws/signaling`, **never** in the URL query string:
   ```json
   {"type": "auth", "token": "<Firebase ID Token>"}
   ```
3. **Connection Readiness**:
   Only after receiving `{"type": "auth.success", "userId": "<UID>"}` is the client permitted to exchange call signaling messages.
