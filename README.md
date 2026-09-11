# Connect Call

> **Flutter Development Intern Assignment** — Build a Functional Calling App in Flutter

Connect Call is a real-time, 1-on-1 audio and video calling mobile application built with Flutter, Google WebRTC, Firebase, and a dedicated FastAPI WebSocket signaling service.

---

## 1. Project Name
**Connect Call** (`connect_call`)

---

## 2. Project Overview
Connect Call provides seamless, low-latency audio and video communications between authenticated users. The mobile client integrates Firebase for user authentication and directory management, an external high-performance FastAPI WebSocket signaling server for session negotiation, and WebRTC for peer-to-peer media streaming.

---

## 3. Features
- **Authentication**: Email & password signup, login, and signout backed by Firebase Authentication.
- **User Discovery & Contacts**: Live list of registered contacts queried from Cloud Firestore with search capabilities.
- **Identity Routing by Firebase UID**: All calls are routed strictly via verified Firebase UIDs (`toUserId` / `fromUserId`), never by arbitrary names, emails, or phone numbers.
- **WebSocket Signaling**: Persistent, authenticated WebSocket connection to the authoritative backend with handshake timeouts and strict token verification.
- **Audio Calling**: High-definition peer-to-peer audio calls with local microphone acquisition, SDP offer/answer negotiation, and ICE candidate exchange.
- **Video Calling**: Dual-feed video calling featuring full-screen remote video rendering and a picture-in-picture local preview.
- **Hardware & Media Controls**:
  - Microphone mute / unmute
  - Video camera mute / unmute
  - Front / rear camera switching
  - Loudspeaker / earpiece audio routing
  - Hang up / call termination
- **Incoming Call Presentation**: Full-screen incoming call UI with distinct audio/video indicators, caller identity, and Accept / Decline actions.
- **Call History**: Persistent call logging stored in Firestore (`users/{uid}/calls`) with in-memory caching, timestamp grouping (*Today*, *Yesterday*), call duration, and state badges.
- **Robust Error Handling**: Auto-rejection with `busy` state when in an active call, 30-second ringing timeout for unanswered calls, network disconnect recovery, and safe fallback if offline.

---

## 4. Technology Stack
- **Framework**: Flutter (Dart 3.8+ / SDK ^3.13.2)
- **Design System**: Material 3 (Custom curated Dark Theme)
- **State Management**: Flutter Riverpod (`StateNotifierProvider`, `StreamProvider`, `Provider`)
- **Backend & Auth**:
  - Firebase Authentication (`firebase_auth: ^5.1.0`)
  - Cloud Firestore (`cloud_firestore: ^5.0.1`)
  - Firebase Core (`firebase_core: ^3.1.0`)
- **Real-Time Communications**:
  - WebRTC (`flutter_webrtc: ^0.12.4`)
  - WebSockets (`web_socket_channel: ^3.0.1`)
- **Device Utilities**:
  - Permissions (`permission_handler: ^11.3.1`)
  - Identifiers (`uuid: ^4.4.0`)
  - Date & Formatting (`intl: ^0.19.0`)

---

## 5. Architecture
The project adheres to a clean, decoupled layer architecture:

```
┌─────────────────────────────────────────────────────────────┐
│                    Presentation Layer (UI)                  │
│       Screens (Splash, Auth, Home, Contacts, History, Call) │
│       Widgets (UserTile, CallControls, VideoViews)          │
└──────────────────────────────┬──────────────────────────────┘
                               │ watches / triggers
┌──────────────────────────────▼──────────────────────────────┐
│                    State Management Layer                   │
│      Riverpod Notifiers & Providers (CallNotifier, etc.)    │
└──────────────────────────────┬──────────────────────────────┘
                               │ orchestrates
┌──────────────────────────────▼──────────────────────────────┐
│                        Services Layer                       │
│    AuthService  │  UserService  │  CallHistoryService       │
│    SignalingService (WebSocket)  │  WebRTCService (Media)   │
└──────────────────────────────┬──────────────────────────────┘
                               │ talks to
┌──────────────────────────────▼──────────────────────────────┐
│                 External Infrastructure                     │
│    Firebase Auth  │  Cloud Firestore  │  FastAPI Signaling  │
└─────────────────────────────────────────────────────────────┘
```

---

