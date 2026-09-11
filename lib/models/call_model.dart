import '../core/constants/app_constants.dart';

class CallModel {
  final String callId;
  final String callerId;
  final String receiverId;
  final String callerName;
  final String receiverName;
  final CallType callType;
  final CallState state;
  final CallDirection direction;
  final DateTime startedAt;
  final DateTime? connectedAt;
  final DateTime? endedAt;
  final int duration; // In seconds
  final CallEndReason endReason;

  CallModel({
    required this.callId,
    required this.callerId,
    required this.receiverId,
    required this.callerName,
    required this.receiverName,
    required this.callType,
    required this.state,
    required this.direction,
    required this.startedAt,
    this.connectedAt,
    this.endedAt,
    this.duration = 0,
    this.endReason = CallEndReason.none,
  });

  /// Returns the other participant's UID relative to the given [currentUid].
  String getPeerUid(String currentUid) {
    return currentUid == callerId ? receiverId : callerId;
  }

  /// Returns the other participant's name relative to the given [currentUid].
  String getPeerName(String currentUid) {
    return currentUid == callerId ? receiverName : callerName;
  }

  /// Returns true if this call is an incoming call
  bool get isIncoming => direction == CallDirection.incoming;

  /// Returns true if the call is currently in an active or establishing state
  bool get isActive =>
      state == CallState.connected ||
      state == CallState.calling ||
      state == CallState.ringing ||
      state == CallState.connecting;

  /// Returns true if the call has terminated
  bool get isEnded =>
      state == CallState.ended ||
      state == CallState.rejected ||
      state == CallState.missed ||
      state == CallState.busy ||
      state == CallState.failed ||
      state == CallState.disconnected;

  Map<String, dynamic> toMap() {
    return {
      'callId': callId,
      'callerId': callerId,
      'receiverId': receiverId,
      'callerName': callerName,
      'receiverName': receiverName,
      'callType': callType.toJson(),
      'state': state.toJson(),
      'direction': direction.toJson(),
      'startedAt': startedAt.toIso8601String(),
      'connectedAt': connectedAt?.toIso8601String(),
      'endedAt': endedAt?.toIso8601String(),
      'duration': duration,
      'endReason': endReason.toJson(),
    };
  }

  factory CallModel.fromMap(Map<String, dynamic> map, String id) {
    return CallModel(
      callId: map['callId'] ?? id,
      callerId: map['callerId'] ?? map['callerUid'] ?? '',
      receiverId: map['receiverId'] ?? map['receiverUid'] ?? '',
      callerName: map['callerName'] ?? 'Unknown Caller',
      receiverName: map['receiverName'] ?? 'Unknown Receiver',
      callType: CallType.fromJson(map['callType'] ?? 'audio'),
      state: CallState.fromJson(map['state'] ?? map['status'] ?? 'idle'),
      direction: CallDirection.fromJson(map['direction'] ?? 'outgoing'),
      startedAt: map['startedAt'] != null
          ? DateTime.tryParse(map['startedAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      connectedAt: map['connectedAt'] != null
          ? DateTime.tryParse(map['connectedAt'].toString())
          : null,
      endedAt: map['endedAt'] != null
          ? DateTime.tryParse(map['endedAt'].toString())
          : null,
      duration: map['duration'] ?? 0,
      endReason: CallEndReason.fromJson(map['endReason'] ?? 'none'),
    );
  }

  CallModel copyWith({
    String? callId,
    String? callerId,
    String? receiverId,
    String? callerName,
    String? receiverName,
    CallType? callType,
    CallState? state,
    CallDirection? direction,
    DateTime? startedAt,
    DateTime? connectedAt,
    DateTime? endedAt,
    int? duration,
    CallEndReason? endReason,
  }) {
    return CallModel(
      callId: callId ?? this.callId,
      callerId: callerId ?? this.callerId,
      receiverId: receiverId ?? this.receiverId,
      callerName: callerName ?? this.callerName,
      receiverName: receiverName ?? this.receiverName,
      callType: callType ?? this.callType,
      state: state ?? this.state,
      direction: direction ?? this.direction,
      startedAt: startedAt ?? this.startedAt,
      connectedAt: connectedAt ?? this.connectedAt,
      endedAt: endedAt ?? this.endedAt,
      duration: duration ?? this.duration,
      endReason: endReason ?? this.endReason,
    );
  }
}
