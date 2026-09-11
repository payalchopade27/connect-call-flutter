import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../core/constants/app_constants.dart';

/// Service managing WebRTC media and peer connection for 1-to-1 audio calling.
///
/// Scope: AUDIO ONLY.
/// Handles:
/// - Local microphone acquisition (getUserMedia audio: true, video: false)
/// - RTCPeerConnection creation with centralized STUN/ICE configuration
/// - Local audio track management
/// - SDP offer & answer generation and remote description handling
/// - ICE candidate exchange & candidate queueing
/// - Remote audio reception
/// - Real microphone mute/unmute
/// - Speakerphone routing via Helper.setSpeakerphoneOn
/// - Comprehensive teardown and cleanup
class WebRTCService {
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  bool _remoteDescriptionSet = false;
  final List<RTCIceCandidate> _queuedRemoteCandidates = [];

  // Callbacks to communicate state to CallProvider
  void Function(RTCIceCandidate candidate)? onLocalIceCandidate;
  void Function(MediaStream remoteStream)? onRemoteStreamAdded;
  void Function(RTCPeerConnectionState state)? onConnectionStateChange;
  void Function(String error)? onError;

  /// Current local audio stream
  MediaStream? get localStream => _localStream;

  /// Current remote audio stream
  MediaStream? get remoteStream => _remoteStream;

  /// Current peer connection
  RTCPeerConnection? get peerConnection => _peerConnection;

  /// Whether remote description has been set (ready for ICE candidates)
  bool get isRemoteDescriptionSet => _remoteDescriptionSet;

  /// Initialize local audio stream and RTCPeerConnection for an audio call.
  /// [iceServers] allows overriding default STUN configuration (e.g. for testing or production TURN).
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
      final config = iceServers ?? AppConstants.iceServers;
      _peerConnection = await createPeerConnection(config);
      debugPrint('✅ [WebRTCService] RTCPeerConnection created.');

      // 3. Add local audio tracks to the peer connection
      for (final track in _localStream!.getAudioTracks()) {
        await _peerConnection!.addTrack(track, _localStream!);
        debugPrint('➕ [WebRTCService] Added local audio track: ${track.id} (enabled: ${track.enabled})');
      }

      // 4. Register RTCPeerConnection event listeners
      _setupPeerConnectionListeners();
    } catch (e, stack) {
      debugPrint('❌ [WebRTCService] Failed to initialize WebRTC: $e\n$stack');
      onError?.call('Failed to initialize audio media: $e');
      rethrow;
    }
  }

  void _setupPeerConnectionListeners() {
    if (_peerConnection == null) return;

    // ICE candidate generated locally -> notify caller to send webrtc.ice
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null || candidate.candidate!.isEmpty) return;
      debugPrint('🧊 [WebRTCService] Local ICE candidate generated: sdpMid=${candidate.sdpMid}, index=${candidate.sdpMLineIndex}');
      onLocalIceCandidate?.call(candidate);
    };

    // Remote track / stream received
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      debugPrint('🎧 [WebRTCService] onTrack event received: track=${event.track.kind}, id=${event.track.id}');
      if (event.streams.isNotEmpty) {
        _remoteStream = event.streams.first;
        onRemoteStreamAdded?.call(_remoteStream!);
      }
    };

    _peerConnection!.onAddStream = (MediaStream stream) {
      debugPrint('🎧 [WebRTCService] onAddStream event received: ${stream.id}');
      _remoteStream = stream;
      onRemoteStreamAdded?.call(stream);
    };

    // Peer connection state changes
    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      debugPrint('📶 [WebRTCService] PeerConnection state changed: $state');
      onConnectionStateChange?.call(state);
    };

    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
      debugPrint('🧊 [WebRTCService] ICE connection state changed: $state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected) {
        onConnectionStateChange?.call(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        onConnectionStateChange?.call(RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        onConnectionStateChange?.call(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      }
    };
  }

  /// Caller side: Create SDP offer, set local description, and return offer SDP string.
  Future<String> createOffer() async {
    if (_peerConnection == null) {
      throw StateError('Cannot create offer: RTCPeerConnection is not initialized.');
    }

    try {
      debugPrint('📄 [WebRTCService] Creating SDP offer (audio only)...');
      final RTCSessionDescription offer = await _peerConnection!.createOffer(
        AppConstants.audioSdpConstraints,
      );
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
  Future<String> handleOfferAndCreateAnswer(String remoteOfferSdp) async {
    if (_peerConnection == null) {
      throw StateError('Cannot handle offer: RTCPeerConnection is not initialized.');
    }

    try {
      debugPrint('📥 [WebRTCService] Setting remote description (offer)...');
      final remoteDescription = RTCSessionDescription(remoteOfferSdp, 'offer');
      await _peerConnection!.setRemoteDescription(remoteDescription);
      _remoteDescriptionSet = true;
      debugPrint('✅ [WebRTCService] Remote description set (offer). Draining queued ICE candidates...');
      await _drainQueuedCandidates();

      debugPrint('📄 [WebRTCService] Creating SDP answer (audio only)...');
      final RTCSessionDescription answer = await _peerConnection!.createAnswer(
        AppConstants.audioSdpConstraints,
      );
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
        debugPrint('🧊 [WebRTCService] Adding remote ICE candidate: sdpMid=$sdpMid, index=$sdpMLineIndex');
        await _peerConnection!.addCandidate(candidate);
      } catch (e) {
        debugPrint('⚠️ [WebRTCService] Error adding remote candidate: $e');
      }
    } else {
      debugPrint('⏳ [WebRTCService] Queuing remote ICE candidate (remote description not set yet)');
      _queuedRemoteCandidates.add(candidate);
    }
  }

  /// Drain queued remote ICE candidates once remote description is set.
  Future<void> _drainQueuedCandidates() async {
    if (_peerConnection == null || _queuedRemoteCandidates.isEmpty) return;

    debugPrint('🧊 [WebRTCService] Draining ${_queuedRemoteCandidates.length} queued remote ICE candidates...');
    for (final candidate in List<RTCIceCandidate>.from(_queuedRemoteCandidates)) {
      try {
        await _peerConnection!.addCandidate(candidate);
      } catch (e) {
        debugPrint('⚠️ [WebRTCService] Error adding queued candidate: $e');
      }
    }
    _queuedRemoteCandidates.clear();
  }

  /// Mute or unmute the local microphone track.
  /// Connects directly to hardware track enabled state.
  void setMicrophoneMute(bool isMuted) {
    if (_localStream == null) return;
    for (final track in _localStream!.getAudioTracks()) {
      track.enabled = !isMuted;
      debugPrint('🎙️ [WebRTCService] Audio track ${track.id} enabled=${track.enabled} (muted=$isMuted)');
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

  /// Clean up all WebRTC media streams, peer connection, and candidate queues.
  Future<void> cleanup() async {
    debugPrint('🧹 [WebRTCService] Cleaning up WebRTC resources...');
    _remoteDescriptionSet = false;
    _queuedRemoteCandidates.clear();

    try {
      // 1. Stop all local audio tracks
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

      debugPrint('✅ [WebRTCService] WebRTC resources successfully cleaned up.');
    } catch (e) {
      debugPrint('⚠️ [WebRTCService] Error during WebRTC cleanup: $e');
    }
  }

  void dispose() {
    cleanup();
  }
}
