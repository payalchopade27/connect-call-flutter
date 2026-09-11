import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect_call/core/constants/app_constants.dart';
import 'package:connect_call/models/call_model.dart';
import 'package:connect_call/models/user_model.dart';
import 'package:connect_call/providers/call_provider.dart';
import 'package:connect_call/providers/history_provider.dart';
import 'package:connect_call/services/webrtc_service.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class FakeWebRTCService extends WebRTCService {
  bool isInitialized = false;
  bool isCleanedUp = false;
  bool isMuted = false;
  bool isSpeakerOn = false;
  String? generatedOfferSdp = 'v=0\r\no=fakeOffer...';
  String? generatedAnswerSdp = 'v=0\r\no=fakeAnswer...';
  String? lastRemoteAnswer;
  String? lastRemoteOffer;
  final List<dynamic> remoteCandidates = [];

  @override
  Future<void> initialize({Map<String, dynamic>? iceServers}) async {
    isInitialized = true;
  }

  @override
  Future<String> createOffer() async {
    return generatedOfferSdp!;
  }

  @override
  Future<String> handleOfferAndCreateAnswer(String remoteOfferSdp) async {
    lastRemoteOffer = remoteOfferSdp;
    return generatedAnswerSdp!;
  }

  @override
  Future<void> handleRemoteAnswer(String remoteAnswerSdp) async {
    lastRemoteAnswer = remoteAnswerSdp;
  }

  @override
  Future<void> addRemoteIceCandidate({
    required dynamic candidateData,
    String? sdpMid,
    int? sdpMLineIndex,
  }) async {
    remoteCandidates.add({
      'candidate': candidateData,
      'sdpMid': sdpMid,
      'sdpMLineIndex': sdpMLineIndex,
    });
  }

  @override
  void setMicrophoneMute(bool muted) {
    isMuted = muted;
  }

  @override
  void enableSpeakerphone(bool enable) {
    isSpeakerOn = enable;
  }

  @override
  Future<void> cleanup() async {
    isCleanedUp = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CallModel Peer Identification & State Helpers', () {
    final call = CallModel(
      callId: 'test_call_123',
      callerId: 'uid_alice',
      receiverId: 'uid_bob',
      callerName: 'Alice',
      receiverName: 'Bob',
      callType: CallType.audio,
      state: CallState.calling,
      direction: CallDirection.outgoing,
      startedAt: DateTime.now(),
    );

    test('getPeerUid returns other participant UID', () {
      expect(call.getPeerUid('uid_alice'), 'uid_bob');
      expect(call.getPeerUid('uid_bob'), 'uid_alice');
      expect(call.getPeerUid('other_uid'), 'uid_alice');
    });

    test('getPeerName returns other participant Name', () {
      expect(call.getPeerName('uid_alice'), 'Bob');
      expect(call.getPeerName('uid_bob'), 'Alice');
    });

    test('isActive and isEnded flags behave correctly', () {
      expect(call.isActive, isTrue);
      expect(call.isEnded, isFalse);

      final endedCall = call.copyWith(state: CallState.ended);
      expect(endedCall.isActive, isFalse);
      expect(endedCall.isEnded, isTrue);

      final missedCall = call.copyWith(state: CallState.missed);
      expect(missedCall.isActive, isFalse);
      expect(missedCall.isEnded, isTrue);
    });
  });

  group('CallNotifier WebRTC Audio State Machine & Controls', () {
    late ProviderContainer container;
    late FakeWebRTCService fakeWebRTC;
    final userMe = UserModel(uid: 'my_uid', name: 'Me', email: 'me@test.com');
    final userPeer = UserModel(uid: 'peer_uid', name: 'Peer User', email: 'peer@test.com');

    setUp(() {
      fakeWebRTC = FakeWebRTCService();
      container = ProviderContainer(
        overrides: [
          webRTCServiceProvider.overrideWithValue(fakeWebRTC),
        ],
      );
    });

    tearDown(() {
      container.dispose();
    });

    test('Initial state is idle with sensible control defaults', () {
      final state = container.read(callProvider);
      expect(state.callState, CallState.idle);
      expect(state.activeCall, isNull);
      expect(state.isMuted, isFalse);
      expect(state.isSpeakerOn, isFalse);
      expect(state.isVideoMuted, isFalse);
      expect(state.isFrontCamera, isTrue);
    });

    test('startOutgoingCall sets state to calling and speaker defaults', () async {
      await container.read(callProvider.notifier).startOutgoingCall(
        targetUser: userPeer,
        callType: CallType.audio,
        currentUser: userMe,
      );

      final state = container.read(callProvider);
      expect(state.callState, CallState.calling);
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.callerId, 'my_uid');
      expect(state.activeCall!.receiverId, 'peer_uid');
      expect(state.activeCall!.getPeerName('my_uid'), 'Peer User');
      // Audio call defaults speaker to false
      expect(state.isSpeakerOn, isFalse);
      expect(state.isMuted, isFalse);
    });

    test('toggleMute updates state and calls WebRTCService.setMicrophoneMute', () {
      final notifier = container.read(callProvider.notifier);

      notifier.toggleMute();
      expect(container.read(callProvider).isMuted, isTrue);
      expect(fakeWebRTC.isMuted, isTrue);

      notifier.toggleMute();
      expect(container.read(callProvider).isMuted, isFalse);
      expect(fakeWebRTC.isMuted, isFalse);
    });

    test('toggleSpeaker updates state and calls WebRTCService.enableSpeakerphone', () {
      final notifier = container.read(callProvider.notifier);

      notifier.toggleSpeaker();
      expect(container.read(callProvider).isSpeakerOn, isTrue);
      expect(fakeWebRTC.isSpeakerOn, isTrue);

      notifier.toggleSpeaker();
      expect(container.read(callProvider).isSpeakerOn, isFalse);
      expect(fakeWebRTC.isSpeakerOn, isFalse);
    });

    test('Outgoing call transition: calling -> connecting -> connected -> ended triggers WebRTC cleanup', () async {
      final notifier = container.read(callProvider.notifier);

      await notifier.startOutgoingCall(
        targetUser: userPeer,
        callType: CallType.audio,
        currentUser: userMe,
      );
      expect(container.read(callProvider).callState, CallState.calling);

      notifier.setConnecting();
      expect(container.read(callProvider).callState, CallState.connecting);

      notifier.setConnected();
      expect(container.read(callProvider).callState, CallState.connected);

      notifier.endCall();
      expect(container.read(callProvider).callState, CallState.ended);
      expect(fakeWebRTC.isCleanedUp, isTrue);
    });

    test('Incoming call simulation: ringing -> accept -> connecting -> connected', () async {
      final notifier = container.read(callProvider.notifier);

      notifier.receiveIncomingCall(
        caller: userPeer,
        callType: CallType.audio,
        currentUid: userMe.uid,
        currentName: userMe.name,
      );

      final ringingState = container.read(callProvider);
      expect(ringingState.callState, CallState.ringing);
      expect(ringingState.activeCall!.getPeerName('my_uid'), 'Peer User');

      await notifier.acceptCall();
      expect(container.read(callProvider).callState, CallState.connecting);
      expect(fakeWebRTC.isInitialized, isTrue);

      // Simulate WebRTC connection established callback
      fakeWebRTC.onConnectionStateChange?.call(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      expect(container.read(callProvider).callState, CallState.connected);

      notifier.endCall();
      expect(container.read(callProvider).callState, CallState.ended);
      expect(fakeWebRTC.isCleanedUp, isTrue);
    });

    test('Incoming call rejection transitions to rejected, records history, and cleans up WebRTC', () {
      final initialHistoryCount = container.read(callHistoryProvider).length;
      final notifier = container.read(callProvider.notifier);

      notifier.receiveIncomingCall(
        caller: userPeer,
        callType: CallType.audio,
        currentUid: userMe.uid,
        currentName: userMe.name,
      );

      notifier.rejectCall();
      expect(container.read(callProvider).callState, CallState.rejected);
      expect(fakeWebRTC.isCleanedUp, isTrue);

      final updatedHistory = container.read(callHistoryProvider);
      expect(updatedHistory.length, initialHistoryCount + 1);
      expect(updatedHistory.first.state, CallState.rejected);
      expect(updatedHistory.first.getPeerName('my_uid'), 'Peer User');
    });

    test('Completed call is recorded into call history and cleans up WebRTC', () async {
      final initialHistoryCount = container.read(callHistoryProvider).length;
      final notifier = container.read(callProvider.notifier);

      await notifier.startOutgoingCall(
        targetUser: userPeer,
        callType: CallType.audio,
        currentUser: userMe,
      );
      notifier.setConnected();
      notifier.endCall();

      final updatedHistory = container.read(callHistoryProvider);
      expect(updatedHistory.length, initialHistoryCount + 1);
      expect(updatedHistory.first.state, CallState.ended);
      expect(updatedHistory.first.getPeerName('my_uid'), 'Peer User');
      expect(fakeWebRTC.isCleanedUp, isTrue);
    });
  });
}
