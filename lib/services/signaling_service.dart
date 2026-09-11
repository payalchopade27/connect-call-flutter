import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/constants/app_constants.dart';
import '../models/signaling_message.dart';

/// Connection states for the WebSocket signaling client.
///
/// Flow: disconnected → connecting → authenticating → authenticated
/// Error states: error (from any state)
enum SignalingConnectionState {
  disconnected,
  connecting,
  authenticating,
  authenticated,
  error,
}

/// Service managing WebSocket signaling communication with the FastAPI backend.
///
/// Implements the frozen signaling contract:
/// 1. Connect to WebSocket at SIGNALING_URL
/// 2. Send auth message as FIRST message: `{"type": "auth", "token": "<TOKEN>"}`
/// 3. Wait for `auth.success` before allowing call messages
/// 4. Route incoming call & WebRTC messages to the message stream
class SignalingService {
  final Duration authTimeoutDuration;

  SignalingService({
    this.authTimeoutDuration = const Duration(seconds: AppConstants.authTimeoutSeconds),
  });

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _authTimeoutTimer;

  final StreamController<SignalingMessage> _messageController =
      StreamController<SignalingMessage>.broadcast();
  final StreamController<SignalingConnectionState> _connectionStateController =
      StreamController<SignalingConnectionState>.broadcast();

  SignalingConnectionState _connectionState = SignalingConnectionState.disconnected;
  String? _currentUid;
  String? _verifiedUserId;

  /// Stream emitting incoming signaling messages (call/webrtc messages only; auth handled internally)
  Stream<SignalingMessage> get messageStream => _messageController.stream;

  /// Stream emitting connection state changes
  Stream<SignalingConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  /// Current connection state
  SignalingConnectionState get connectionState => _connectionState;

  /// Whether the service is fully authenticated and ready for call messages
  bool get isAuthenticated => _connectionState == SignalingConnectionState.authenticated;

  /// Legacy compatibility — returns true when authenticated
  bool get isConnected => isAuthenticated;

  /// Current user's UID (set after successful auth)
  String? get currentUid => _verifiedUserId ?? _currentUid;

  /// Connect to the FastAPI WebSocket signaling endpoint and authenticate.
  ///
  /// Flow:
  /// 1. Open WebSocket to [signalingUrl]
  /// 2. Send `{"type": "auth", "token": "..."}` as first message
  /// 3. Wait for `auth.success` (with 10s timeout)
  /// 4. Transition to `authenticated` state
  ///
  /// [idToken] is the Firebase ID token — it is NEVER logged.
  /// [uid] is the local Firebase UID for duplicate-connection prevention.
  /// [customChannel] allows injecting a mock channel for testing.
  Future<void> connect({
    required String signalingUrl,
    required String idToken,
    required String uid,
    WebSocketChannel? customChannel,
  }) async {
    // Prevent duplicate connections if already connected/authenticating with same user
    if ((_connectionState == SignalingConnectionState.authenticated ||
            _connectionState == SignalingConnectionState.authenticating ||
            _connectionState == SignalingConnectionState.connecting) &&
        _currentUid == uid &&
        customChannel == null) {
      debugPrint('ℹ️ [SignalingService] Already connected/connecting for user $uid. Skipping duplicate.');
      return;
    }

    // Clean up existing connection before reconnecting
    disconnect();

    _currentUid = uid;
    _updateState(SignalingConnectionState.connecting);

    try {
      final uri = Uri.parse(signalingUrl);
      debugPrint('🌐 [SignalingService] Connecting to WebSocket: ${uri.scheme}://${uri.host}:${uri.port}${uri.path} for UID: $uid');

      _channel = customChannel ?? WebSocketChannel.connect(uri);

      _subscription = _channel!.stream.listen(
        (data) {
          _onDataReceived(data);
        },
        onError: (error) {
          debugPrint('⚠️ [SignalingService] WebSocket error: $error');
          _updateState(SignalingConnectionState.error);
          _cleanupChannel();
        },
        onDone: () {
          debugPrint('🔌 [SignalingService] WebSocket connection closed.');
          _cancelAuthTimeout();
          _updateState(SignalingConnectionState.disconnected);
          _cleanupChannel();
        },
        cancelOnError: false,
      );

      // WebSocket is open — now send auth message as the FIRST message
      _updateState(SignalingConnectionState.authenticating);

      final authMsg = SignalingMessage.auth(idToken);
      _sendRaw(authMsg);
      debugPrint('🔐 [SignalingService] Auth message sent. Waiting for auth.success...');

      // Start auth timeout
      _startAuthTimeout();

    } catch (e) {
      debugPrint('❌ [SignalingService] Connection failed: $e');
      _updateState(SignalingConnectionState.error);
      _cleanupChannel();
    }
  }

  /// Parse and route incoming WebSocket messages.
  void _onDataReceived(dynamic rawData) {
    if (rawData == null) return;
    try {
      final String text = rawData.toString();
      final message = SignalingMessage.fromJson(text);

      // Route auth messages internally — they do not reach the call provider
      switch (message.type) {
        case SignalingMessageType.authSuccess:
          _handleAuthSuccess(message);
          return;
        case SignalingMessageType.authError:
          _handleAuthError(message);
          return;
      }

      // For call/webrtc messages, only forward if authenticated
      if (_connectionState != SignalingConnectionState.authenticated) {
        debugPrint('⚠️ [SignalingService] Received ${message.type} before authentication. Ignoring.');
        return;
      }

      debugPrint('📩 [SignalingService] Inbound message: ${message.type} (callId: ${message.callId})');
      _messageController.add(message);
    } catch (e) {
      debugPrint('⚠️ [SignalingService] Error parsing incoming message (ignoring malformed data): $e');
    }
  }

