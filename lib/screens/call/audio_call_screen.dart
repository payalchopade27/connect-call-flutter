import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../providers/auth_provider.dart';
import '../../providers/call_provider.dart';

class AudioCallScreen extends ConsumerWidget {
  const AudioCallScreen({super.key});

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
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Header Tag
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  callState.errorMessage != null
                      ? callState.errorMessage!
                      : 'AUDIO CALL IN PROGRESS',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: callState.errorMessage != null
                        ? AppColors.callRed
                        : AppColors.callGreen,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ),

              // Contact Avatar & Timer
              Column(
                children: [
                  CircleAvatar(
                    radius: 60,
                    backgroundColor: AppColors.primary,
                    child: Text(
                      peerName.isNotEmpty ? peerName[0].toUpperCase() : 'U',
                      style: const TextStyle(fontSize: 48, color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    peerName,
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _formatDuration(callState.durationSeconds),
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.primaryLight,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),

              // Audio Control Action Bar
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Mute Button
                  GestureDetector(
                    onTap: () {
                      ref.read(callProvider.notifier).toggleMute();
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: callState.isMuted ? AppColors.callRed.withValues(alpha: 0.2) : AppColors.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: callState.isMuted ? AppColors.callRed : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Icon(
                        callState.isMuted ? Icons.mic_off : Icons.mic,
                        color: callState.isMuted ? AppColors.callRed : Colors.white,
                        size: 28,
                      ),
                    ),
                  ),

                  // End Call Button
                  GestureDetector(
                    onTap: () {
                      ref.read(callProvider.notifier).endCall();
                    },
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: const BoxDecoration(
                        color: AppColors.callRed,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.call_end, color: Colors.white, size: 32),
                    ),
                  ),

                  // Speaker Button
                  GestureDetector(
                    onTap: () {
                      ref.read(callProvider.notifier).toggleSpeaker();
                    },
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: callState.isSpeakerOn
                            ? AppColors.primary.withValues(alpha: 0.25)
                            : AppColors.surface,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: callState.isSpeakerOn ? AppColors.primaryLight : Colors.transparent,
                          width: 1.5,
                        ),
                      ),
                      child: Icon(
                        callState.isSpeakerOn ? Icons.volume_up : Icons.volume_off,
                        color: callState.isSpeakerOn ? AppColors.primaryLight : Colors.white70,
                        size: 28,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
