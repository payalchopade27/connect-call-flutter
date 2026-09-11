import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../core/constants/app_constants.dart';

/// Service managing WebRTC media and peer connection for 1-to-1 audio AND video calling.
///
/// Handles:
/// - Local microphone acquisition (getUserMedia audio: true, video: false) — audio calls
/// - Local camera + microphone acquisition — video calls
/// - RTCPeerConnection creation with centralized STUN/ICE configuration
/// - Local audio track management
/// - Local video track management
/// - RTCVideoRenderer lifecycle for local and remote video
/// - SDP offer & answer generation and remote description handling
/// - ICE candidate exchange & candidate queueing
/// - Remote audio/video reception
/// - Real microphone mute/unmute
/// - Video track enable/disable (camera on/off)
/// - Camera switching (front ↔ rear)
/// - Speakerphone routing via Helper.setSpeakerphoneOn
/// - Comprehensive teardown and cleanup
class WebRTCService {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  // Video renderers (initialized lazily for video calls)
  RTCVideoRenderer? _localRenderer;
  RTCVideoRenderer? _remoteRenderer;
  bool _renderersInitialized = false;

  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _queuedRemoteCandidates = [];

  // Callbacks to communicate state to CallProvider
  void Function(RTCIceCandidate candidate)? onLocalIceCandidate;
  void Function(MediaStream remoteStream)? onRemoteStreamAdded;
  void Function(RTCPeerConnectionState state)? onConnectionStateChange;
  void Function(String error)? onError;

  /// Current local audio/video stream
  MediaStream? get localStream => _localStream;

  /// Current remote audio/video stream
  MediaStream? get remoteStream => _remoteStream;

  /// Current peer connection
  RTCPeerConnection? get peerConnection => _peerConnection;

  /// Whether remote description has been set (ready for ICE candidates)
  bool get isRemoteDescriptionSet => _remoteDescriptionSet;

  /// Local video renderer (initialized when video call is active)
  RTCVideoRenderer? get localRenderer => _localRenderer;

  /// Remote video renderer (initialized when video call is active)
  RTCVideoRenderer? get remoteRenderer => _remoteRenderer;

  // ==========================================
  // INITIALIZATION
  // ==========================================

