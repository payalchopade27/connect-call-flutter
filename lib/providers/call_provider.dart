import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';
import '../core/constants/app_constants.dart';
import '../models/call_model.dart';
import '../models/signaling_message.dart';
import '../models/user_model.dart';
import '../services/signaling_service.dart';
import '../services/webrtc_service.dart';
import 'auth_provider.dart';
import 'history_provider.dart';
import 'users_provider.dart';

class ActiveCallState {
  final CallModel? activeCall;
  final CallState callState;
  final int durationSeconds;
  final String? errorMessage;
  final bool isMuted;
  final bool isSpeakerOn;
  final bool isVideoMuted;
  final bool isFrontCamera;

  ActiveCallState({
    this.activeCall,
    this.callState = CallState.idle,
    this.durationSeconds = 0,
    this.errorMessage,
    this.isMuted = false,
    this.isSpeakerOn = false,
    this.isVideoMuted = false,
    this.isFrontCamera = true,
  });

  ActiveCallState copyWith({
    CallModel? activeCall,
    CallState? callState,
    int? durationSeconds,
    String? errorMessage,
    bool? isMuted,
    bool? isSpeakerOn,
    bool? isVideoMuted,
    bool? isFrontCamera,
    bool clearActiveCall = false,
    bool clearErrorMessage = false,
  }) {
    return ActiveCallState(
      activeCall: clearActiveCall ? null : (activeCall ?? this.activeCall),
      callState: callState ?? this.callState,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      isMuted: isMuted ?? this.isMuted,
      isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
      isVideoMuted: isVideoMuted ?? this.isVideoMuted,
      isFrontCamera: isFrontCamera ?? this.isFrontCamera,
    );
  }
}

class CallNotifier extends StateNotifier<ActiveCallState> {
  final Ref _ref;
  final SignalingService _signalingService;
  final WebRTCService _webrtcService;
  Timer? _durationTimer;
  Timer? _cleanupTimer;
  Timer? _ringingTimeoutTimer;
  StreamSubscription<SignalingMessage>? _signalingSubscription;
  bool _hasRecordedHistory = false;

  CallNotifier(this._ref)
      : _signalingService = _ref.read(signalingServiceProvider),
        _webrtcService = _ref.read(webRTCServiceProvider),
        super(ActiveCallState()) {
    _listenToSignaling();
    _signalingService.onReconnectRequested = () => connectSignaling();
  }

  /// Default timeout for unanswered incoming or outgoing calls (30 seconds)
  static const Duration ringingTimeoutDuration = Duration(seconds: 30);

  /// Allowed state transitions matrix to protect against invalid state jumps
  static const Map<CallState, Set<CallState>> _allowedTransitions = {
    CallState.idle: {CallState.calling, CallState.ringing},
    CallState.calling: {
      CallState.connecting,
      CallState.connected,
      CallState.rejected,
      CallState.busy,
      CallState.failed,
      CallState.ended,
    },
    CallState.ringing: {
      CallState.connecting,
      CallState.connected,
      CallState.rejected,
      CallState.missed,
      CallState.busy,
      CallState.failed,
      CallState.ended,
    },
    CallState.connecting: {
      CallState.connected,
      CallState.failed,
      CallState.disconnected,
      CallState.ended,
    },
    CallState.connected: {
      CallState.disconnected,
      CallState.ended,
      CallState.failed,
    },
    CallState.rejected: {CallState.ended, CallState.idle},
    CallState.missed: {CallState.ended, CallState.idle},
    CallState.busy: {CallState.ended, CallState.idle},
    CallState.failed: {CallState.ended, CallState.idle},
    CallState.disconnected: {CallState.ended, CallState.idle},
    CallState.ended: {CallState.idle},
  };

  /// Verify if transition from currentState to targetState is valid
  bool _canTransitionTo(CallState targetState) {
    final allowed = _allowedTransitions[state.callState];
    if (allowed == null || !allowed.contains(targetState)) {
      debugPrint('⚠️ [CallNotifier] Disallowed state transition: ${state.callState} -> $targetState');
      return false;
    }
    return true;
  }

