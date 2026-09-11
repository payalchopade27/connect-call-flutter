import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../core/constants/app_constants.dart';
import '../models/signaling_message.dart';

/// Connection states for the WebSocket signaling client
enum SignalingConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

/// Service managing WebSocket signaling communication with Person 1's FastAPI backend
class SignalingService {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  final StreamController<SignalingMessage> _messageController =
      StreamController<SignalingMessage>.broadcast();
  final StreamController<SignalingConnectionState> _connectionStateController =
      StreamController<SignalingConnectionState>.broadcast();

  SignalingConnectionState _connectionState = SignalingConnectionState.disconnected;
  String? _currentUid;
  String? _currentServerUrl;

  /// Stream emitting incoming signaling messages from other peers/backend
  Stream<SignalingMessage> get messageStream => _messageController.stream;

  /// Stream emitting connection state changes
  Stream<SignalingConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  /// Current connection state
  SignalingConnectionState get connectionState => _connectionState;

  /// Whether the WebSocket is currently connected
  bool get isConnected => _connectionState == SignalingConnectionState.connected;

  /// Current user's UID connected to the service
  String? get currentUid => _currentUid;

  /// Connect to the FastAPI WebSocket signaling endpoint using Firebase authentication
  Future<void> connect({
    required String serverUrl,
    required String idToken,
    required String uid,
    WebSocketChannel? customChannel,
  }) async {
    // Prevent duplicate connections if already connected with same user
    if ((_connectionState == SignalingConnectionState.connected ||
            _connectionState == SignalingConnectionState.connecting) &&
        _currentUid == uid &&
        _currentServerUrl == serverUrl &&
        customChannel == null) {
      debugPrint('ℹ️ [SignalingService] Already connected/connecting for user $uid. Skipping duplicate.');
      return;
    }

    // Clean up existing connection if changing user or server
    disconnect();

    _currentUid = uid;
    _currentServerUrl = serverUrl;
    _updateState(SignalingConnectionState.connecting);

    try {
      final uri = AppConstants.buildSignalingUri(baseUrl: serverUrl, token: idToken);
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
          _updateState(SignalingConnectionState.disconnected);
          _cleanupChannel();
        },
        cancelOnError: false,
      );

      _updateState(SignalingConnectionState.connected);
      debugPrint('✅ [SignalingService] Connected to signaling backend.');
    } catch (e) {
      debugPrint('❌ [SignalingService] Connection failed: $e');
      _updateState(SignalingConnectionState.error);
      _cleanupChannel();
    }
  }

  /// Parse and distribute incoming WebSocket payload
  void _onDataReceived(dynamic rawData) {
    if (rawData == null) return;
    try {
      final String text = rawData.toString();
      final message = SignalingMessage.fromJson(text);
      debugPrint('📩 [SignalingService] Inbound message: ${message.type} (callId: ${message.callId})');
      _messageController.add(message);
    } catch (e) {
      debugPrint('⚠️ [SignalingService] Error parsing incoming message (ignoring malformed data): $e');
    }
  }

  /// Send a signaling message envelope through the WebSocket
  void send(SignalingMessage message) {
    if (_channel == null || _connectionState != SignalingConnectionState.connected) {
      debugPrint('⚠️ [SignalingService] Cannot send ${message.type}: WebSocket not connected.');
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

  /// Convenience helper to send call.invite
  void sendInvite({
    required String callId,
    required String callerId,
    required String receiverId,
    required String callerName,
    required String receiverName,
    required CallType callType,
  }) {
    send(SignalingMessage(
      type: SignalingMessageType.callInvite,
      callId: callId,
      callerId: callerId,
      receiverId: receiverId,
      callerName: callerName,
      receiverName: receiverName,
      callType: callType,
    ));
  }

  /// Convenience helper to send call.accept
  void sendAccept({
    required String callId,
    required String callerId,
    required String receiverId,
  }) {
    send(SignalingMessage(
      type: SignalingMessageType.callAccept,
      callId: callId,
      callerId: callerId,
      receiverId: receiverId,
    ));
  }

  /// Convenience helper to send call.reject
  void sendReject({
    required String callId,
    required String callerId,
    required String receiverId,
    String? reason,
  }) {
    send(SignalingMessage(
      type: SignalingMessageType.callReject,
      callId: callId,
      callerId: callerId,
      receiverId: receiverId,
      data: reason != null ? {'reason': reason} : null,
    ));
  }

  /// Convenience helper to send call.end
  void sendEnd({
    required String callId,
    required String callerId,
    required String receiverId,
  }) {
    send(SignalingMessage(
      type: SignalingMessageType.callEnd,
      callId: callId,
      callerId: callerId,
      receiverId: receiverId,
    ));
  }

  /// Disconnect the WebSocket signaling connection
  void disconnect() {
    _cleanupChannel();
    _currentUid = null;
    _currentServerUrl = null;
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

  void _updateState(SignalingConnectionState state) {
    if (_connectionState == state) return;
    _connectionState = state;
    _connectionStateController.add(state);
  }

  void dispose() {
    disconnect();
    _messageController.close();
    _connectionStateController.close();
  }
}

