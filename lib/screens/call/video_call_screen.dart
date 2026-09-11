import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../providers/auth_provider.dart';
import '../../providers/call_provider.dart';

class VideoCallScreen extends ConsumerWidget {
  const VideoCallScreen({super.key});

  String _formatDuration(int seconds) {
    final mins = (seconds ~/ 60).toString().padLeft(2, '0');
    final secs = (seconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final callState = ref.watch(callProvider);
    final activeCall = callState.activeCall;
    final currentUid = ref.watch(currentUserProvider)?.uid ?? '';
    final peerName = activeCall?.getPeerName(currentUid) ?? 'Peer';

    final webrtcService = ref.watch(webRTCServiceProvider);
    final localRenderer = webrtcService.localRenderer;
    final remoteRenderer = webrtcService.remoteRenderer;

    final hasRemoteVideo = remoteRenderer != null && remoteRenderer.srcObject != null;
    final hasLocalVideo = localRenderer != null &&
        localRenderer.srcObject != null &&
        !callState.isVideoMuted;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // 1. Remote Video View (Full Screen) or Fallback Placeholder
            Positioned.fill(
              child: hasRemoteVideo
                  ? RTCVideoView(
                      remoteRenderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : Container(
                      color: AppColors.surface,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircleAvatar(
                              radius: 52,
                              backgroundColor: AppColors.primary,
                              child: Text(
                                peerName.isNotEmpty ? peerName[0].toUpperCase() : 'U',
                                style: const TextStyle(
                                  fontSize: 40,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              peerName,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              callState.callState == CallState.connected
                                  ? 'Connected • Camera Off'
                                  : 'Connecting video...',
                              style: const TextStyle(
                                color: AppColors.primaryLight,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),

            // 2. Local Video Preview (Picture-in-Picture Shell in top right)
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                width: 110,
                height: 155,
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: callState.isVideoMuted
                        ? AppColors.callRed
                        : AppColors.primaryLight,
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: hasLocalVideo
                      ? RTCVideoView(
                          localRenderer,
                          mirror: callState.isFrontCamera,
                          objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        )
                      : Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                callState.isVideoMuted
                                    ? Icons.videocam_off
                                    : Icons.camera_alt,
                                color: callState.isVideoMuted
                                    ? AppColors.callRed
                                    : Colors.white70,
                                size: 24,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                callState.isVideoMuted
                                    ? 'Video Off'
                                    : (callState.isFrontCamera
                                        ? 'Front Cam'
                                        : 'Rear Cam'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),

            // 3. Top Status & Duration Bar
            Positioned(
              top: 20,
              left: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.65),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: AppColors.callGreen,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _formatDuration(callState.durationSeconds),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 4. Optional Error Banner Overlay
            if (callState.errorMessage != null)
              Positioned(
                top: 70,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.callRed.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    callState.errorMessage!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),

            // 5. Bottom Action Control Bar
            Positioned(
              bottom: 32,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Mute Microphone Button
                    IconButton(
                      icon: Icon(
                        callState.isMuted ? Icons.mic_off : Icons.mic,
                        color: callState.isMuted ? AppColors.callRed : Colors.white,
                      ),
                      onPressed: () {
                        ref.read(callProvider.notifier).toggleMute();
                      },
                      tooltip: callState.isMuted ? 'Unmute' : 'Mute',
                    ),

                    // Switch Camera Button
                    IconButton(
                      icon: Icon(
                        Icons.cameraswitch,
                        color: callState.isFrontCamera
                            ? Colors.white
                            : AppColors.primaryLight,
                      ),
                      onPressed: () {
                        ref.read(callProvider.notifier).switchCamera();
                      },
                      tooltip: 'Switch Camera',
                    ),

                    // Speakerphone Button
                    IconButton(
                      icon: Icon(
                        callState.isSpeakerOn ? Icons.volume_up : Icons.volume_off,
                        color: callState.isSpeakerOn
                            ? AppColors.primaryLight
                            : Colors.white70,
                      ),
                      onPressed: () {
                        ref.read(callProvider.notifier).toggleSpeaker();
                      },
                      tooltip: callState.isSpeakerOn
                          ? 'Speakerphone On'
                          : 'Speakerphone Off',
                    ),

                    // Toggle Video Button
                    IconButton(
                      icon: Icon(
                        callState.isVideoMuted ? Icons.videocam_off : Icons.videocam,
                        color: callState.isVideoMuted
                            ? AppColors.callRed
                            : Colors.white,
                      ),
                      onPressed: () {
                        ref.read(callProvider.notifier).toggleVideo();
                      },
                      tooltip: callState.isVideoMuted
                          ? 'Turn Camera On'
                          : 'Turn Camera Off',
                    ),

                    // End Call Button
                    GestureDetector(
                      onTap: () {
                        ref.read(callProvider.notifier).endCall();
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: const BoxDecoration(
                          color: AppColors.callRed,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.call_end, color: Colors.white, size: 24),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