  /// Request microphone permission before starting/answering an audio call.
  Future<bool> _checkMicrophonePermission() async {
    try {
      final status = await Permission.microphone.request();
      if (status.isGranted) {
        return true;
      } else if (status.isPermanentlyDenied) {
        setFailed('Microphone permission is permanently denied. Please enable it in device settings.');
        return false;
      } else {
        setFailed('Microphone permission is required for audio calling.');
        return false;
      }
    } catch (e) {
      debugPrint('ℹ️ [CallNotifier] Mic permission check fallback (e.g. test environment): $e');
      return true;
    }
  }

  /// Request both microphone and camera permissions before starting/answering a video call.
  Future<bool> _checkVideoPermissions() async {
    try {
      final micStatus = await Permission.microphone.request();
      final cameraStatus = await Permission.camera.request();

      if (micStatus.isPermanentlyDenied || cameraStatus.isPermanentlyDenied) {
        setFailed(
          'Camera/microphone permission is permanently denied. '
          'Please enable it in device settings.',
        );
        return false;
      }
      if (!micStatus.isGranted) {
        setFailed('Microphone permission is required for video calling.');
        return false;
      }
      if (!cameraStatus.isGranted) {
        setFailed('Camera permission is required for video calling.');
        return false;
      }
      return true;
    } catch (e) {
      debugPrint('ℹ️ [CallNotifier] Camera permission check fallback: $e');
      return true;
    }
  }

  /// Connect the WebSocket signaling service using current authenticated Firebase credentials.
  /// Auth token is sent as the first WebSocket message per the frozen contract.
  Future<void> connectSignaling({String? customUrl, String? token, String? uid}) async {
    try {
      // Fallback directly to FirebaseAuth.instance.currentUser if currentUserProvider
      // hasn't emitted its first value yet on app start.
      final user = _ref.read(currentUserProvider) ?? FirebaseAuth.instance.currentUser;
      final effectiveUid = uid ?? user?.uid;
      if (effectiveUid == null || effectiveUid.isEmpty) {
        debugPrint('ℹ️ [CallNotifier] Cannot connect signaling: no user UID available.');
        return;
      }

      final effectiveToken = token ?? (user != null ? await user.getIdToken() : null) ?? '';
      if (effectiveToken.isEmpty) {
        debugPrint('ℹ️ [CallNotifier] Cannot connect signaling: empty ID token.');
        return;
      }

      await _signalingService.connect(
        signalingUrl: customUrl ?? AppConstants.signalingUrl,
        idToken: effectiveToken,
        uid: effectiveUid,
      );
    } catch (e) {
      debugPrint('⚠️ [CallNotifier] connectSignaling error: $e');
    }
  }

  /// Disconnect signaling service
  void disconnectSignaling() {
    _signalingService.disconnect();
  }

  /// Subscribe to inbound WebSocket messages from SignalingService.
  void _listenToSignaling() {
    _signalingSubscription?.cancel();
    _signalingSubscription = _signalingService.messageStream.listen(
      _handleIncomingSignalingMessage,
      onError: (err) {
        debugPrint('⚠️ [CallNotifier] Signaling stream error: $err');
      },
    );
  }

  /// Wire up WebRTCService callbacks for ICE candidates, connection states, and errors.
  void _setupWebRTCCallbacks({bool isVideo = false}) {
    _webrtcService.onLocalIceCandidate = (RTCIceCandidate candidate) {
      if (state.activeCall == null) return;
      final targetUserId = state.activeCall!.getPeerUid(
        _signalingService.currentUid ?? state.activeCall!.callerId,
      );

      _signalingService.sendIce(
        callId: state.activeCall!.callId,
        toUserId: targetUserId,
        candidate: candidate.candidate,
        sdpMid: candidate.sdpMid,
        sdpMLineIndex: candidate.sdpMLineIndex,
      );
    };

    _webrtcService.onConnectionStateChange = (RTCPeerConnectionState pcState) {
      debugPrint('📶 [CallNotifier] WebRTC connection state changed: $pcState');
      if (pcState == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        if (state.callState == CallState.connecting || state.callState == CallState.calling) {
          setConnected();
        }
      } else if (pcState == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        if (state.callState == CallState.connected) {
          setDisconnected();
        }
      } else if (pcState == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        setFailed('Media connection failed');
      }
    };

    _webrtcService.onError = (String error) {
      debugPrint('❌ [CallNotifier] WebRTC error: $error');
      setFailed(error);
    };
  }

