import 'package:flutter/foundation.dart';

/// Clean placeholder for Person 1's WebSocket signaling client
class SignalingService {
  void connect(String uid) {
    debugPrint('[SignalingService Placeholder] Connect called for $uid');
  }

  void disconnect() {
    debugPrint('[SignalingService Placeholder] Disconnect called');
  }
}
