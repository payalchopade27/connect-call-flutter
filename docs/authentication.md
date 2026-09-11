# ConnectCall Authentication Architecture & WebSocket Auth Contract

This document specifies the authentication architecture and protocol contract for **ConnectCall**. It serves as the single source of truth for both the Flutter client and the FastAPI backend.

---

## 1. Architectural Principles

1. **Authentication Ownership**:
   - Authentication is performed directly by the Flutter client using **Firebase Authentication** (e.g., Phone, Email, Google, etc.).
   - The backend does **not** handle user registration, passwords, login endpoints, or user credential storage.

2. **Backend Token Verification**:
   - Upon successful sign-in on the client, Flutter retrieves a Firebase Authentication ID token via `user.getIdToken()`.
   - The backend verifies this token using the **Firebase Admin SDK** (`verify_id_token`).

3. **Canonical User Identity**:
   - The verified Firebase UID (`decoded_token["uid"]`) is the **sole canonical identity** (`userId`) recognized by the backend.
   - **Client-supplied `userId` values must never be trusted.** Identity is established strictly from the verified cryptographically-signed Firebase ID token.
   - For all future signaling messages, the sender identity is always derived from the authenticated connection's registered UID—never from a client-supplied payload field such as `fromUserId`.

4. **Transport Security & Token Placement**:
   - **The Firebase ID token must NOT be placed in the WebSocket URL query string** (e.g., `ws://host/ws/signaling?token=...` is strictly forbidden). Putting tokens in URLs exposes them in server access logs, browser history, proxy logs, and telemetry.
   - The token must be transmitted as the first message over the established WebSocket connection inside an encrypted payload (`wss://` in production, `ws://` in development).

5. **Credential Safety & Error Obfuscation**:
   - The Firebase Admin service-account private key (`serviceAccountKey.json` / `*credentials*.json`) is a sensitive secret. It is loaded strictly via the `FIREBASE_CREDENTIALS_PATH` environment variable and never committed to Git.
   - Internal Firebase exception details, service-account paths, and server stack traces are **never** returned to the client upon authentication failure. A generic, standardized error payload is always returned.

---

## 2. Frozen WebSocket Endpoint & Authentication Protocol

### Endpoint URLs
- **Development**: `ws://<backend-host>:8000/ws/signaling`
- **Production**: `wss://<backend-host>/ws/signaling`

### Authentication Sequence
Authentication occurs immediately as the first interaction upon opening the WebSocket.

```
Flutter Client                                              FastAPI Backend (/ws/signaling)
      │                                                                    │
      │ ── 1. Establish WebSocket Connection (No token in URL) ──────────▶ │
      │                                                                    │
      │ ◀── [Accept Connection] ───────────────────────────────────────────│
      │                                                                    │
      │ ── 2. Send Auth Message (Must arrive within 10 seconds) ─────────▶ │
      │       {"type": "auth", "token": "<Firebase ID Token>"}             │
      │                                                                    │
      │                                                                    │── Validate JSON structure & type == "auth"
      │                                                                    │── Extract token string
      │                                                                    │── verify_firebase_token(token)
      │                                                                    │── Extract decoded_token["uid"]
      │                                                                    │── Register in ConnectionManager
      │                                                                    │
      │ ◀── 3a. On Success: auth.success ──────────────────────────────────│
      │       {"type": "auth.success",                                     │
      │        "userId": "<verified Firebase UID>"}                        │
      │                                                                    │── Connection ready for signaling
      │                                                                    │
      │                         ── OR ──                                   │
      │                                                                    │
      │ ◀── 3b. On Failure / Malformed / Non-auth: auth.error ─────────────│
      │       {"type": "auth.error",                                       │
      │        "code": "AUTH_INVALID",                                     │
      │        "message": "Authentication failed"}                         │
      │                                                                    │── Close WebSocket (Code 1008)
      │                                                                    │
      │ ◀── 3c. On Timeout (> 10s without auth message): auth.error ───────│
      │       {"type": "auth.error",                                       │
      │        "code": "AUTH_TIMEOUT",                                     │
      │        "message": "Authentication timeout"}                        │
      │                                                                    │── Close WebSocket (Code 1008)
```

---

## 3. Detailed Handshake Specifications

### Step 1: Connection Establishment
- The client establishes a WebSocket connection to `/ws/signaling`.
- No query parameters or headers are required for authentication.

### Step 2: Initial Auth Message
Immediately after connection, the client must send:
```json
{
  "type": "auth",
  "token": "<Firebase ID token>"
}
```

#### Authentication Rules:
1. **10-Second Timeout**: If no valid authentication message is received within `10.0` seconds of connection, the backend replies with code `AUTH_TIMEOUT` and immediately closes the socket with WebSocket close code `1008 Policy Violation`.
2. **First Message Enforcement**: The very first message must have `"type": "auth"`. If the client sends any other message (e.g. `call.invite`) or malformed JSON before authenticating, the backend replies with `AUTH_INVALID` and immediately closes the connection.
3. **Missing / Empty Token**: If `"token"` is omitted, empty, or whitespace-only, the backend rejects the connection with `AUTH_INVALID`.

### Step 3a: Authentication Success Response
When token verification succeeds, the backend responds with:
```json
{
  "type": "auth.success",
  "userId": "<verified Firebase UID>"
}
```
At this point, the connection enters the authenticated state, is registered in `ConnectionManager`, and is eligible for 1-to-1 WebRTC call signaling.

### Step 3b: Authentication Failure Response
If token verification fails (invalid signature, expired token, revoked token, malformed JSON, non-auth initial message):
```json
{
  "type": "auth.error",
  "code": "AUTH_INVALID",
  "message": "Authentication failed"
}
```
The server then cleanly terminates the WebSocket connection with close code `1008`.

---

## 4. Flutter Integration Checklist

The Flutter client developer must follow these exact steps:

1. Sign in the user via Firebase Authentication (`FirebaseAuth.instance`).
2. Retrieve the current ID token:
   ```dart
   final idToken = await FirebaseAuth.instance.currentUser?.getIdToken();
   ```
3. Connect to the WebSocket signaling URL:
   ```dart
   final channel = WebSocketChannel.connect(Uri.parse('ws://<host>:8000/ws/signaling'));
   ```
4. Immediately transmit the authentication payload:
   ```dart
   channel.sink.add(jsonEncode({
     'type': 'auth',
     'token': idToken,
   }));
   ```
5. Await the response:
   - If response has `"type": "auth.success"`, the signaling connection is ready. Save the verified `userId`.
   - If response has `"type": "auth.error"`, handle the error, refresh the ID token via `getIdToken(true)`, and reconnect.
6. **Do NOT send any call signaling messages (e.g. `call.invite`) before `auth.success` is received.**
