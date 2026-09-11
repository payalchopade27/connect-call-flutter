# ConnectCall Signaling Protocol Specification

This document details the WebSocket signaling protocol implemented on the ConnectCall backend (`/ws/signaling`), covering authentication, call lifecycle management, WebRTC relay, error handling, and security guarantees.

---

## 1. Overview & Connection Lifecycle

The ConnectCall backend acts purely as a **signaling server**. Media traffic (audio/video) travels peer-to-peer directly between Flutter clients using WebRTC.

```
Flutter Client A                   FastAPI Backend                   Flutter Client B
      │                                   │                                   │
      ├────── WebSocket Connect ─────────►│                                   │
      ├────── auth: {token} ─────────────►│                                   │
      │◄───── auth.success ───────────────┤                                   │
      │                                   │◄────── WebSocket Connect ─────────┤
      │                                   │◄────── auth: {token} ─────────────┤
      │                                   ├─────── auth.success ─────────────►│
      │                                   │                                   │
      │── call.invite ───────────────────►│── call.invite ───────────────────►│
      │                                   │◄─ call.accept ────────────────────┤
      │◄─ call.accept ────────────────────┤                                   │
      │── webrtc.offer ──────────────────►│── webrtc.offer ──────────────────►│
      │                                   │◄─ webrtc.answer ──────────────────┤
      │◄─ webrtc.answer ──────────────────┤                                   │
      │◄══════════════ WebRTC P2P Media / Audio / Video ═════════════════════►│
      │                                   │                                   │
      │── call.end ──────────────────────►│── call.end ──────────────────────►│
```

### Connection Endpoint
- **URL**: `/ws/signaling`
- **Protocol**: JSON over WebSocket
- **Auth Timeout**: 10 seconds. The client MUST authenticate within 10 seconds of opening the socket, or the server closes the connection with code `1008` (Policy Violation).

---

## 2. Authentication Phase

The first message sent by any client immediately upon connecting MUST be an authentication message containing a valid Firebase ID token.

### Client Request: `auth`
```json
{
  "type": "auth",
  "token": "<FIREBASE_ID_TOKEN>"
}
```

### Server Response: `auth.success`
```json
{
  "type": "auth.success",
  "userId": "<CANONICAL_FIREBASE_UID>"
}
```

### Server Response: `auth.error` (Failure)
If authentication fails (missing token, malformed JSON, invalid/expired/revoked token, or timeout):
```json
{
  "type": "auth.error",
  "code": "AUTH_INVALID",
  "message": "Authentication failed"
}
```
*Note: The server immediately closes the connection with code `1008` after sending `auth.error`. Internal Firebase error details and stack traces are never exposed.*

---

## 3. Call Signaling Lifecycle

All post-authentication signaling messages follow the standard envelope format:
```json
{
  "type": "<MESSAGE_TYPE>",
  "callId": "<UNIQUE_CALL_ID>",
  "toUserId": "<TARGET_FIREBASE_UID>",
  "payload": {}
}
```

When routed by the server, the message delivered to the destination user includes `fromUserId`, which is derived **exclusively** from the authenticated connection:
```json
{
  "type": "<MESSAGE_TYPE>",
  "callId": "<UNIQUE_CALL_ID>",
  "fromUserId": "<SENDER_FIREBASE_UID>",
  "toUserId": "<RECEIVER_FIREBASE_UID>",
  "payload": {}
}
```

### 3.1 `call.invite`

Initiates a 1-to-1 call session in `ringing` state.

- **Sender**: Caller
- **Payload**:
  ```json
  {
    "type": "call.invite",
    "callId": "call_12345",
    "toUserId": "receiver_uid",
    "payload": {
      "callType": "audio" // or "video"
    }
  }
  ```
- **Delivered to Receiver**:
  ```json
  {
    "type": "call.invite",
    "callId": "call_12345",
    "fromUserId": "caller_uid",
    "toUserId": "receiver_uid",
    "payload": {
      "callType": "audio"
    }
  }
  ```
