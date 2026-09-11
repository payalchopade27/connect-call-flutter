import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:connect_call/core/constants/app_constants.dart';
import 'package:connect_call/models/call_model.dart';
import 'package:connect_call/models/user_model.dart';
import 'package:connect_call/providers/call_provider.dart';
import 'package:connect_call/providers/history_provider.dart';

void main() {
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

  group('CallNotifier State Machine & Controls', () {
    late ProviderContainer container;
    final userMe = UserModel(uid: 'my_uid', name: 'Me', email: 'me@test.com');
    final userPeer = UserModel(uid: 'peer_uid', name: 'Peer User', email: 'peer@test.com');

    setUp(() {
      container = ProviderContainer();
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

    test('startOutgoingCall sets state to calling and speaker defaults', () {
      container.read(callProvider.notifier).startOutgoingCall(
        targetUser: userPeer,
        callType: CallType.video,
        currentUser: userMe,
      );

      final state = container.read(callProvider);
      expect(state.callState, CallState.calling);
      expect(state.activeCall, isNotNull);
      expect(state.activeCall!.callerId, 'my_uid');
      expect(state.activeCall!.receiverId, 'peer_uid');
      expect(state.activeCall!.getPeerName('my_uid'), 'Peer User');
      // Video call defaults speaker to true
      expect(state.isSpeakerOn, isTrue);
      expect(state.isMuted, isFalse);
    });

    test('Local controls toggle state without hardware calls', () {
      final notifier = container.read(callProvider.notifier);

      notifier.toggleMute();
      expect(container.read(callProvider).isMuted, isTrue);
      notifier.toggleMute();
      expect(container.read(callProvider).isMuted, isFalse);

      notifier.toggleSpeaker();
      expect(container.read(callProvider).isSpeakerOn, isTrue);

      notifier.toggleVideo();
      expect(container.read(callProvider).isVideoMuted, isTrue);

      notifier.switchCamera();
      expect(container.read(callProvider).isFrontCamera, isFalse);
    });

    test('Outgoing call transition: calling -> connecting -> connected -> ended', () {
      final notifier = container.read(callProvider.notifier);

      notifier.startOutgoingCall(
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

      notifier.acceptCall();
      expect(container.read(callProvider).callState, CallState.connecting);

      // Wait for simulated accept delay
      await Future.delayed(const Duration(milliseconds: 700));
      expect(container.read(callProvider).callState, CallState.connected);

      notifier.endCall();
      expect(container.read(callProvider).callState, CallState.ended);
    });

    test('Incoming call rejection transitions to rejected and records history', () {
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

      final updatedHistory = container.read(callHistoryProvider);
      expect(updatedHistory.length, initialHistoryCount + 1);
      expect(updatedHistory.first.state, CallState.rejected);
      expect(updatedHistory.first.getPeerName('my_uid'), 'Peer User');
    });

    test('Completed call is recorded into call history', () {
      final initialHistoryCount = container.read(callHistoryProvider).length;
      final notifier = container.read(callProvider.notifier);

      notifier.startOutgoingCall(
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
    });
  });
}