## 6. Firebase Setup
- **Project ID**: `connectcall-c60b0` (Project name: `connectcall`)
- **Android App Application ID**: `com.example.connect_call`
- **Config file**: Placed at `android/app/google-services.json`
- **Database**: Default Google Cloud Firestore instance.
- **Android Gradle**:
  - Root `android/settings.gradle.kts` applies `id("com.google.gms.google-services") version "4.4.2" apply false`.
  - App `android/app/build.gradle.kts` applies `id("com.google.gms.google-services")`.

---

## 7. Authentication
1. Users register with **Display Name**, **Email**, and **Password**.
2. Upon registration or login, Firebase Auth returns a verified `User` object.
3. The user's UID (`FirebaseAuth.instance.currentUser?.uid`) serves as the unique identifier across all services.
4. An ID token is retrieved via `user.getIdToken()`.
5. **Security**: The Firebase ID token is strictly kept in memory and is **NEVER** logged to console or persisted to disk.

---

## 8. Firestore Data Model
- **Users Collection (`users/{uid}`)**:
  ```json
  {
    "uid": "<FIREBASE_UID>",
    "name": "Alex Rivers",
    "email": "alex@connectcall.com",
    "phone": "+1234567890",
    "bio": "Available for calls",
    "isOnline": true,
    "lastSeen": "TIMESTAMP",
    "createdAt": "TIMESTAMP"
  }
  ```
- **User Calls Subcollection (`users/{uid}/calls/{callId}`)**:
  ```json
  {
    "callId": "<UUID>",
    "callerId": "<SENDER_UID>",
    "receiverId": "<RECEIVER_UID>",
    "callerName": "Alex Rivers",
    "receiverName": "Sam Intern",
    "callType": "audio" | "video",
    "state": "ended" | "missed" | "rejected" | "busy" | "failed",
    "direction": "incoming" | "outgoing",
    "startedAt": "2026-09-11T12:00:00.000Z",
    "endedAt": "2026-09-11T12:04:05.000Z",
    "duration": 245,
    "endReason": "userEnded"
  }
  ```

---

## 9. WebSocket Signaling & Authoritative Contract
- **Deployed Endpoint**: `wss://connect-call-flutter.onrender.com/ws/signaling`
- **Handshake Flow**:
  1. Open WebSocket connection.
  2. Send `auth` message as the **FIRST** frame:
     ```json
     { "type": "auth", "token": "<FIREBASE_ID_TOKEN>" }
     ```
  3. Backend verifies the token with Firebase Admin SDK.
  4. Backend responds with `auth.success`:
     ```json
     { "type": "auth.success", "userId": "<VERIFIED_FIREBASE_UID>" }
     ```
  5. The Flutter client guards all call traffic — no call or signaling messages can be sent prior to receiving `auth.success`.
- **Envelope Rules**:
  - The client **NEVER** sends `callerId` or `fromUserId` in outgoing envelopes; the backend automatically stamps the sender identity from the authenticated connection.
  - Outgoing message schema:
    ```json
    {
      "type": "<MESSAGE_TYPE>",
      "callId": "<UUID>",
      "toUserId": "<TARGET_FIREBASE_UID>",
      "payload": {}
    }
    ```

---

## 10. WebRTC Audio & Video
- **STUN Configuration**: Centralized STUN servers configured via Google STUN endpoints (`stun:stun.l.google.com:19302`, `stun:stun1.l.google.com:19302`).
- **Audio Profile**: 1-channel audio constraint; local track toggle for hardware microphone mute; speaker routing via `Helper.setSpeakerphoneOn`.
- **Video Profile**: 720p 1280x720 ideal constraints, front-facing camera default, hardware camera track toggling for video mute, and camera switching via `Helper.switchCamera`.
- **Renderers**: `RTCVideoRenderer` instances for local preview and remote feed with automatic initialization and resource disposal.

---

## 11. Permissions
Permissions are dynamically managed via `permission_handler`:
- **Audio calls**: Requests `Permission.microphone`.
- **Video calls**: Requests both `Permission.microphone` and `Permission.camera`.
- **Graceful Rejection**: If permissions are denied or permanently denied, a clean error banner is presented rather than looping requests or crashing.

---

## 12. Call States
Supported lifecycle states:
`idle` ➔ `calling` / `ringing` ➔ `connecting` ➔ `connected` ➔ `ended` / `rejected` / `missed` / `busy` / `failed` / `disconnected`