- **Validation**:
  - `toUserId` cannot equal `fromUserId` (self-call rejected with `CANNOT_CALL_SELF`).
  - `callType` must be `"audio"` or `"video"` (`INVALID_CALL_TYPE`).
  - `callId` must not already exist (`DUPLICATE_CALL_ID`).
  - `toUserId` must be connected/online (`USER_OFFLINE`).
  - Neither caller nor receiver can already be in a ringing or active call (`USER_BUSY`).

### 3.2 `call.accept`

Transitions a call from `ringing` $\rightarrow$ `active`.

- **Sender**: Receiver only
- **Target**: Caller only
- **Message**:
  ```json
  {
    "type": "call.accept",
    "callId": "call_12345",
    "toUserId": "caller_uid",
    "payload": {}
  }
  ```
- **Delivered to Caller**:
  ```json
  {
    "type": "call.accept",
    "callId": "call_12345",
    "fromUserId": "receiver_uid",
    "toUserId": "caller_uid",
    "payload": {}
  }
  ```
- **Validation**:
  - Only the designated receiver can accept (`NOT_PARTICIPANT`).
  - Target must be the caller (`INVALID_TARGET`).
  - Call must currently be in `ringing` state (`INVALID_STATE`).

### 3.3 `call.reject`

Transitions a call from `ringing` $\rightarrow$ `rejected` and releases both users' busy state.

- **Sender**: Receiver only
- **Target**: Caller only
- **Message**:
  ```json
  {
    "type": "call.reject",
    "callId": "call_12345",
    "toUserId": "caller_uid",
    "payload": {
      "reason": "busy" // optional
    }
  }
  ```
- **Delivered to Caller**:
  ```json
  {
    "type": "call.reject",
    "callId": "call_12345",
    "fromUserId": "receiver_uid",
    "toUserId": "caller_uid",
    "payload": {
      "reason": "busy"
    }
  }
  ```
- **Validation**:
  - Only the receiver can reject (`NOT_PARTICIPANT`).
  - Call must be in `ringing` state (`INVALID_STATE`).

### 3.4 `call.end`

Terminates a call from either `ringing` or `active` $\rightarrow$ `ended`, releasing user busy states.

- **Sender**: Either caller or receiver
- **Target**: The other participant
- **Message**:
  ```json
  {
    "type": "call.end",
    "callId": "call_12345",
    "toUserId": "other_participant_uid",
    "payload": {
      "reason": "hangup" // optional
    }
  }
  ```
- **Delivered to Peer**:
  ```json
  {
    "type": "call.end",
    "callId": "call_12345",
    "fromUserId": "terminating_uid",
    "toUserId": "other_participant_uid",
    "payload": {
      "reason": "hangup"
    }
  }
  ```
- **Validation**:
  - Sender must be an active participant (`NOT_PARTICIPANT`).
  - Target must be the other participant (`INVALID_TARGET`).
  - Call must be in `ringing` or `active` state (`INVALID_STATE`).

---

## 4. WebRTC Signaling Relay

WebRTC signaling messages are relayed unchanged between participants once the call is in the `active` state.

### 4.1 `webrtc.offer`
- **Sender**: Caller (typically) or either participant during renegotiation
- **Message**:
  ```json
  {
    "type": "webrtc.offer",
    "callId": "call_12345",
    "toUserId": "peer_uid",
    "payload": {
      "sdp": "v=0\r\no=- ..."
    }
  }
  ```

### 4.2 `webrtc.answer`
- **Sender**: Receiver (or peer responding to renegotiation)
- **Message**:
  ```json
  {
    "type": "webrtc.answer",
    "callId": "call_12345",
    "toUserId": "peer_uid",
    "payload": {
      "sdp": "v=0\r\no=- ..."
    }
  }
  ```

### 4.3 `webrtc.ice`
- **Sender**: Either participant
- **Message**:
  ```json
  {
    "type": "webrtc.ice",
    "callId": "call_12345",
    "toUserId": "peer_uid",
    "payload": {
      "candidate": {
        "candidate": "candidate:1 1 UDP ...",
        "sdpMid": "0",
        "sdpMLineIndex": 0
      },
      "sdpMid": "0",
      "sdpMLineIndex": 0
    }
  }
  ```

