class AppConstants {
  static const String appName = 'ConnectCall';
  static const String appTagline = 'Seamless HD Audio & Video Calling';

  /// Default WebSocket URL for backend signaling.
  ///
  /// NOTE: Replace with your actual FastAPI server host/port.
  /// - Android emulator loopback: `ws://10.0.2.2:8000/ws/signaling`
  /// - iOS simulator / desktop: `ws://localhost:8000/ws/signaling`
  /// - Physical devices: `ws://{YOUR_LAN_IP}:8000/ws/signaling`
  static const String defaultSignalingUrl = 'ws://10.0.2.2:8000/ws/signaling';

  /// Active signaling server URL — the single centralized configuration value.
  /// Change this to point to your backend before running.
  static String signalingUrl = defaultSignalingUrl;

  /// Authentication timeout in seconds.
  /// Backend will disconnect if auth message is not received within this window.
  static const int authTimeoutSeconds = 10;
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