  /// Initialize local audio stream and RTCPeerConnection for an audio call.
  /// [iceServers] allows overriding default STUN configuration.
  Future<void> initialize({
    Map<String, dynamic>? iceServers,
  }) async {
    try {
      debugPrint('🎙️ [WebRTCService] Initializing WebRTC audio engine...');

      // 1. Acquire local microphone stream (audio only)
      _localStream = await navigator.mediaDevices.getUserMedia(
        AppConstants.audioMediaConstraints,
      );
      debugPrint('✅ [WebRTCService] Local microphone stream acquired: ${_localStream?.id}');

      // 2. Create RTCPeerConnection with centralized STUN configuration
      await _createPeerConnection(iceServers);

      // 3. Add local audio tracks to the peer connection
      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
        debugPrint('➕ [WebRTCService] Added local audio track: ${track.id}');
      }

      // 4. Register RTCPeerConnection event listeners
      _setupPeerConnectionListeners();
    } catch (e, stack) {
      debugPrint('❌ [WebRTCService] Failed to initialize audio WebRTC: $e\n$stack');
      onError?.call('Failed to initialize audio media: $e');
      rethrow;
    }
  }

  /// Initialize local camera + microphone stream and RTCPeerConnection for a video call.
  /// Also initializes RTCVideoRenderers for local and remote video display.
  Future<void> initializeVideo({
    Map<String, dynamic>? iceServers,
  }) async {
    try {
      debugPrint('📹 [WebRTCService] Initializing WebRTC video engine...');

      // 1. Initialize RTCVideoRenderers for local and remote feeds
      await _initializeRenderers();

      // 2. Acquire local camera + microphone stream
      _localStream = await navigator.mediaDevices.getUserMedia(
        AppConstants.videoMediaConstraints,
      );
      debugPrint('✅ [WebRTCService] Local camera+mic stream acquired: ${_localStream?.id}');

      // 3. Attach local stream to local renderer
      _localRenderer!.srcObject = _localStream;

      // 4. Create RTCPeerConnection
      await _createPeerConnection(iceServers);

      // 5. Add all local tracks (audio + video)
      for (final track in _localStream!.getTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
        debugPrint('➕ [WebRTCService] Added local track: ${track.kind} id=${track.id}');
      }

      // 6. Register RTCPeerConnection event listeners
      _setupPeerConnectionListeners();
    } catch (e, stack) {
      debugPrint('❌ [WebRTCService] Failed to initialize video WebRTC: $e\n$stack');
      onError?.call('Failed to initialize video media: $e');
      rethrow;
    }
  }

  Future<void> _initializeRenderers() async {
    if (_renderersInitialized) return;
    _localRenderer = RTCVideoRenderer();
    _remoteRenderer = RTCVideoRenderer();
    await _localRenderer!.initialize();
    await _remoteRenderer!.initialize();
    _renderersInitialized = true;
    debugPrint('✅ [WebRTCService] RTCVideoRenderers initialized.');
  }

  Future<void> _createPeerConnection(Map<String, dynamic>? iceServers) async {
    final config = iceServers ?? AppConstants.iceServers;
    _peerConnection = await createPeerConnection(config);
    debugPrint('✅ [WebRTCService] RTCPeerConnection created.');
  }

  void _setupPeerConnectionListeners() {
    if (_peerConnection == null) return;

    // ICE candidate generated locally -> notify caller to send webrtc.ice
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      debugPrint('🧊 [WebRTCService] Local ICE candidate: sdpMid=${candidate.sdpMid}');
      onLocalIceCandidate?.call(candidate);
    };

    // Remote track / stream received
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      debugPrint('🎧 [WebRTCService] onTrack: track=${event.track.kind}, id=${event.track.id}');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        // Attach to remote renderer if available (video call)
        if (_remoteRenderer != null) {
          _remoteRenderer!.srcObject = _remoteStream;
        }
        onRemoteStreamAdded?.call(_remoteStream!);
      }
    };

    _peerConnection!.onAddStream = (MediaStream stream) {
      debugPrint('🎧 [WebRTCService] onAddStream: ${stream.id}');
      _remoteStream = stream;
      if (_remoteRenderer != null) {
        _remoteRenderer!.srcObject = _remoteStream;
      }
      onRemoteStreamAdded?.call(stream);
    };

    // Peer connection state changes
    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('📶 [WebRTCService] PeerConnection state: $state');
      onConnectionStateChange?.call(state);
    };

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('🧊 [WebRTCService] ICE connection state: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        onConnectionStateChange?.call(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        onConnectionStateChange?.call(RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        onConnectionStateChange?.call(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      }
    };
  }

  // ==========================================
  // OFFER / ANSWER / ICE
  // ==========================================

  /// Caller side: Create SDP offer, set local description, and return offer SDP string.
  Future<String> createOffer({bool isVideo = false}) async {
    if (_peerConnection == null) {
      throw StateError('Cannot create offer: RTCPeerConnection is not initialized.');
    }

    try {
      debugPrint('📄 [WebRTCService] Creating SDP offer (isVideo=$isVideo)...');
      final constraints = isVideo
          ? AppConstants.videoSdpConstraints
          : AppConstants.audioSdpConstraints;
      final RTCSessionDescription offer = await _peerConnection!.createOffer(constraints);
      await _peerConnection!.setLocalDescription(offer);
      debugPrint('✅ [WebRTCService] Local description set (offer).');
      return offer.sdp ?? '';
    } catch (e) {
      debugPrint('❌ [WebRTCService] Failed to create SDP offer: $e');
      onError?.call('Failed to create call offer: $e');
      rethrow;
    }
  }

  /// Callee side: Receive remote SDP offer, set remote description, create SDP answer,
  /// set local description, and return answer SDP string.
  Future<String> handleOfferAndCreateAnswer(String remoteOfferSdp, {bool isVideo = false}) async {
    if (_peerConnection == null) {
      throw StateError('Cannot handle offer: RTCPeerConnection is not initialized.');
    }

    try {
      debugPrint('📥 [WebRTCService] Setting remote description (offer)...');
      final remoteDescription = RTCSessionDescription(remoteOfferSdp, 'offer');
      await _peerConnection!.setRemoteDescription(remoteDescription);
      _remoteDescriptionSet = true;
      debugPrint('✅ [WebRTCService] Remote description set. Draining queued ICE candidates...');
      await _drainQueuedCandidates();

      debugPrint('📄 [WebRTCService] Creating SDP answer (isVideo=$isVideo)...');
      final constraints = isVideo
          ? AppConstants.videoSdpConstraints
          : AppConstants.audioSdpConstraints;
      final RTCSessionDescription answer = await _peerConnection!.createAnswer(constraints);
      await _peerConnection!.setLocalDescription(answer);
      debugPrint('✅ [WebRTCService] Local description set (answer).');
      return answer.sdp ?? '';
    } catch (e) {
      debugPrint('❌ [WebRTCService] Failed to handle offer and create answer: $e');
      onError?.call('Failed to answer call: $e');
      rethrow;
    }
  }

  /// Caller side: Set remote SDP answer when received from callee.
  Future<void> handleRemoteAnswer(String remoteAnswerSdp) async {
    if (_peerConnection == null) {
      throw StateError('Cannot handle answer: RTCPeerConnection is not initialized.');
    }

    try {
      debugPrint('📥 [WebRTCService] Setting remote description (answer)...');
      final remoteDescription = RTCSessionDescription(remoteAnswerSdp, 'answer');
      await _peerConnection!.setRemoteDescription(remoteDescription);
      _remoteDescriptionSet = true;
      debugPrint('✅ [WebRTCService] Remote description set (answer). Draining queued ICE candidates...');
      await _drainQueuedCandidates();
    } catch (e) {
      debugPrint('❌ [WebRTCService] Failed to set remote answer: $e');
      onError?.call('Failed to complete call handshake: $e');
      rethrow;
    }
  }

  /// Handle incoming remote ICE candidate received through signaling.
  /// If remote description is already set, adds candidate immediately.
  /// Otherwise, queues candidate until remote description is set.
  Future<void> addRemoteIceCandidate({
    required dynamic candidateData,
    String? sdpMid,
    int? sdpMLineIndex,
  }) async {
    String? candidateString;

    if (candidateData is Map) {
      candidateString = candidateData['candidate']?.toString();
      sdpMid ??= candidateData['sdpMid']?.toString();
      final lineIdx = candidateData['sdpMLineIndex'];
      if (lineIdx is int) {
        sdpMLineIndex ??= lineIdx;
      } else if (lineIdx is String) {
        sdpMLineIndex ??= int.tryParse(lineIdx);
      }
    } else if (candidateData is String) {
      candidateString = candidateData;
    }

    if (candidateString == null || candidateString.isEmpty) {
      debugPrint('⚠️ [WebRTCService] Received empty or invalid candidate. Skipping.');
      return;
    }

    final candidate = RTCIceCandidate(candidateString, sdpMid, sdpMLineIndex);

    if (_remoteDescriptionSet && _peerConnection != null) {
      try {
        debugPrint('🧊 [WebRTCService] Adding remote ICE candidate: sdpMid=$sdpMid');
        await _peerConnection!.addCandidate(candidate);
      } catch (e) {
        debugPrint('⚠️ [WebRTCService] Error adding remote candidate: $e');
      }
    } else {
      debugPrint('⏳ [WebRTCService] Queuing remote ICE candidate (remote description not set yet)');
      _queuedRemoteCandidates.add(candidate);
    }
  }

  Future<void> _drainQueuedCandidates() async {
    if (_peerConnection == null || _queuedRemoteCandidates.isEmpty) return;

    debugPrint('🧊 [WebRTCService] Draining ${_queuedRemoteCandidates.length} queued ICE candidates...');
    for (final candidate in List<RTCIceCandidate>.from(_queuedRemoteCandidates)) {
      try {
        await _peerConnection!.addCandidate(candidate);
      } catch (e) {
        debugPrint('⚠️ [WebRTCService] Error adding queued candidate: $e');
      }
    }
    _queuedRemoteCandidates.clear();
  }

  // ==========================================
  // MEDIA CONTROLS
  // ==========================================

  /// Mute or unmute the local microphone track.
  /// Connects directly to hardware track enabled state.
  void setMicrophoneMute(bool isMuted) {
    if (_localStream == null) return;
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = !isMuted;
      debugPrint('🎙️ [WebRTCService] Audio track ${track.id} enabled=${track.enabled}');
    }
  }

  /// Enable or disable the local camera video track.
  void setVideoMute(bool isMuted) {
    if (_localStream == null) return;
    for (final track in _localStream!.getVideoTracks()) {
      track.enabled = !isMuted;
      debugPrint('📹 [WebRTCService] Video track ${track.id} enabled=${track.enabled}');
    }
    // Update renderer srcObject so the local preview reflects the mute state
    if (_localRenderer != null) {
      _localRenderer!.srcObject = isMuted ? null : _localStream;
    }
  }

  /// Switch between front and rear cameras.
  Future<void> switchCamera() async {
    if (_localStream == null) return;
    try {
      final videoTracks = _localStream!.getVideoTracks();
      if (videoTracks.isNotEmpty) {
        await Helper.switchCamera(videoTracks.first);
        debugPrint('🔄 [WebRTCService] Camera switched.');
      }
    } catch (e) {
      debugPrint('⚠️ [WebRTCService] Failed to switch camera: $e');
    }
  }

  /// Route audio through loudspeaker or earpiece.
  void enableSpeakerphone(bool enable) {
    try {
      Helper.setSpeakerphoneOn(enable);
      debugPrint('🔊 [WebRTCService] Speakerphone set to: $enable');
    } catch (e) {
      debugPrint('⚠️ [WebRTCService] Failed to toggle speakerphone: $e');
    }
  }

  // ==========================================
  // CLEANUP
  // ==========================================

  /// Clean up all WebRTC media streams, peer connection, renderers, and candidate queues.
  /// This method is idempotent — safe to call multiple times.
  Future<void> cleanup() async {
    debugPrint('🧹 [WebRTCService] Cleaning up WebRTC resources...');
    _remoteDescriptionSet = false;
    _queuedRemoteCandidates.clear();

    try {
      // 1. Stop all local tracks
      if (_localStream != null) {
        for (final track in _localStream!.getTracks()) {
          track.stop();
        }
        await _localStream!.dispose();
        _localStream = null;
      }

      // 2. Dispose remote stream
      if (_remoteStream != null) {
        for (final track in _remoteStream!.getTracks()) {
          track.stop();
        }
        await _remoteStream!.dispose();
        _remoteStream = null;
      }

      // 3. Close and dispose peer connection
      if (_peerConnection != null) {
        await _peerConnection!.close();
        await _peerConnection!.dispose();
        _peerConnection = null;
      }

      // 4. Dispose video renderers
      if (_renderersInitialized) {
        try {
          _localRenderer?.srcObject = null;
          _remoteRenderer?.srcObject = null;
          await _localRenderer?.dispose();
          await _remoteRenderer?.dispose();
        } catch (e) {
          debugPrint('⚠️ [WebRTCService] Renderer dispose error: $e');
        }
        _localRenderer = null;
        _remoteRenderer = null;
        _renderersInitialized = false;
      }

      debugPrint('✅ [WebRTCService] WebRTC resources successfully cleaned up.');
    } catch (e) {
      debugPrint('⚠️ [WebRTCService] Error during WebRTC cleanup: $e');
    }
  }

  void dispose() {
    cleanup();
  }
}
