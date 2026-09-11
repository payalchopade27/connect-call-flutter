class AppConstants {
  static const String appName = 'ConnectCall';
  static const String appTagline = 'Seamless HD Audio & Video Calling';
  
  // Default WebSocket URL placeholder for backend signaling
  static const String defaultSignalingUrl = 'ws://10.0.2.2:8000/ws/call';
}

/// Call types specified in team contract
enum CallType {
  audio,
  video;

  String toJson() => name;
  static CallType fromJson(String json) =>
      CallType.values.firstWhere((e) => e.name == json, orElse: () => CallType.audio);
}

/// Call direction
enum CallDirection {
  incoming,
  outgoing;

  String toJson() => name;
  static CallDirection fromJson(String json) =>
      CallDirection.values.firstWhere((e) => e.name == json, orElse: () => CallDirection.outgoing);
}

/// Call states specified in team contract
enum CallState {
  idle,
  calling,
  ringing,
  connecting,
  connected,
  ended,
  rejected,
  missed,
  busy,
  failed,
  disconnected;

  String toJson() => name;
  static CallState fromJson(String json) =>
      CallState.values.firstWhere((e) => e.name == json, orElse: () => CallState.idle);
}

/// Call end reasons
enum CallEndReason {
  userEnded,
  rejected,
  missed,
  busy,
  failed,
  disconnected,
  none;

  String toJson() => name;
  static CallEndReason fromJson(String json) =>
      CallEndReason.values.firstWhere((e) => e.name == json, orElse: () => CallEndReason.none);
}