  /// Process inbound signaling messages
  void _handleIncomingSignalingMessage(SignalingMessage message) {
    debugPrint('🔔 [CallNotifier] Processing signaling message: ${message.type} (callId: ${message.callId})');

    switch (message.type) {
      case SignalingMessageType.callInvite:
        _handleInboundInvite(message);
        break;

      case SignalingMessageType.callAccept:
        _handleInboundAccept(message);
        break;

      case SignalingMessageType.callReject:
        _handleInboundReject(message);
        break;

      case SignalingMessageType.callEnd:
        _handleInboundEnd(message);
        break;

      case SignalingMessageType.webrtcOffer:
        _handleInboundOffer(message);
        break;

      case SignalingMessageType.webrtcAnswer:
        _handleInboundAnswer(message);
        break;

      case SignalingMessageType.webrtcIce:
        _handleInboundIce(message);
        break;

      case SignalingMessageType.peerDisconnected:
        _handleInboundPeerDisconnected(message);
        break;

      case SignalingMessageType.callError:
        _handleInboundError(message);
        break;

      default:
        debugPrint('ℹ️ [CallNotifier] Unhandled signaling message type: ${message.type}');
        break;
    }
  }

  void _handleInboundInvite(SignalingMessage message) {
    // If already in an active or pending call, auto-reject with busy
    if (state.activeCall != null && state.activeCall!.isActive) {
      debugPrint('⚠️ [CallNotifier] Line busy. Auto-rejecting incoming call ${message.callId}');
      _signalingService.sendReject(
        callId: message.callId ?? '',
        toUserId: message.fromUserId ?? '',
        reason: 'busy',
      );
      return;
    }

    _cancelTimers();
    _hasRecordedHistory = false;

    // Extract caller UID from the incoming fromUserId field (set by backend)
    final callerUid = message.fromUserId ?? '';
    final receiverUid = message.toUserId ?? _signalingService.currentUid ?? '';
    final incomingCallType = message.callType ?? CallType.audio;

    final incomingCall = CallModel(
      callId: message.callId ?? '',
      callerId: callerUid,
      receiverId: receiverUid,
      callerName: callerUid,
      receiverName: 'Me',
      callType: incomingCallType,
      state: CallState.ringing,
      direction: CallDirection.incoming,
      startedAt: DateTime.now(),
    );

    state = ActiveCallState(
      activeCall: incomingCall,
      callState: CallState.ringing,
      durationSeconds: 0,
      isMuted: false,
      isSpeakerOn: incomingCallType == CallType.video,
      isVideoMuted: false,
      isFrontCamera: true,
    );

    _startRingingTimeout(isIncoming: true);

    // Asynchronously resolve caller's real display name from Firestore
    _resolveCallerName(callerUid, incomingCall.callId);
  }

  Future<void> _resolveCallerName(String callerUid, String callId) async {
    try {
      final user = await _ref.read(userServiceProvider).getUserProfileOnce(callerUid);
      if (user != null && user.name.isNotEmpty && mounted) {
        if (state.activeCall?.callId == callId) {
          final updated = state.activeCall!.copyWith(callerName: user.name);
          state = state.copyWith(activeCall: updated);
        }
      }
    } catch (e) {
      debugPrint('ℹ️ [CallNotifier] Could not resolve caller display name: $e');
    }
  }

  /// Caller side: Callee accepted the call -> initialize WebRTC and send SDP offer.
  Future<void> _handleInboundAccept(SignalingMessage message) async {
    if (state.activeCall == null || state.activeCall!.callId != message.callId) {
      debugPrint('⚠️ [CallNotifier] Received accept for non-matching callId: ${message.callId}');
      return;
    }

    if (state.callState == CallState.calling || state.callState == CallState.connecting) {
      _cancelRingingTimeout();
      setConnecting();

      final isVideo = state.activeCall!.callType == CallType.video;

      try {
        _setupWebRTCCallbacks(isVideo: isVideo);
        if (_webrtcService.peerConnection == null) {
          if (isVideo) {
            await _webrtcService.initializeVideo();
          } else {
            await _webrtcService.initialize();
          }
        }

        final offerSdp = await _webrtcService.createOffer(isVideo: isVideo);
        final otherUserId = state.activeCall!.getPeerUid(
          _signalingService.currentUid ?? state.activeCall!.callerId,
        );

        _signalingService.sendOffer(
          callId: state.activeCall!.callId,
          toUserId: otherUserId,
          sdp: offerSdp,
        );
      } catch (e) {
        debugPrint('❌ [CallNotifier] Failed to create WebRTC offer on accept: $e');
        setFailed('WebRTC initialization failed. Please check microphone permissions and try again.');
      }
    }
  }