  void _handleAuthSuccess(SignalingMessage message) {
    _cancelAuthTimeout();

    _verifiedUserId = message.verifiedUserId ?? _currentUid;
    _updateState(SignalingConnectionState.authenticated);
    debugPrint('✅ [SignalingService] Authenticated as user: $_verifiedUserId');
  }

  void _handleAuthError(SignalingMessage message) {
    _cancelAuthTimeout();

    final code = message.errorCode ?? 'UNKNOWN';
    final errorMsg = message.errorMessage ?? 'Authentication failed';
    debugPrint('❌ [SignalingService] Auth error [$code]: $errorMsg');

    _updateState(SignalingConnectionState.error);
    _cleanupChannel();
  }

  void _startAuthTimeout() {
    _cancelAuthTimeout();
    _authTimeoutTimer = Timer(
      authTimeoutDuration,
      () {
        if (_connectionState == SignalingConnectionState.authenticating) {
          debugPrint('⏰ [SignalingService] Auth timeout after ${authTimeoutDuration.inSeconds}s');
          _updateState(SignalingConnectionState.error);
          _cleanupChannel();
        }
      },
    );
  }

  void _cancelAuthTimeout() {
    _authTimeoutTimer?.cancel();
    _authTimeoutTimer = null;
  }

  /// Send a raw message through the WebSocket (used for auth before authenticated state).
  void _sendRaw(SignalingMessage message) {
    if (_channel == null) {
      debugPrint('⚠️ [SignalingService] Cannot send ${message.type}: no WebSocket channel.');
      return;
    }

    try {
      final jsonStr = message.toJson();
      _channel!.sink.add(jsonStr);
    } catch (e) {
      debugPrint('❌ [SignalingService] Error sending message: $e');
    }
  }

  /// Send a signaling message envelope through the WebSocket.
  /// GUARDED: Only sends if authenticated. Call messages before auth are blocked.
  void send(SignalingMessage message) {
    if (_channel == null || _connectionState != SignalingConnectionState.authenticated) {
      debugPrint('⚠️ [SignalingService] Cannot send ${message.type}: not authenticated.');
      return;
    }

    try {
      final jsonStr = message.toJson();
      debugPrint('📤 [SignalingService] Outbound message: ${message.type} (callId: ${message.callId})');
      _channel!.sink.add(jsonStr);
    } catch (e) {
      debugPrint('❌ [SignalingService] Error sending message: $e');
    }
  }

  // ==========================================
  // Convenience methods matching frozen contract
  // ==========================================

  /// Send call.invite — does NOT include callerId (backend derives it).
  void sendInvite({
    required String callId,
    required String toUserId,
    required CallType callType,
  }) {
    send(SignalingMessage.invite(
      callId: callId,
      toUserId: toUserId,
      callType: callType,
    ));
  }

  /// Send call.accept — does NOT include callerId (backend derives it).
  void sendAccept({
    required String callId,
    required String toUserId,
  }) {
    send(SignalingMessage.accept(
      callId: callId,
      toUserId: toUserId,
    ));
  }

  /// Send call.reject — does NOT include callerId (backend derives it).
  void sendReject({
    required String callId,
    required String toUserId,
    String? reason,
  }) {
    send(SignalingMessage.reject(
      callId: callId,
      toUserId: toUserId,
      reason: reason ?? 'rejected',
    ));
  }

  /// Send call.end — does NOT include callerId (backend derives it).
  void sendEnd({
    required String callId,
    required String toUserId,
  }) {
    send(SignalingMessage.end(
      callId: callId,
      toUserId: toUserId,
    ));
  }

  /// Send webrtc.offer — does NOT include callerId (backend derives it).
  void sendOffer({
    required String callId,
    required String toUserId,
    required String sdp,
  }) {
    send(SignalingMessage.offer(
      callId: callId,
      toUserId: toUserId,
      sdp: sdp,
    ));
  }

  /// Send webrtc.answer — does NOT include callerId (backend derives it).
  void sendAnswer({
    required String callId,
    required String toUserId,
    required String sdp,
  }) {
    send(SignalingMessage.answer(
      callId: callId,
      toUserId: toUserId,
      sdp: sdp,
    ));
  }

  /// Send webrtc.ice candidate — does NOT include callerId (backend derives it).
  void sendIce({
    required String callId,
    required String toUserId,
    required dynamic candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  }) {
    send(SignalingMessage.ice(
      callId: callId,
      toUserId: toUserId,
      candidate: candidate,
      sdpMid: sdpMid,
      sdpMLineIndex: sdpMLineIndex,
    ));
  }

  /// Disconnect the WebSocket signaling connection.
  void disconnect() {
    _cancelAuthTimeout();
    _cleanupChannel();
    _currentUid = null;
    _verifiedUserId = null;
    _updateState(SignalingConnectionState.disconnected);
  }

  void _cleanupChannel() {
    _subscription?.cancel();
    _subscription = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void _updateState(SignalingConnectionState newState) {
    if (_connectionState == newState) return;
    _connectionState = newState;
    _connectionStateController.add(newState);
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _connectionStateController.close();
  }
}
