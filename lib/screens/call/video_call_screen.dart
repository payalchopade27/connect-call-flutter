import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Remote Video Placeholder (Full Screen Shell)
            Container(
              color: AppColors.surface,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleAvatar(
                      radius: 48,
                      backgroundColor: AppColors.primary,
                      child: Text(
                        peerName.isNotEmpty ? peerName[0].toUpperCase() : 'U',
                        style: const TextStyle(fontSize: 36, color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      peerName,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '📹 Remote WebRTC Video Stream Placeholder',
                      style: TextStyle(color: AppColors.primaryLight, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

            // Local Video Preview Placeholder (Picture-in-Picture Shell in top right)
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                width: 110,
                height: 150,
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: callState.isVideoMuted ? AppColors.callRed : AppColors.primaryLight,
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        callState.isVideoMuted ? Icons.videocam_off : Icons.camera_alt,
                        color: callState.isVideoMuted ? AppColors.callRed : Colors.white70,
                        size: 24,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        callState.isVideoMuted
                            ? 'Video Muted'
                            : (callState.isFrontCamera ? 'Front Cam' : 'Rear Cam'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Top Status & Duration Bar
            Positioned(
              top: 20,
              left: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _formatDuration(callState.durationSeconds),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontFamily: 'monospace'),
                ),
              ),
            ),

            // Bottom Action Control Bar
            Positioned(
              bottom: 32,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(32),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Mute Button
                    IconButton(
                      icon: Icon(
                        callState.isMuted ? Icons.mic_off : Icons.mic,
                        color: callState.isMuted ? AppColors.callRed : Colors.white,
                      ),
                      onPressed: () {
                        ref.read(callProvider.notifier).toggleMute();
                      },
                      tooltip: callState.isMuted ? 'Unmute Microphone' : 'Mute Microphone',
                    ),

                    // Switch Camera Button
                    IconButton(
                      icon: Icon(
                        Icons.cameraswitch,
                        color: callState.isFrontCamera ? Colors.white : AppColors.primaryLight,
                      ),
                      onPressed: () {
                        ref.read(callProvider.notifier).switchCamera();
                      },
                      tooltip: 'Switch Camera',
                    ),

                    // Toggle Video Button
                    IconButton(
                      icon: Icon(
                        callState.isVideoMuted ? Icons.videocam_off : Icons.videocam,
                        color: callState.isVideoMuted ? AppColors.callRed : Colors.white,
                      ),
                      onPressed: () {
                        ref.read(callProvider.notifier).toggleVideo();
                      },
                      tooltip: callState.isVideoMuted ? 'Turn Camera On' : 'Turn Camera Off',
                    ),

                    // End Call Button
                    GestureDetector(
                      onTap: () {
                        ref.read(callProvider.notifier).endCall();
                      },
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: const BoxDecoration(
                          color: AppColors.callRed,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.call_end, color: Colors.white),
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