  /// Callee side: Receive remote SDP offer -> set remote description and send SDP answer.
  Future<void> _handleInboundOffer(SignalingMessage message) async {
    if (state.activeCall == null || state.activeCall!.callId != message.callId) {
      debugPrint('⚠️ [CallNotifier] Received offer for non-matching callId: ${message.callId}');
      return;
    }

    final offerSdp = message.sdp;
    if (offerSdp == null || offerSdp.isEmpty) {
      debugPrint('⚠️ [CallNotifier] Received webrtc.offer without SDP payload.');
      return;
    }

    final isVideo = state.activeCall!.callType == CallType.video;

    try {
      _setupWebRTCCallbacks(isVideo: isVideo);
      if (_webrtcService.peerConnection == null) {
        if (isVideo) {
          await _webrtcService.initializeVideo();
        } else {
          await _webrtcService.initialize();
        }
      }

      final answerSdp = await _webrtcService.handleOfferAndCreateAnswer(
        offerSdp,
        isVideo: isVideo,
      );
      final otherUserId = state.activeCall!.getPeerUid(
        _signalingService.currentUid ?? state.activeCall!.callerId,
      );

      _signalingService.sendAnswer(
        callId: state.activeCall!.callId,
        toUserId: otherUserId,
        sdp: answerSdp,
      );
      setConnecting();
    } catch (e) {
      debugPrint('❌ [CallNotifier] Error handling webrtc.offer: $e');
      setFailed('Failed to establish media connection: $e');
    }
  }

  /// Caller side: Receive remote SDP answer -> set remote description and drain queued ICE candidates.
  Future<void> _handleInboundAnswer(SignalingMessage message) async {
    if (state.activeCall == null || state.activeCall!.callId != message.callId) {
      debugPrint('⚠️ [CallNotifier] Received answer for non-matching callId: ${message.callId}');
      return;
    }

    final answerSdp = message.sdp;
    if (answerSdp == null || answerSdp.isEmpty) {
      debugPrint('⚠️ [CallNotifier] Received webrtc.answer without SDP payload.');
      return;
    }

    try {
      await _webrtcService.handleRemoteAnswer(answerSdp);
      setConnecting();
    } catch (e) {
      debugPrint('❌ [CallNotifier] Error handling webrtc.answer: $e');
      setFailed('Failed to complete media handshake: $e');
    }
  }

  /// Both sides: Receive remote ICE candidate and add to peer connection.
  void _handleInboundIce(SignalingMessage message) {
    if (state.activeCall == null || state.activeCall!.callId != message.callId) {
      return;
    }

    _webrtcService.addRemoteIceCandidate(
      candidateData: message.candidate,
      sdpMid: message.sdpMid,
      sdpMLineIndex: message.sdpMLineIndex,
    );
  }

  void _handleInboundReject(SignalingMessage message) {
    if (state.activeCall == null || state.activeCall!.callId != message.callId) return;

    _cancelTimers();
    _webrtcService.cleanup();

    final isBusy = message.reason == 'busy';
    final targetState = isBusy ? CallState.busy : CallState.rejected;
    final endReason = isBusy ? CallEndReason.busy : CallEndReason.rejected;

    if (!_canTransitionTo(targetState)) return;

    final updatedCall = state.activeCall!.copyWith(
      state: targetState,
      endedAt: DateTime.now(),
      endReason: endReason,
    );

    state = state.copyWith(
      activeCall: updatedCall,
      callState: targetState,
    );

    _recordCallToHistory(updatedCall);
    _scheduleCleanup();
  }

  void _handleInboundEnd(SignalingMessage message) {
    if (state.activeCall == null || state.activeCall!.callId != message.callId) return;
    debugPrint('📞 [CallNotifier] Peer ended the call: ${message.callId}');
    _cancelTimers();
    _webrtcService.cleanup();

    if (!_canTransitionTo(CallState.ended)) return;

    final updatedCall = state.activeCall!.copyWith(
      state: CallState.ended,
      endedAt: DateTime.now(),
      duration: state.durationSeconds,
      endReason: CallEndReason.userEnded,
    );

    state = state.copyWith(
      activeCall: updatedCall,
      callState: CallState.ended,
    );

    _recordCallToHistory(updatedCall);
    _scheduleCleanup();
  }