---

## 13. End-to-End Call Flow
```
User A (Caller)                       Backend                        User B (Callee)
      │                                  │                                  │
      ├─── WebSocket Connect ───────────►│                                  │
      ├─── {type: "auth", token: ...} ──►│                                  │
      │◄── {type: "auth.success"} ───────┤                                  │
      │                                  │◄─── WebSocket Connect ───────────┤
      │                                  │◄─── {type: "auth", token: ...} ──┤
      │                                  ├──── {type: "auth.success"} ─────►│
      │                                  │                                  │
      ├─── call.invite ─────────────────►│──── call.invite ────────────────►│
      │    (callId, toUserId, payload)   │    (fromUserId stamped)          │ (Rings)
      │                                  │                                  │
      │                                  │◄─── call.accept ─────────────────┤
      │◄── call.accept ──────────────────┤                                  │
      │                                  │                                  │
      ├─── webrtc.offer ────────────────►│──── webrtc.offer ───────────────►│
      │                                  │◄─── webrtc.answer ───────────────┤
      │◄── webrtc.answer ────────────────┤                                  │
      │                                  │                                  │
      ├─── webrtc.ice ──────────────────►│──── webrtc.ice ─────────────────►│
      │◄── webrtc.ice ───────────────────│◄─── webrtc.ice ──────────────────┤
      │                                  │                                  │
      │◄══════════════════ WebRTC P2P Direct Media Stream ═════════════════►│
      │                                (Connected)                          │
      │                                  │                                  │
      ├─── call.end ────────────────────►│──── call.end ───────────────────►│
      │ (Hardware cleaned up)            │                     (Hardware cleaned up)
```

---

## 14. How to Run
### Prerequisites
- Flutter SDK 3.13.2+ installed and configured on PATH
- Android SDK / Android Studio configured with API level 34+
- Physical Android device or emulator with Google Play Services

### Steps
1. Navigate to the project root:
   ```bash
   cd c:\Users\Payal\StudioProjects\connect_call\connect_call
   ```
2. Install dependencies:
   ```bash
   flutter pub get
   ```
3. Run on connected device:
   ```bash
   flutter run
   ```

---

## 15. How to Build Release APK
Run the release build command from the project root:
```bash
flutter build apk --release
```
The resulting release binary will be generated at:
```
build/app/outputs/flutter-apk/app-release.apk
```

---

## 16. Backend Signaling Endpoint
```
wss://connect-call-flutter.onrender.com/ws/signaling
```

---

## 17. Testing
The project includes automated unit, state machine, contract, and widget tests.

### Running Automated Tests
```bash
flutter test
```
All 43 unit and integration tests pass:
- `test/call_state_test.dart`: Call state machine transitions, controls (mute, speaker, video mute, camera switch), peer identification, and history logging.
- `test/signaling_service_test.dart`: WebSocket connection, authentication first-message contract, auth timeout, inbound/outbound envelope validation, offer/answer/ICE exchange, error routing, and peer disconnection.
- `test/widget_test.dart`: Splash screen rendering and smoke test.

### Analyzer Check
```bash
flutter analyze
```
Outputs 0 errors, 0 warnings, 0 lints.

---

## 18. Known Limitations
1. **P2P NAT Traversal**: In restrictive symmetric NAT or carrier-grade cellular environments, direct WebRTC connections may require a TURN relay server (RFC 5766). The app is pre-configured with Google STUN servers for standard networks, with pluggable TURN config in `AppConstants.iceServers`.
2. **Background Push Notifications**: When the application is completely terminated, incoming calls currently rely on an active WebSocket connection. Production deployment requires Firebase Cloud Messaging (FCM) high-priority data messages with CallKit / ConnectionService integration for background wakeups.
3. **Physical Media Verification**: Automated tests thoroughly verify the state machine, mock WebRTC lifecycle, and signaling envelopes. Verification of physical camera sensors and microphone hardware audio requires real physical mobile devices.

---

## 19. AI-Assisted Development Disclosure
This project was developed with the assistance of AI coding tools (Google Antigravity / Gemini) for code drafting, refactoring, architectural review, and test coverage generation. All generated code was reviewed, validated, and verified for compliance with the project specifications and backend contract.
