# CallSessionManager Architecture & Lifecycle Specification

This document details the architectural responsibilities, data model, state lifecycle, and boundary contracts for the **CallSessionManager** (`app.calls`) in the ConnectCall backend.

---

## 1. Purpose of CallSessionManager

The `CallSessionManager` is an in-process, memory-based state engine designed exclusively for managing 1-to-1 audio and video call sessions.

### Core Separation of Concerns

The session manager is strictly decoupled from transport, authentication, and client frameworks:

```
┌────────────────────────────────────────────────────────┐
│               Authenticated WebSocket                  │
│       (Derives canonical Firebase UID from token)      │
└──────────────────────────┬─────────────────────────────┘
                           │ verified UID
                           ▼
┌────────────────────────────────────────────────────────┐
│                   CallSessionManager                   │
│      (Tracks call sessions, states, participants)       │
└──────────────────────────┬─────────────────────────────┘
                           │ target UID
                           ▼
┌────────────────────────────────────────────────────────┐
│                   ConnectionManager                    │
│           (Routes messages: UID → WebSocket)           │
└────────────────────────────────────────────────────────┘
```

The `CallSessionManager` does **NOT**:
- Hold or reference `WebSocket` objects.
- Inspect or verify Firebase ID tokens (relies on the pre-authenticated UID provided by the WebSocket router).
- Touch or parse WebRTC SDP offers/answers, ICE candidates, or media streams.
- Interfere with Firestore databases or push notification systems.
- Depend on external databases (Redis, PostgreSQL).

---

## 2. CallSession Model

The session model is implemented as a typed Pydantic model (`app.calls.models.CallSession`):

| Field | Type | Description | Constraints |
|---|---|---|---|
| `call_id` | `str` | Unique call identifier | Non-empty string, must be unique across all calls |
| `caller_id` | `str` | Verified Firebase UID of caller | Non-empty string, fixed at creation |
| `receiver_id` | `str` | Verified Firebase UID of receiver | Non-empty string, fixed at creation, $\neq$ `caller_id` |
| `call_type` | `CallType` (`"audio"` \| `"video"`) | Type of media call | Must be either `"audio"` or `"video"` |
| `state` | `CallState` (`"ringing"`, `"active"`, `"rejected"`, `"ended"`) | Current call lifecycle state | Initial state is always `"ringing"` |

---

## 3. Call Lifecycle & State Transitions

### State Diagram

```
         ringing
        /   │   \
       /    │    \
      /     │     \
accept     reject   end
    │       │       │
    ▼       ▼       ▼
 active  rejected  ended
    │
   end
    │
    ▼
  ended
```

### Transition Rules

| From State | To State | Trigger | Permitted? | Notes |
|---|---|---|---|---|
| `ringing` | `active` | Receiver accepts (`call.accept`) | **Yes** | Call becomes active |
| `ringing` | `rejected` | Receiver rejects (`call.reject`) | **Yes** | Terminal state; releases both participants |
| `ringing` | `ended` | Caller cancels before answer | **Yes** | Terminal state; releases both participants |
| `active` | `ended` | Either participant hangs up (`call.end`) | **Yes** | Terminal state; releases both participants |
| `active` | `rejected` | Invalid command | **No** | Raises `InvalidStateTransitionError` |
| `active` | `active` | Redundant accept | **No** | Raises `InvalidStateTransitionError` |
| `ended` | `*` | Any command | **No** | Terminal state; cannot be altered |
| `rejected` | `*` | Any command | **No** | Terminal state; cannot be altered |
| Any | Previous State | Backward transition | **No** | Reversals are strictly forbidden |

---

## 4. One-Active-Call-Per-User Policy

For the MVP, each user may participate in at most **ONE active or ringing call** at any time.

1. **Busy Definition**:
   - A user is marked as **busy** if they are registered as `caller_id` or `receiver_id` in any session with state `ringing` or `active`.
2. **Conflict Handling**:
   - If User A attempts to call User B while User A or User B is already in a `ringing` or `active` call, the manager rejects call creation immediately with `UserBusyError`.
3. **Release**:
   - When a call transitions to a terminal state (`rejected` or `ended`), or is removed via `remove_call()`, both `caller_id` and `receiver_id` are automatically released and eligible to start or join new calls.

---

## 5. Participant Ownership & Validation

1. **Immutable Participants**:
   - `caller_id` and `receiver_id` are defined at call creation and can never be modified.
2. **Participant Validation (`is_participant`)**:
   - Returns `True` only if the verified `user_id` matches `caller_id` or `receiver_id`.
3. **Other Participant Lookup (`get_other_participant`)**:
   - Given a participating `user_id`, returns the partner's UID.
   - If called with a third-party `user_id`, raises `UserNotParticipantError`.
   - Protects sessions from unauthorized access by third parties.

---

## 6. Concurrency Strategy

- FastAPI executes asynchronously on an `asyncio` event loop.
- Multiple WebSocket message handlers can invoke manager operations concurrently.
- Concurrency safety is achieved in-memory using an internal `asyncio.Lock()`:
  - Checking participant availability and creating calls occurs atomically.
  - State transitions and participant releases occur atomically.
- This prevents race conditions where two simultaneous incoming calls could place a single user in two active sessions.

---

## 7. Relationship with Other Subsystems

### With Firebase Authentication
The `CallSessionManager` does not verify Firebase tokens. The WebSocket layer verifies the token upon initial connection and passes the canonical UID (`decoded_token["uid"]`) into all session manager calls.

### With ConnectionManager
The `ConnectionManager` maps `Firebase UID → WebSocket`. The `CallSessionManager` maps `call_id → CallSession`. When a future signaling event occurs (e.g. `call.invite`), the signaling router will:
1. Verify sender identity from the WebSocket.
2. Validate and create session via `CallSessionManager`.
3. Locate recipient WebSocket via `ConnectionManager`.
4. Relay signaling message to recipient.
