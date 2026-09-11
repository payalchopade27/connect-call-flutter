import 'dart:convert';
import '../core/constants/app_constants.dart';

/// Standard message types agreed upon in the frozen backend signaling contract.
class SignalingMessageType {
  // Authentication
  static const String auth = 'auth';
  static const String authSuccess = 'auth.success';
  static const String authError = 'auth.error';

  // Call signaling
  static const String callInvite = 'call.invite';
  static const String callAccept = 'call.accept';
  static const String callReject = 'call.reject';
  static const String callEnd = 'call.end';
  static const String callError = 'call.error';
  static const String peerDisconnected = 'peer.disconnected';

  // WebRTC signaling
  static const String webrtcOffer = 'webrtc.offer';
  static const String webrtcAnswer = 'webrtc.answer';
  static const String webrtcIce = 'webrtc.ice';
}

/// Centralized signaling message envelope for WebSocket communication.
///
/// Auth message format:
/// ```json
/// {"type": "auth", "token": "<FIREBASE_ID_TOKEN>"}
/// ```
///
/// Auth success format:
/// ```json
/// {"type": "auth.success", "userId": "<VERIFIED_FIREBASE_UID>"}
/// ```
///
/// Auth error format:
/// ```json
/// {"type": "auth.error", "code": "AUTH_INVALID", "message": "Authentication failed"}
/// ```
///
/// Outgoing call format (Flutter → Backend):
/// ```json
/// {"type": "...", "callId": "...", "toUserId": "...", "payload": {...}}
/// ```
///
/// Incoming call format (Backend → Flutter):
/// ```json
/// {"type": "...", "callId": "...", "fromUserId": "...", "toUserId": "...", "payload": {...}}
/// ```
///
/// IMPORTANT: Outgoing messages must NOT include fromUserId or callerId.
/// The backend derives the sender from the authenticated WebSocket connection.
class SignalingMessage {
  final String type;
  final String? callId;

  /// The target user's Firebase UID (used in outgoing messages).
  final String? toUserId;

  /// The sender's Firebase UID (present only in incoming messages from backend).
  final String? fromUserId;

  /// The verified user ID (returned in auth.success).
  final String? userId;

  /// The Firebase ID token (sent in auth message). NEVER logged.
  final String? token;

  /// Error code (in auth.error / call.error).
  final String? code;

  /// Error message (in auth.error / call.error).
  final String? message;

  /// Payload containing type-specific data (callType, reason, sdp, candidate, etc.)
  final Map<String, dynamic> payload;

  SignalingMessage({
    required this.type,
    this.callId,
    this.toUserId,
    this.fromUserId,
    this.userId,
    this.token,
    this.code,
    this.message,
    this.payload = const {},
  });