  void _handleInboundPeerDisconnected(SignalingMessage message) {
    if (state.activeCall == null || state.activeCall!.callId != message.callId) return;
    debugPrint('🔌 [CallNotifier] Peer disconnected: ${message.callId}');
    _webrtcService.cleanup();
    setDisconnected();
  }

  void _handleInboundError(SignalingMessage message) {
    final errorMsg = message.errorMessage ?? 'Call signaling error';
    debugPrint('❌ [CallNotifier] Call error received: $errorMsg (code: ${message.errorCode}, callId: ${message.callId})');

    // Only fail the call if an active call exists and matches the error
    if (state.activeCall != null) {
      if (message.callId == null ||
          message.callId!.isEmpty ||
          message.callId == state.activeCall!.callId) {
        _webrtcService.cleanup();
        setFailed(errorMsg);
      } else {
        debugPrint('ℹ️ [CallNotifier] Ignoring call error for other callId: ${message.callId}');
      }
    } else {
      debugPrint('ℹ️ [CallNotifier] Ignoring call error while idle: $errorMsg');
    }
  }

  // ==========================================
  // LOCAL CALL CONTROLS (Hooked to WebRTC)
  // ==========================================

  void toggleMute() {
    final newMute = !state.isMuted;
    _webrtcService.setMicrophoneMute(newMute);
    state = state.copyWith(isMuted: newMute);
  }

  void toggleSpeaker() {
    final newSpeaker = !state.isSpeakerOn;
    _webrtcService.enableSpeakerphone(newSpeaker);
    state = state.copyWith(isSpeakerOn: newSpeaker);
  }

  /// Toggle local camera video track on/off.
  void toggleVideo() {
    final newVideoMuted = !state.isVideoMuted;
    _webrtcService.setVideoMute(newVideoMuted);
    state = state.copyWith(isVideoMuted: newVideoMuted);
  }

  /// Switch between front and rear camera.
  Future<void> switchCamera() async {
    await _webrtcService.switchCamera();
    state = state.copyWith(isFrontCamera: !state.isFrontCamera);
  }

  // ==========================================
  // CALL FLOW LIFECYCLE
  // ==========================================

  /// Initiate an outgoing call (audio or video).
  /// Checks required permissions, creates UUID callId, and sends call.invite.
  Future<void> startOutgoingCall({
    required UserModel targetUser,
    required CallType callType,
    required UserModel currentUser,
  }) async {
    _cancelTimers();
    _hasRecordedHistory = false;

    // 1. Check required permissions based on call type
    final bool hasPermission = callType == CallType.video
        ? await _checkVideoPermissions()
        : await _checkMicrophonePermission();
    if (!hasPermission) return;

    if (!_canTransitionTo(CallState.calling)) {
      state = ActiveCallState(callState: CallState.idle);
    }

    final callId = const Uuid().v4();
    final newCall = CallModel(
      callId: callId,
      callerId: currentUser.uid,
      receiverId: targetUser.uid,
      callerName: currentUser.name,
      receiverName: targetUser.name,
      callType: callType,
      state: CallState.calling,
      direction: CallDirection.outgoing,
      startedAt: DateTime.now(),
    );

    state = ActiveCallState(
      activeCall: newCall,
      callState: CallState.calling,
      durationSeconds: 0,
      isMuted: false,
      isSpeakerOn: callType == CallType.video,
      isVideoMuted: false,
      isFrontCamera: true,
    );

    // Send call.invite per frozen contract — no callerId
    _signalingService.sendInvite(
      callId: callId,
      toUserId: targetUser.uid,
      callType: callType,
    );

    _startRingingTimeout(isIncoming: false);
  }

  /// Simulate receiving an incoming call (for testing & local demonstration)
  void receiveIncomingCall({
    required UserModel caller,
    required CallType callType,
    String? currentUid,
    String? currentName,
  }) {
    _cancelTimers();
    _hasRecordedHistory = false;

    if (!_canTransitionTo(CallState.ringing)) {
      state = ActiveCallState(callState: CallState.idle);
    }

    final callId = const Uuid().v4();
    final newCall = CallModel(
      callId: callId,
      callerId: caller.uid,
      receiverId: currentUid ?? 'me',
      callerName: caller.name,
      receiverName: currentName ?? 'Me',
      callType: callType,
      state: CallState.ringing,
      direction: CallDirection.incoming,
      startedAt: DateTime.now(),
    );

    state = ActiveCallState(
      activeCall: newCall,
      callState: CallState.ringing,
      durationSeconds: 0,
      isMuted: false,
      isSpeakerOn: callType == CallType.video,
      isVideoMuted: false,
      isFrontCamera: true,
    );

    _startRingingTimeout(isIncoming: true);
  }

