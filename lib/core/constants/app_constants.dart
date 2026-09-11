class AppConstants {
  static const String appName = 'ConnectCall';
  static const String appTagline = 'Seamless HD Audio & Video Calling';

  /// Production WebSocket signaling endpoint (authoritative).
  static const String defaultSignalingUrl =
      'wss://connect-call-flutter.onrender.com/ws/signaling';

  /// Active signaling server URL — the single centralized configuration value.
  static String signalingUrl = defaultSignalingUrl;

  /// Authentication timeout in seconds.
  /// Backend will disconnect if auth message is not received within this window.
  static const int authTimeoutSeconds = 10;

  /// Centralized ICE / STUN servers configuration for WebRTC.
  /// Development default uses public Google STUN servers.
  /// Replaceable at runtime or in production with TURN server credentials.
  static const Map<String, dynamic> defaultIceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ],
  };

  /// Active ICE servers configuration (easy to replace with production TURN).
  static Map<String, dynamic> iceServers = defaultIceServers;

  /// WebRTC audio-only media constraints for getUserMedia
  static const Map<String, dynamic> audioMediaConstraints = {
    'audio': true,
    'video': false,
  };

  /// WebRTC audio+video media constraints for getUserMedia (video calls)
  static const Map<String, dynamic> videoMediaConstraints = {
    'audio': true,
    'video': {
      'facingMode': 'user',
      'width': {'ideal': 1280},
      'height': {'ideal': 720},
    },
  };

  /// WebRTC audio-only SDP constraints for offer/answer
  static const Map<String, dynamic> audioSdpConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': false,
    },
    'optional': [],
  };

  /// WebRTC audio+video SDP constraints for offer/answer (video calls)
  static const Map<String, dynamic> videoSdpConstraints = {
    'mandatory': {
      'OfferToReceiveAudio': true,
      'OfferToReceiveVideo': true,
    },
    'optional': [],
  };
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