  /// Serialize for sending to backend.
  /// NEVER includes fromUserId or callerId — backend derives sender identity.
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'type': type,
    };

    if (type == SignalingMessageType.auth) {
      if (token != null) map['token'] = token;
      return map;
    }

    if (callId != null) map['callId'] = callId;
    if (toUserId != null) map['toUserId'] = toUserId;
    if (userId != null) map['userId'] = userId;

    // Call and WebRTC messages always include the payload object (even if empty) per contract
    map['payload'] = payload;

    return map;
  }

  String toJson() => jsonEncode(toMap());

  /// Parse an incoming message from the backend.
  factory SignalingMessage.fromMap(Map<String, dynamic> map) {
    Map<String, dynamic> parsedPayload = {};
    if (map['payload'] is Map<String, dynamic>) {
      parsedPayload = map['payload'] as Map<String, dynamic>;
    } else if (map['payload'] is Map) {
      parsedPayload = Map<String, dynamic>.from(map['payload'] as Map);
    }

    return SignalingMessage(
      type: map['type']?.toString() ?? '',
      callId: map['callId']?.toString(),
      toUserId: map['toUserId']?.toString(),
      fromUserId: map['fromUserId']?.toString(),
      userId: map['userId']?.toString(),
      token: map['token']?.toString(),
      code: map['code']?.toString(),
      message: map['message']?.toString(),
      payload: parsedPayload,
    );
  }

  factory SignalingMessage.fromJson(String jsonStr) {
    final Map<String, dynamic> map = jsonDecode(jsonStr) as Map<String, dynamic>;
    return SignalingMessage.fromMap(map);
  }

  // ==========================================
  // Convenience factories
  // ==========================================

  /// Create auth message (first message after WebSocket connect).
  /// Format: `{"type": "auth", "token": "<FIREBASE_ID_TOKEN>"}`
  /// Token must NEVER be logged.
  factory SignalingMessage.auth(String token) {
    return SignalingMessage(
      type: SignalingMessageType.auth,
      token: token,
    );
  }

  /// Create call.invite message.
  factory SignalingMessage.invite({
    required String callId,
    required String toUserId,
    required CallType callType,
  }) {
    return SignalingMessage(
      type: SignalingMessageType.callInvite,
      callId: callId,
      toUserId: toUserId,
      payload: {'callType': callType.toJson()},
    );
  }

  /// Create call.accept message.
  factory SignalingMessage.accept({
    required String callId,
    required String toUserId,
  }) {
    return SignalingMessage(
      type: SignalingMessageType.callAccept,
      callId: callId,
      toUserId: toUserId,
      payload: const {},
    );
  }

  /// Create call.reject message.
  factory SignalingMessage.reject({
    required String callId,
    required String toUserId,
    String reason = 'rejected',
  }) {
    return SignalingMessage(
      type: SignalingMessageType.callReject,
      callId: callId,
      toUserId: toUserId,
      payload: {'reason': reason},
    );
  }

  /// Create call.end message.
  factory SignalingMessage.end({
    required String callId,
    required String toUserId,
  }) {
    return SignalingMessage(
      type: SignalingMessageType.callEnd,
      callId: callId,
      toUserId: toUserId,
      payload: const {},
    );
  }

  /// Create webrtc.offer message per contract envelope.
  factory SignalingMessage.offer({
    required String callId,
    required String toUserId,
    required String sdp,
  }) {
    return SignalingMessage(
      type: SignalingMessageType.webrtcOffer,
      callId: callId,
      toUserId: toUserId,
      payload: {'sdp': sdp},
    );
  }

  /// Create webrtc.answer message per contract envelope.
  factory SignalingMessage.answer({
    required String callId,
    required String toUserId,
    required String sdp,
  }) {
    return SignalingMessage(
      type: SignalingMessageType.webrtcAnswer,
      callId: callId,
      toUserId: toUserId,
      payload: {'sdp': sdp},
    );
  }

  /// Create webrtc.ice message per contract envelope.
  factory SignalingMessage.ice({
    required String callId,
    required String toUserId,
    required dynamic candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) {
    return SignalingMessage(
      type: SignalingMessageType.webrtcIce,
      callId: callId,
      toUserId: toUserId,
      payload: {
        'candidate': candidate,
        'sdpMid': ?sdpMid,
        'sdpMLineIndex': ?sdpMLineIndex,
      },
    );
  }

  // ==========================================
  // Payload & Field helpers for incoming messages
  // ==========================================

  /// Extract callType from payload (incoming call.invite).
  CallType? get callType {
    final ct = payload['callType']?.toString().toLowerCase();
    if (ct == null) return null;
    return ct == 'video' ? CallType.video : CallType.audio;
  }

  /// Extract reason from payload (incoming call.reject).
  String? get reason => payload['reason']?.toString();

  /// Extract verified userId (from auth.success top-level or payload).
  String? get verifiedUserId => userId ?? payload['userId']?.toString();

  /// Extract error code from auth.error / call.error (top-level or payload).
  String? get errorCode => code ?? payload['code']?.toString();

  /// Extract error message from auth.error / call.error (top-level or payload).
  String? get errorMessage => message ?? payload['message']?.toString();

  /// Extract SDP from payload (incoming webrtc.offer / webrtc.answer).
  String? get sdp => payload['sdp']?.toString();

  /// Extract ICE candidate from payload (incoming webrtc.ice).
  dynamic get candidate => payload['candidate'];

  /// Extract sdpMid from payload (incoming webrtc.ice).
  String? get sdpMid => payload['sdpMid']?.toString();

  /// Extract sdpMLineIndex from payload (incoming webrtc.ice).
  int? get sdpMLineIndex {
    final idx = payload['sdpMLineIndex'];
    if (idx is int) return idx;
    if (idx is String) return int.tryParse(idx);
    return null;
  }

  @override
  String toString() {
    return 'SignalingMessage(type: $type, callId: $callId, toUserId: $toUserId, fromUserId: $fromUserId)';
  }
}