  /// Accept incoming call -> checks permissions, sends call.accept, and initializes WebRTC.
  Future<void> acceptCall() async {
    if (state.activeCall == null) return;
    _cancelRingingTimeout();

    if (!_canTransitionTo(CallState.connecting)) return;

    final isVideo = state.activeCall!.callType == CallType.video;

    // 1. Verify permissions (camera + mic for video, mic only for audio)
    final bool hasPermission = isVideo
        ? await _checkVideoPermissions()
        : await _checkMicrophonePermission();
    if (!hasPermission) {
      rejectCall('permission_denied');
      return;
    }

    // 2. Send call.accept to the caller
    _signalingService.sendAccept(
      callId: state.activeCall!.callId,
      toUserId: state.activeCall!.callerId,
    );

    setConnecting();

    // 3. Initialize appropriate WebRTC engine on callee side
    try {
      _setupWebRTCCallbacks(isVideo: isVideo);
      if (isVideo) {
        await _webrtcService.initializeVideo();
      } else {
        await _webrtcService.initialize();
      }
    } catch (e) {
      debugPrint('❌ [CallNotifier] Error initializing WebRTC on accept: $e');
      setFailed('Failed to access microphone/camera. Please grant permissions and try again.');
    }
  }

  /// Reject call -> transitioning calling/ringing to rejected.
  void rejectCall([String? reason]) {
    if (state.activeCall == null) return;
    _cancelTimers();
    _webrtcService.cleanup();

    if (!_canTransitionTo(CallState.rejected)) return;

    _signalingService.sendReject(
      callId: state.activeCall!.callId,
      toUserId: state.activeCall!.callerId,
      reason: reason,
    );

    final updatedCall = state.activeCall!.copyWith(
      state: CallState.rejected,
      endedAt: DateTime.now(),
      endReason: CallEndReason.rejected,
    );

    state = state.copyWith(
      activeCall: updatedCall,
      callState: CallState.rejected,
    );

    _recordCallToHistory(updatedCall);
    _scheduleCleanup();
  }

  /// Set call state to connecting
  void setConnecting() {
    if (state.activeCall == null) return;
    if (state.callState == CallState.connecting) return;
    _cancelRingingTimeout();

    if (!_canTransitionTo(CallState.connecting)) return;

    final updatedCall = state.activeCall!.copyWith(state: CallState.connecting);
    state = state.copyWith(
      activeCall: updatedCall,
      callState: CallState.connecting,
    );
  }

  /// Set call state to connected and start duration counter
  void setConnected() {
    if (state.activeCall == null) return;
    _cancelRingingTimeout();

    if (!_canTransitionTo(CallState.connected)) return;

    final updatedCall = state.activeCall!.copyWith(
      state: CallState.connected,
      connectedAt: DateTime.now(),
    );

    state = state.copyWith(
      activeCall: updatedCall,
      callState: CallState.connected,
      durationSeconds: 0,
    );

    _startDurationTimer();
  }

  /// End active call locally -> sends call.end, releases hardware, cleans up WebRTC.
  void endCall([CallEndReason reason = CallEndReason.userEnded]) {
    _cancelTimers();
    _webrtcService.cleanup();

    if (state.activeCall == null) {
      state = state.copyWith(callState: CallState.idle, clearActiveCall: true);
      return;
    }

    if (!_canTransitionTo(CallState.ended)) {
      return;
    }

    final otherUserId = state.activeCall!.getPeerUid(
      _signalingService.currentUid ?? state.activeCall!.callerId,
    );

    _signalingService.sendEnd(
      callId: state.activeCall!.callId,
      toUserId: otherUserId,
    );

    final updatedCall = state.activeCall!.copyWith(
      state: CallState.ended,
      endedAt: DateTime.now(),
      duration: state.durationSeconds,
      endReason: reason,
    );

    state = state.copyWith(
      activeCall: updatedCall,
      callState: CallState.ended,
    );

    _recordCallToHistory(updatedCall);
    _scheduleCleanup();
  }

