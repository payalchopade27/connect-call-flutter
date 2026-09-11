import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:connect_call/core/constants/app_constants.dart';
import 'package:connect_call/models/signaling_message.dart';
import 'package:connect_call/models/user_model.dart';
import 'package:connect_call/providers/call_provider.dart';
import 'package:connect_call/services/signaling_service.dart';
import 'package:connect_call/services/webrtc_service.dart';

class MockWebSocketSink implements WebSocketSink {
  final List<dynamic> sentMessages = [];
  bool isClosed = false;

  @override
  void add(dynamic data) {
    sentMessages.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) async {
    await for (final data in stream) {
      sentMessages.add(data);
    }
  }

  @override
  Future close([int? closeCode, String? closeReason]) async {
    isClosed = true;
  }

  @override
  Future get done => Future.value();
}

class MockWebSocketChannel extends StreamChannelMixin implements WebSocketChannel {
  final StreamController _inController = StreamController.broadcast();
  final MockWebSocketSink _outSink = MockWebSocketSink();

  @override
  Stream get stream => _inController.stream;

  @override
  WebSocketSink get sink => _outSink;

  void emitFromServer(dynamic data) {
    _inController.add(data);
  }

  void closeChannel() {
    _inController.close();
  }

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  String? get protocol => null;

  @override
  Future<void> get ready => Future.value();
}

class FakeWebRTCService extends WebRTCService {
  bool isInitialized = false;
  bool isCleanedUp = false;
  bool isMuted = false;
  bool isSpeakerOn = false;
  bool isVideoMuted = false;
  bool isCameraFront = true;
  String? generatedOfferSdp = 'v=0\r\no=testOffer...';
  String? generatedAnswerSdp = 'v=0\r\no=testAnswer...';
  String? lastRemoteAnswer;
  String? lastRemoteOffer;
  final List<dynamic> remoteCandidates = [];

  @override
  Future<void> initialize({Map<String, dynamic>? iceServers}) async {
    isInitialized = true;
  }

  @override
  Future<void> initializeVideo({Map<String, dynamic>? iceServers}) async {
    isInitialized = true;
  }

  @override
  Future<String> createOffer({bool isVideo = false}) async {
    return generatedOfferSdp!;
  }

