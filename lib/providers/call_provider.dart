import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../core/constants/app_constants.dart';
import '../models/call_model.dart';
import '../models/signaling_message.dart';
import '../models/user_model.dart';
import '../services/signaling_service.dart';
import '../services/webrtc_service.dart';
import 'auth_provider.dart';
import 'history_provider.dart';

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
  Timer? _durationTimer;
  Timer? _cleanupTimer;
  Timer? _ringingTimeoutTimer;
  StreamSubscription<SignalingMessage>? _signalingSubscription;
  bool _hasRecordedHistory = false;

  CallNotifier(this._ref) : super(ActiveCallState()) {
    _listenToSignaling();
  }

  SignalingService get _signalingService => _ref.read(signalingServiceProvider);

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

  /// Connect the WebSocket signaling service using current authenticated Firebase credentials.
  /// Auth token is sent as the first WebSocket message per the frozen contract.
  Future<void> connectSignaling({String? customUrl, String? token, String? uid}) async {
    try {
      final user = _ref.read(currentUserProvider);
      final effectiveUid = uid ?? user?.uid;
      if (effectiveUid == null || effectiveUid.isEmpty) {
        debugPrint('ℹ️ [CallNotifier] Cannot connect signaling: no user UID available.');
        return;
      }

      final effectiveToken = token ?? (user != null ? await user.getIdToken() : null) ?? '';
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
  /// Auth messages are handled internally by SignalingService and do not reach here.
  void _listenToSignaling() {
    _signalingSubscription?.cancel();
    _signalingSubscription = _signalingService.messageStream.listen(
      _handleIncomingSignalingMessage,
      onError: (err) {
        debugPrint('⚠️ [CallNotifier] Signaling stream error: $err');
      },
    );
  }

  /// Process inbound signaling messages (only call-related, auth is handled by service)
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

      case SignalingMessageType.peerDisconnected:
        _handleInboundPeerDisconnected(message);
        break;

      case SignalingMessageType.callError:
        _handleInboundError(message);
        break;

      default:
        debugPrint('ℹ️ [CallNotifier] Unhandled or future signaling message type: ${message.type}');
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
      callerName: callerUid, // Will be resolved via UserService if needed
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
  }

  void _handleInboundAccept(SignalingMessage message) {
    if (state.activeCall == null || state.activeCall!.callId != message.callId) {
      debugPrint('⚠️ [CallNotifier] Received accept for non-matching callId: ${message.callId}');
      return;
    }

    if (state.callState == CallState.calling || state.callState == CallState.connecting) {
      _cancelRingingTimeout();
      setConnecting();
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted && state.callState == CallState.connecting) {
          setConnected();
        }
      });
    }
  }

  void _handleInboundReject(SignalingMessage message) {
    if (state.activeCall == null || state.activeCall!.callId != message.callId) return;

    _cancelTimers();

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
    setDisconnected();
  }

  void _handleInboundError(SignalingMessage message) {
    final errorMsg = message.errorMessage ?? 'Call signaling error';
    debugPrint('❌ [CallNotifier] Call error received: $errorMsg');
    setFailed(errorMsg);
  }

  // ==========================================
  // LOCAL CALL CONTROLS (Riverpod state only)
  // ==========================================

  void toggleMute() {
    state = state.copyWith(isMuted: !state.isMuted);
  }

  void toggleSpeaker() {
    state = state.copyWith(isSpeakerOn: !state.isSpeakerOn);
  }

  void toggleVideo() {
    state = state.copyWith(isVideoMuted: !state.isVideoMuted);
  }

  void switchCamera() {
    state = state.copyWith(isFrontCamera: !state.isFrontCamera);
  }

  // ==========================================
  // CALL FLOW LIFECYCLE
  // ==========================================

  /// Initiate an outgoing call.
  /// Sends call.invite with toUserId and callType in payload (no callerId per contract).
  void startOutgoingCall({
    required UserModel targetUser,
    required CallType callType,
    required UserModel currentUser,
  }) {
    _cancelTimers();
    _hasRecordedHistory = false;

    if (!_canTransitionTo(CallState.calling)) {
      // If previous call cleanup was still running, reset to idle first
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

    // Send call.invite per frozen contract — no callerId, backend derives sender
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

  /// Accept incoming call -> transitioning ringing to connecting -> connected.
  /// Sends call.accept to the caller's UID (toUserId = callerId of the incoming call).
  void acceptCall() {
    if (state.activeCall == null) return;
    _cancelRingingTimeout();

    if (!_canTransitionTo(CallState.connecting)) return;

    // Per frozen contract: toUserId = the caller (the other party)
    _signalingService.sendAccept(
      callId: state.activeCall!.callId,
      toUserId: state.activeCall!.callerId,
    );

    setConnecting();

    // Short delay simulating connection setup
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted && state.callState == CallState.connecting) {
        setConnected();
      }
    });
  }

  /// Reject call -> transitioning calling/ringing to rejected.
  /// Sends call.reject to the other party.
  void rejectCall([String? reason]) {
    if (state.activeCall == null) return;
    _cancelTimers();

    if (!_canTransitionTo(CallState.rejected)) return;

    // Per frozen contract: toUserId = the other party
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

  /// End active call locally.
  /// Sends call.end to the other party per frozen contract.
  void endCall([CallEndReason reason = CallEndReason.userEnded]) {
    _cancelTimers();

    if (state.activeCall == null) {
      state = state.copyWith(callState: CallState.idle, clearActiveCall: true);
      return;
    }

    if (!_canTransitionTo(CallState.ended)) {
      return;
    }

    // Per frozen contract: toUserId = the other party's UID
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

  /// Dev simulation helper: simulate peer accepting an outgoing call
  void simulatePeerAccept() {
    if (state.callState == CallState.calling || state.callState == CallState.ringing) {
      setConnecting();
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted && state.callState == CallState.connecting) {
          setConnected();
        }
      });
    }
  }

  /// Dev simulation helper: simulate peer rejecting an outgoing call
  void simulatePeerReject() {
    if (state.callState == CallState.calling || state.callState == CallState.ringing) {
      rejectCall();
    }
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
    _ref.read(callHistoryNotifierProvider.notifier).addCallRecord(call);
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
