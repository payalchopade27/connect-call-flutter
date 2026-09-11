import 'dart:convert';
import '../core/constants/app_constants.dart';

/// Standard message types agreed upon in the backend signaling contract.
class SignalingMessageType {
  static const String callInvite = 'call.invite';
  static const String callAccept = 'call.accept';
  static const String callReject = 'call.reject';
  static const String callEnd = 'call.end';
  static const String webrtcOffer = 'webrtc.offer';
  static const String webrtcAnswer = 'webrtc.answer';
  static const String webrtcIce = 'webrtc.ice';
  static const String callError = 'call.error';
  static const String peerDisconnected = 'peer.disconnected';
}

/// Centralized signaling message envelope for WebSocket communication with FastAPI.
class SignalingMessage {
  final String type;
  final String callId;
  final String callerId;
  final String receiverId;
  final String? callerName;
  final String? receiverName;
  final CallType? callType;
  final Map<String, dynamic>? data;

  SignalingMessage({
    required this.type,
    required this.callId,
    required this.callerId,
    required this.receiverId,
    this.callerName,
    this.receiverName,
    this.callType,
    this.data,
  });

  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{
      'type': type,
      'callId': callId,
      'callerId': callerId,
      'receiverId': receiverId,
    };

    if (callerName != null) map['callerName'] = callerName;
    if (receiverName != null) map['receiverName'] = receiverName;
    if (callType != null) map['callType'] = callType!.name;
    if (data != null) map['data'] = data;

    return map;
  }

  String toJson() => jsonEncode(toMap());

  factory SignalingMessage.fromMap(Map<String, dynamic> map) {
    CallType? parsedCallType;
    if (map['callType'] != null) {
      final ctStr = map['callType'].toString().toLowerCase();
      parsedCallType = ctStr == 'video' ? CallType.video : CallType.audio;
    }

    Map<String, dynamic>? parsedData;
    if (map['data'] is Map<String, dynamic>) {
      parsedData = map['data'] as Map<String, dynamic>;
    } else if (map['payload'] is Map<String, dynamic>) {
      parsedData = map['payload'] as Map<String, dynamic>;
    }

    return SignalingMessage(
      type: map['type']?.toString() ?? '',
      callId: map['callId']?.toString() ?? '',
      callerId: map['callerId']?.toString() ?? map['senderId']?.toString() ?? '',
      receiverId: map['receiverId']?.toString() ?? map['targetId']?.toString() ?? '',
      callerName: map['callerName']?.toString(),
      receiverName: map['receiverName']?.toString(),
      callType: parsedCallType,
      data: parsedData,
    );
  }

  factory SignalingMessage.fromJson(String jsonStr) {
    final Map<String, dynamic> map = jsonDecode(jsonStr) as Map<String, dynamic>;
    return SignalingMessage.fromMap(map);
  }

  @override
  String toString() {
    return 'SignalingMessage(type: $type, callId: $callId, callerId: $callerId, receiverId: $receiverId, callType: $callType)';
  }
}