  @override
  Future<String> handleOfferAndCreateAnswer(String remoteOfferSdp, {bool isVideo = false}) async {
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
  void setVideoMute(bool muted) {
    isVideoMuted = muted;
  }

  @override
  Future<void> switchCamera() async {
    isCameraFront = !isCameraFront;
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

/// Helper: Simulate the backend sending auth.success after Flutter sends auth
void simulateAuthSuccess(MockWebSocketChannel channel, {String userId = 'test-uid'}) {
  channel.emitFromServer(jsonEncode({
    'type': 'auth.success',
    'userId': userId,
  }));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SignalingMessage Model & Contract Serialization', () {
    test('Serializes auth message with token at top level per contract', () {
      final msg = SignalingMessage.auth('firebase-id-token-abc');
      final jsonStr = msg.toJson();
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;

      expect(map['type'], 'auth');
      expect(map['token'], 'firebase-id-token-abc');
      expect(map.containsKey('callId'), isFalse);
      expect(map.containsKey('toUserId'), isFalse);
      expect(map.containsKey('payload'), isFalse);
    });

    test('Serializes call.invite per frozen contract (no callerId, with payload)', () {
      final msg = SignalingMessage.invite(
        callId: 'call-xyz-123',
        toUserId: 'uid-bob',
        callType: CallType.audio,
      );

      final jsonStr = msg.toJson();
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;

      expect(map['type'], 'call.invite');
      expect(map['callId'], 'call-xyz-123');
      expect(map['toUserId'], 'uid-bob');
      expect(map['payload'], isA<Map<String, dynamic>>());
      expect(map['payload']['callType'], 'audio');
      expect(map.containsKey('callerId'), isFalse);
      expect(map.containsKey('fromUserId'), isFalse);
    });

    test('Serializes call.accept per frozen contract (with empty payload map)', () {
      final msg = SignalingMessage.accept(
        callId: 'call-acc-1',
        toUserId: 'caller-uid',
      );

      final map = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(map['type'], 'call.accept');
      expect(map['callId'], 'call-acc-1');
      expect(map['toUserId'], 'caller-uid');
      expect(map['payload'], isA<Map<String, dynamic>>());
      expect(map['payload'], isEmpty);
      expect(map.containsKey('callerId'), isFalse);
    });

    test('Serializes call.reject with reason in payload', () {
      final msg = SignalingMessage.reject(
        callId: 'call-xyz-123',
        toUserId: 'uid-bob',
        reason: 'busy',
      );

      final map = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(map['type'], 'call.reject');
      expect(map['callId'], 'call-xyz-123');
      expect(map['toUserId'], 'uid-bob');
      expect(map['payload']['reason'], 'busy');
      expect(map.containsKey('callerId'), isFalse);
    });

    test('Serializes call.end per frozen contract (with empty payload map)', () {
      final msg = SignalingMessage.end(
        callId: 'call-1',
        toUserId: 'uid-2',
      );

      final map = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(map['type'], 'call.end');
      expect(map['callId'], 'call-1');
      expect(map['toUserId'], 'uid-2');
      expect(map['payload'], isA<Map<String, dynamic>>());
      expect(map['payload'], isEmpty);
      expect(map.containsKey('callerId'), isFalse);
    });

    test('Parses incoming call.invite with fromUserId from backend', () {
      final jsonMap = {
        'type': SignalingMessageType.callInvite,
        'callId': 'call-xyz-123',
        'fromUserId': 'uid-alice',
        'toUserId': 'uid-bob',
        'payload': {'callType': 'audio'},
      };

      final parsed = SignalingMessage.fromMap(jsonMap);
      expect(parsed.type, SignalingMessageType.callInvite);
      expect(parsed.fromUserId, 'uid-alice');
      expect(parsed.toUserId, 'uid-bob');
      expect(parsed.callType, CallType.audio);
    });

    test('Serializes and parses webrtc.offer envelope per contract', () {
      final msg = SignalingMessage.offer(
        callId: 'call-sdp-1',
        toUserId: 'peer-uid',
        sdp: 'v=0\r\no=offer...',
      );

      final map = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(map['type'], 'webrtc.offer');
      expect(map['callId'], 'call-sdp-1');
      expect(map['toUserId'], 'peer-uid');
      expect(map['payload']['sdp'], 'v=0\r\no=offer...');
      expect(map.containsKey('callerId'), isFalse);

      final parsed = SignalingMessage.fromJson(msg.toJson());
      expect(parsed.sdp, 'v=0\r\no=offer...');
    });

    test('Serializes and parses webrtc.answer envelope per contract', () {
      final msg = SignalingMessage.answer(
        callId: 'call-sdp-2',
        toUserId: 'peer-uid',
        sdp: 'v=0\r\no=answer...',
      );

      final map = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(map['type'], 'webrtc.answer');
      expect(map['payload']['sdp'], 'v=0\r\no=answer...');

      final parsed = SignalingMessage.fromJson(msg.toJson());
      expect(parsed.sdp, 'v=0\r\no=answer...');
    });

    test('Serializes and parses webrtc.ice envelope per contract', () {
      final msg = SignalingMessage.ice(
        callId: 'call-ice-1',
        toUserId: 'peer-uid',
        candidate: {'candidate': 'candidate:...'},
        sdpMid: '0',
        sdpMLineIndex: 0,
      );

      final map = jsonDecode(msg.toJson()) as Map<String, dynamic>;
      expect(map['type'], 'webrtc.ice');
      expect(map['payload']['candidate'], isA<Map>());
      expect(map['payload']['sdpMid'], '0');
      expect(map['payload']['sdpMLineIndex'], 0);

      final parsed = SignalingMessage.fromJson(msg.toJson());
      expect(parsed.candidate, isNotNull);
      expect(parsed.sdpMid, '0');
      expect(parsed.sdpMLineIndex, 0);
    });
  });

  group('SignalingService WebSocket + Auth Handshake', () {
    late SignalingService service;
    late MockWebSocketChannel mockChannel;

    setUp(() {
      service = SignalingService();
      mockChannel = MockWebSocketChannel();
    });

    tearDown(() {
      service.dispose();
      mockChannel.closeChannel();
    });

    test('Connects and sends auth message as first message', () async {
      expect(service.connectionState, SignalingConnectionState.disconnected);

      await service.connect(
        signalingUrl: 'ws://test.com/ws/signaling',
        idToken: 'mock-firebase-token',
        uid: 'user-123',
        customChannel: mockChannel,
      );

      expect(service.connectionState, SignalingConnectionState.authenticating);

      expect(mockChannel._outSink.sentMessages.length, 1);
      final authMsg = jsonDecode(mockChannel._outSink.sentMessages.first);
      expect(authMsg['type'], 'auth');
      expect(authMsg['token'], 'mock-firebase-token');
    });

    test('Transitions to authenticated after auth.success and stores userId', () async {
      await service.connect(
        signalingUrl: 'ws://test.com/ws/signaling',
        idToken: 'mock-token',
        uid: 'user-123',
        customChannel: mockChannel,
      );

      simulateAuthSuccess(mockChannel, userId: 'verified-uid-456');
      await Future.delayed(const Duration(milliseconds: 50));

      expect(service.connectionState, SignalingConnectionState.authenticated);
      expect(service.isAuthenticated, isTrue);
      expect(service.isConnected, isTrue);
      expect(service.currentUid, 'verified-uid-456');
    });

    test('Handles auth.error and transitions to error state', () async {
      await service.connect(
        signalingUrl: 'ws://test.com/ws/signaling',
        idToken: 'bad-token',
        uid: 'user-123',
        customChannel: mockChannel,
      );

      mockChannel.emitFromServer(jsonEncode({
        'type': 'auth.error',
        'code': 'AUTH_INVALID',
        'message': 'Authentication failed',
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(service.connectionState, SignalingConnectionState.error);
      expect(service.isAuthenticated, isFalse);
    });

    test('Times out and enters error state if auth.success is not received within timeout', () async {
      final timeoutService = SignalingService(
        authTimeoutDuration: const Duration(milliseconds: 50),
      );
      final timeoutChannel = MockWebSocketChannel();

      await timeoutService.connect(
        signalingUrl: 'ws://test.com/ws/signaling',
        idToken: 'mock-token',
        uid: 'user-123',
        customChannel: timeoutChannel,
      );

      expect(timeoutService.connectionState, SignalingConnectionState.authenticating);

      await Future.delayed(const Duration(milliseconds: 80));

      expect(timeoutService.connectionState, SignalingConnectionState.error);
      expect(timeoutService.isAuthenticated, isFalse);

      timeoutService.dispose();
      timeoutChannel.closeChannel();
    });

    test('Blocks call messages before authentication', () async {
      await service.connect(
        signalingUrl: 'ws://test.com/ws/signaling',
        idToken: 'mock-token',
        uid: 'user-123',
        customChannel: mockChannel,
      );

      service.sendInvite(
        callId: 'call-1',
        toUserId: 'user-2',
        callType: CallType.audio,
      );

      expect(mockChannel._outSink.sentMessages.length, 1);
      final onlyMsg = jsonDecode(mockChannel._outSink.sentMessages.first);
      expect(onlyMsg['type'], 'auth');
    });

    test('Allows call messages after authentication', () async {
      await service.connect(
        signalingUrl: 'ws://test.com/ws/signaling',
        idToken: 'mock-token',
        uid: 'user-123',
        customChannel: mockChannel,
      );

      simulateAuthSuccess(mockChannel, userId: 'user-123');
      await Future.delayed(const Duration(milliseconds: 50));

      service.sendInvite(
        callId: 'call-99',
        toUserId: 'user-peer',
        callType: CallType.audio,
      );

      expect(mockChannel._outSink.sentMessages.length, 2);
      final sentInvite = jsonDecode(mockChannel._outSink.sentMessages[1]);
      expect(sentInvite['type'], 'call.invite');
      expect(sentInvite['callId'], 'call-99');
      expect(sentInvite['toUserId'], 'user-peer');
      expect(sentInvite['payload']['callType'], 'audio');
      expect(sentInvite.containsKey('callerId'), isFalse);
    });

    test('Safely ignores malformed JSON without crashing', () async {
      await service.connect(
        signalingUrl: 'ws://test.com/ws/signaling',
        idToken: 'mock-token',
        uid: 'user-123',
        customChannel: mockChannel,
      );

      simulateAuthSuccess(mockChannel, userId: 'user-123');
      await Future.delayed(const Duration(milliseconds: 50));

      mockChannel.emitFromServer('{not_valid_json');

      expect(service.isAuthenticated, isTrue);
    });

    test('Safely ignores unknown message types without crashing or state corruption', () async {
      await service.connect(
        signalingUrl: 'ws://test.com/ws/signaling',
        idToken: 'mock-token',
        uid: 'user-123',
        customChannel: mockChannel,
      );

      simulateAuthSuccess(mockChannel, userId: 'user-123');
      await Future.delayed(const Duration(milliseconds: 50));

      mockChannel.emitFromServer(jsonEncode({
        'type': 'custom.unknown.type',
        'foo': 'bar',
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(service.isAuthenticated, isTrue);
    });

    test('Disconnect resets state completely', () async {
      await service.connect(
        signalingUrl: 'ws://test.com/ws/signaling',
        idToken: 'mock-token',
        uid: 'user-123',
        customChannel: mockChannel,
      );

      simulateAuthSuccess(mockChannel, userId: 'user-123');
      await Future.delayed(const Duration(milliseconds: 50));

      service.disconnect();
      expect(service.connectionState, SignalingConnectionState.disconnected);
      expect(service.isAuthenticated, isFalse);
      expect(service.isConnected, isFalse);
    });
  });

  group('CallProvider + SignalingService + WebRTC Integration', () {
    late ProviderContainer container;
    late SignalingService signaling;
    late MockWebSocketChannel mockChannel;
    late FakeWebRTCService fakeWebRTC;

    setUp(() async {
      signaling = SignalingService();
      mockChannel = MockWebSocketChannel();
      fakeWebRTC = FakeWebRTCService();

      await signaling.connect(
        signalingUrl: 'ws://test.com/ws/signaling',
        idToken: 'mock-token',
        uid: 'my-uid',
        customChannel: mockChannel,
      );

      simulateAuthSuccess(mockChannel, userId: 'my-uid');
      await Future.delayed(const Duration(milliseconds: 50));

      container = ProviderContainer(
        overrides: [
          signalingServiceProvider.overrideWithValue(signaling),
          webRTCServiceProvider.overrideWithValue(fakeWebRTC),
        ],
      );
    });

    tearDown(() {
      container.dispose();
      signaling.dispose();
      mockChannel.closeChannel();
    });

    test('Inbound call.invite transitions CallNotifier to ringing', () async {
      expect(container.read(callProvider).callState, CallState.idle);

      mockChannel.emitFromServer(jsonEncode({
        'type': 'call.invite',
        'callId': 'call-101',
        'fromUserId': 'caller-uid',
        'toUserId': 'my-uid',
        'payload': {'callType': 'audio'},
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(callProvider);
      expect(state.callState, CallState.ringing);
      expect(state.activeCall?.callId, 'call-101');
      expect(state.activeCall?.callerId, 'caller-uid');
      expect(state.activeCall?.direction, CallDirection.incoming);
    });

    test('Inbound call.accept initiates WebRTC offer sending', () async {
      final userPeer = UserModel(uid: 'user-peer', name: 'Peer', email: 'peer@test.com');
      final userMe = UserModel(uid: 'my-uid', name: 'Me', email: 'me@test.com');

      await container.read(callProvider.notifier).startOutgoingCall(
        targetUser: userPeer,
        callType: CallType.audio,
        currentUser: userMe,
      );

      final callId = container.read(callProvider).activeCall!.callId;

      // Peer accepts call
      mockChannel.emitFromServer(jsonEncode({
        'type': 'call.accept',
        'callId': callId,
        'fromUserId': 'user-peer',
        'toUserId': 'my-uid',
        'payload': {},
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(container.read(callProvider).callState, CallState.connecting);
      expect(fakeWebRTC.isInitialized, isTrue);

      // Verify webrtc.offer was sent
      final sentMsgs = mockChannel._outSink.sentMessages;
      final offerMsg = sentMsgs.map((m) => jsonDecode(m)).firstWhere(
            (m) => m['type'] == 'webrtc.offer' && m['callId'] == callId,
            orElse: () => null,
          );

      expect(offerMsg, isNotNull);
      expect(offerMsg['toUserId'], 'user-peer');
      expect(offerMsg['payload']['sdp'], 'v=0\r\no=testOffer...');
      expect(offerMsg.containsKey('callerId'), isFalse);
    });

    test('Inbound webrtc.offer generates and sends webrtc.answer', () async {
      // Ensure CallNotifier is instantiated and subscribed to signaling stream
      final notifier = container.read(callProvider.notifier);

      // Simulate incoming call
      mockChannel.emitFromServer(jsonEncode({
        'type': 'call.invite',
        'callId': 'call-102',
        'fromUserId': 'caller-uid',
        'toUserId': 'my-uid',
        'payload': {'callType': 'audio'},
      }));

      await Future.delayed(const Duration(milliseconds: 50));
      await notifier.acceptCall();

      // Inbound webrtc.offer
      mockChannel.emitFromServer(jsonEncode({
        'type': 'webrtc.offer',
        'callId': 'call-102',
        'fromUserId': 'caller-uid',
        'toUserId': 'my-uid',
        'payload': {'sdp': 'v=0\r\no=remoteOffer...'},
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(fakeWebRTC.lastRemoteOffer, 'v=0\r\no=remoteOffer...');

      // Verify webrtc.answer was sent
      final sentMsgs = mockChannel._outSink.sentMessages;
      final answerMsg = sentMsgs.map((m) => jsonDecode(m)).firstWhere(
            (m) => m['type'] == 'webrtc.answer' && m['callId'] == 'call-102',
            orElse: () => null,
          );

      expect(answerMsg, isNotNull);
      expect(answerMsg['toUserId'], 'caller-uid');
      expect(answerMsg['payload']['sdp'], 'v=0\r\no=testAnswer...');
    });

    test('Inbound webrtc.answer sets remote answer on WebRTCService', () async {
      final userPeer = UserModel(uid: 'user-peer', name: 'Peer', email: 'peer@test.com');
      final userMe = UserModel(uid: 'my-uid', name: 'Me', email: 'me@test.com');

      await container.read(callProvider.notifier).startOutgoingCall(
        targetUser: userPeer,
        callType: CallType.audio,
        currentUser: userMe,
      );

      final callId = container.read(callProvider).activeCall!.callId;

      mockChannel.emitFromServer(jsonEncode({
        'type': 'webrtc.answer',
        'callId': callId,
        'fromUserId': 'user-peer',
        'toUserId': 'my-uid',
        'payload': {'sdp': 'v=0\r\no=remoteAnswer...'},
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(fakeWebRTC.lastRemoteAnswer, 'v=0\r\no=remoteAnswer...');
    });

    test('Inbound webrtc.ice passes candidate to WebRTCService', () async {
      final userPeer = UserModel(uid: 'user-peer', name: 'Peer', email: 'peer@test.com');
      final userMe = UserModel(uid: 'my-uid', name: 'Me', email: 'me@test.com');

      await container.read(callProvider.notifier).startOutgoingCall(
        targetUser: userPeer,
        callType: CallType.audio,
        currentUser: userMe,
      );

      final callId = container.read(callProvider).activeCall!.callId;

      mockChannel.emitFromServer(jsonEncode({
        'type': 'webrtc.ice',
        'callId': callId,
        'fromUserId': 'user-peer',
        'toUserId': 'my-uid',
        'payload': {
          'candidate': {'candidate': 'candidate:123'},
          'sdpMid': '0',
          'sdpMLineIndex': 0,
        },
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(fakeWebRTC.remoteCandidates.length, 1);
      expect(fakeWebRTC.remoteCandidates.first['sdpMid'], '0');
    });

    test('Inbound call.end triggers WebRTC cleanup and transitions to ended', () async {
      final userPeer = UserModel(uid: 'user-peer', name: 'Peer', email: 'peer@test.com');
      final userMe = UserModel(uid: 'my-uid', name: 'Me', email: 'me@test.com');

      await container.read(callProvider.notifier).startOutgoingCall(
        targetUser: userPeer,
        callType: CallType.audio,
        currentUser: userMe,
      );
      container.read(callProvider.notifier).setConnected();

      final callId = container.read(callProvider).activeCall!.callId;

      mockChannel.emitFromServer(jsonEncode({
        'type': 'call.end',
        'callId': callId,
        'fromUserId': 'user-peer',
        'toUserId': 'my-uid',
        'payload': {},
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(container.read(callProvider).callState, CallState.ended);
      expect(fakeWebRTC.isCleanedUp, isTrue);
    });

    test('Inbound peer.disconnected triggers WebRTC cleanup and transitions to disconnected', () async {
      final userPeer = UserModel(uid: 'user-peer', name: 'Peer', email: 'peer@test.com');
      final userMe = UserModel(uid: 'my-uid', name: 'Me', email: 'me@test.com');

      await container.read(callProvider.notifier).startOutgoingCall(
        targetUser: userPeer,
        callType: CallType.audio,
        currentUser: userMe,
      );
      container.read(callProvider.notifier).setConnected();

      final callId = container.read(callProvider).activeCall!.callId;

      mockChannel.emitFromServer(jsonEncode({
        'type': 'peer.disconnected',
        'callId': callId,
        'fromUserId': 'user-peer',
        'toUserId': 'my-uid',
        'payload': {},
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(container.read(callProvider).callState, CallState.disconnected);
      expect(fakeWebRTC.isCleanedUp, isTrue);
    });

    test('Inbound call.error triggers WebRTC cleanup and transitions to failed', () async {
      final userPeer = UserModel(uid: 'user-peer', name: 'Peer', email: 'peer@test.com');
      final userMe = UserModel(uid: 'my-uid', name: 'Me', email: 'me@test.com');

      await container.read(callProvider.notifier).startOutgoingCall(
        targetUser: userPeer,
        callType: CallType.audio,
        currentUser: userMe,
      );

      final callId = container.read(callProvider).activeCall!.callId;

      mockChannel.emitFromServer(jsonEncode({
        'type': 'call.error',
        'callId': callId,
        'fromUserId': 'server',
        'toUserId': 'my-uid',
        'payload': {'message': 'Peer unavailable'},
      }));

      await Future.delayed(const Duration(milliseconds: 50));

      expect(container.read(callProvider).callState, CallState.failed);
      expect(container.read(callProvider).errorMessage, contains('Peer unavailable'));
      expect(fakeWebRTC.isCleanedUp, isTrue);
    });

    test('Mute toggle propagates to WebRTCService during active call', () async {
      final userPeer = UserModel(uid: 'user-peer', name: 'Peer', email: 'peer@test.com');
      final userMe = UserModel(uid: 'my-uid', name: 'Me', email: 'me@test.com');

      await container.read(callProvider.notifier).startOutgoingCall(
        targetUser: userPeer,
        callType: CallType.audio,
        currentUser: userMe,
      );
      container.read(callProvider.notifier).setConnected();

      final notifier = container.read(callProvider.notifier);

      // Initially unmuted
      expect(container.read(callProvider).isMuted, isFalse);
      expect(fakeWebRTC.isMuted, isFalse);

      // Mute
      notifier.toggleMute();
      expect(container.read(callProvider).isMuted, isTrue);
      expect(fakeWebRTC.isMuted, isTrue);

      // Unmute
      notifier.toggleMute();
      expect(container.read(callProvider).isMuted, isFalse);
      expect(fakeWebRTC.isMuted, isFalse);
    });
  });
}