  /// Set call state to failed
  void setFailed(String message) {
    _cancelTimers();
    _webrtcService.cleanup();

    if (state.activeCall != null && _canTransitionTo(CallState.failed)) {
      final updatedCall = state.activeCall!.copyWith(
        state: CallState.failed,
        endedAt: DateTime.now(),
        endReason: CallEndReason.failed,
      );
      state = state.copyWith(
        activeCall: updatedCall,
        callState: CallState.failed,
        errorMessage: message,
      );
      _recordCallToHistory(updatedCall);
    } else {
      state = state.copyWith(callState: CallState.failed, errorMessage: message);
    }

    _scheduleCleanup();
  }

  /// Set call state to disconnected
  void setDisconnected() {
    _cancelTimers();
    _webrtcService.cleanup();

    if (state.activeCall != null && _canTransitionTo(CallState.disconnected)) {
      final updatedCall = state.activeCall!.copyWith(
        state: CallState.disconnected,
        endedAt: DateTime.now(),
        endReason: CallEndReason.disconnected,
      );
      state = state.copyWith(
        activeCall: updatedCall,
        callState: CallState.disconnected,
      );
      _recordCallToHistory(updatedCall);
    }

    _scheduleCleanup();
  }



  // ==========================================
  // TIMERS & INTERNAL HELPERS
  // ==========================================

  void _startRingingTimeout({required bool isIncoming}) {
    _ringingTimeoutTimer?.cancel();
    _ringingTimeoutTimer = Timer(ringingTimeoutDuration, () {
      if (!mounted) return;
      if (isIncoming && state.callState == CallState.ringing) {
        debugPrint('⏰ Incoming call ringing timeout: marking as missed');
        if (state.activeCall != null && _canTransitionTo(CallState.missed)) {
          final missedCall = state.activeCall!.copyWith(
            state: CallState.missed,
            endedAt: DateTime.now(),
            duration: 0,
            endReason: CallEndReason.missed,
          );
          state = state.copyWith(
            activeCall: missedCall,
            callState: CallState.missed,
          );
          _recordCallToHistory(missedCall);
          _scheduleCleanup();
        }
      } else if (!isIncoming && state.callState == CallState.calling) {
        debugPrint('⏰ Outgoing call timeout: marking as busy');
        if (state.activeCall != null && _canTransitionTo(CallState.busy)) {
          final busyCall = state.activeCall!.copyWith(
            state: CallState.busy,
            endedAt: DateTime.now(),
            duration: 0,
            endReason: CallEndReason.busy,
          );
          state = state.copyWith(
            activeCall: busyCall,
            callState: CallState.busy,
          );
          _recordCallToHistory(busyCall);
          _scheduleCleanup();
        }
      }
    });
  }

  void _cancelRingingTimeout() {
    _ringingTimeoutTimer?.cancel();
    _ringingTimeoutTimer = null;
  }

  void _startDurationTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        state = state.copyWith(durationSeconds: timer.tick);
      }
    });
  }

  void _recordCallToHistory(CallModel call) {
    if (_hasRecordedHistory) return;
    _hasRecordedHistory = true;
    final currentUid = _signalingService.currentUid ?? _ref.read(currentUserProvider)?.uid;
    _ref.read(callHistoryNotifierProvider.notifier).addCallRecord(call, userUid: currentUid);
  }

  void _scheduleCleanup() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) {
        state = ActiveCallState(callState: CallState.idle);
      }
    });
  }

  void _cancelTimers() {
    _durationTimer?.cancel();
    _durationTimer = null;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    _ringingTimeoutTimer?.cancel();
    _ringingTimeoutTimer = null;
  }

  @override
  void dispose() {
    _webrtcService.cleanup();
    _signalingSubscription?.cancel();
    _cancelTimers();
    super.dispose();
  }
}

final signalingServiceProvider = Provider<SignalingService>((ref) {
  return SignalingService();
});

final webRTCServiceProvider = Provider<WebRTCService>((ref) {
  return WebRTCService();
});

final callProvider = StateNotifierProvider<CallNotifier, ActiveCallState>((ref) {
  return CallNotifier(ref);
});

/// StreamProvider exposing the live WebSocket signaling connection state
final signalingConnectionStateProvider = StreamProvider<SignalingConnectionState>((ref) {
  final service = ref.watch(signalingServiceProvider);
  return service.connectionStateStream;
});