### WebRTC Relay Rules:
- Call MUST be in `active` state (sending WebRTC messages while `ringing` returns `INVALID_STATE`).
- Sender MUST be a verified participant (`NOT_PARTICIPANT`).
- `toUserId` MUST match the other participant (`INVALID_TARGET`).
- Payload MUST match SDP (`{"sdp": str}`) or ICE structure (`INVALID_MESSAGE`).
- The server DOES NOT modify the payload in any way.

---

## 5. Disconnect Cleanup & Peer Notification

When a participant disconnects unexpectedly (e.g. app closed, network drop):
1. The server detects the disconnect.
2. The server verifies this socket is the active registered socket for the user (stale replacement connections do not trigger cleanup of newer calls).
3. Any `ringing` or `active` call associated with that user is transitioned to `ended`.
4. The remaining peer receives a `peer.disconnected` notification:
   ```json
   {
     "type": "peer.disconnected",
     "callId": "call_12345",
     "fromUserId": "disconnected_uid",
     "toUserId": "remaining_peer_uid",
     "payload": {
       "userId": "disconnected_uid"
     }
   }
   ```
5. Both users' busy state is cleared, allowing them to participate in new calls immediately.

---

## 6. Error Handling

When a signaling error occurs, the server returns a `call.error` response to the sender without terminating the WebSocket connection:

```json
{
  "type": "call.error",
  "callId": "call_12345",
  "payload": {
    "code": "<ERROR_CODE>",
    "message": "<HUMAN_READABLE_DESCRIPTION>"
  }
}
```

### Protocol Error Codes

| Error Code | Description |
|---|---|
| `CALL_NOT_FOUND` | Specified `callId` does not exist |
| `DUPLICATE_CALL_ID` | Specified `callId` already exists |
| `CANNOT_CALL_SELF` | Caller attempted to call themselves (`caller == receiver`) |
| `USER_OFFLINE` | Target user is not connected to the signaling server |
| `USER_BUSY` | Either caller or receiver is currently in a ringing or active call |
| `NOT_PARTICIPANT` | Sender is not an authorized participant in the call |
| `INVALID_TARGET` | `toUserId` does not match the other participant in the call |
| `INVALID_STATE` | Operation not permitted in the current call state |
| `INVALID_CALL_TYPE` | Call type must be `"audio"` or `"video"` |
| `INVALID_MESSAGE` | Malformed JSON, missing required envelope fields, or invalid payload structure |
| `UNKNOWN_TYPE` | Unrecognized message type |

---

## 7. Security Guarantees

1. **Authenticated Identity Binding**:
   - The user identity (`userId`) is extracted exclusively from the validated Firebase ID token during the auth handshake.
   - The client cannot supply, alter, or spoof `fromUserId` or `callerId` in any post-auth message. The server always sets `fromUserId = authenticated_uid`.
2. **Third-Party Eavesdropping / Injection Protection**:
   - Users cannot send messages to arbitrary `toUserId` values unless an active or ringing call exists between those two specific users.
   - WebRTC SDP and ICE messages cannot be injected by third parties (`NOT_PARTICIPANT`).
3. **No Credential / Internal Leakage**:
   - Firebase Admin exceptions and internal errors never reach clients in responses.
   - Failures return standardized, generic error payloads (`AUTH_INVALID`).
4. **Server Resilience & DoS Protection**:
   - The server handles malformed JSON, unknown types, and invalid payloads gracefully without dropping the WebSocket connection or crashing.
   - Enforces a 64 KB (`MAX_MESSAGE_SIZE_BYTES = 65536`) ceiling on both authentication and signaling messages, protecting the server against memory exhaustion attacks.

---

## 8. Frozen Contract Status

The ConnectCall backend signaling protocol is **frozen**.
- **Endpoint**: `/ws/signaling`
- **Call Message Types**: `call.invite`, `call.accept`, `call.reject`, `call.end`
- **WebRTC Message Types**: `webrtc.offer`, `webrtc.answer`, `webrtc.ice`
- **System Message Types**: `call.error`, `peer.disconnected`, `auth`, `auth.success`, `auth.error`
- **Envelope Fields**: `type`, `token`, `userId`, `callId`, `fromUserId`, `toUserId`, `payload`, `code`, `message`

