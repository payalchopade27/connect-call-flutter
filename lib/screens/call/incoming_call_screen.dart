import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../providers/auth_provider.dart';
import '../../providers/call_provider.dart';

class IncomingCallScreen extends ConsumerWidget {
  const IncomingCallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final callState = ref.watch(callProvider);
    final activeCall = callState.activeCall;
    final currentUid = ref.watch(currentUserProvider)?.uid ?? '';
    final peerName = activeCall?.getPeerName(currentUid) ?? (activeCall?.callerName ?? 'Incoming Call');

    final isVideo = activeCall?.callType == CallType.video;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 48.0),
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
                  'INCOMING ${isVideo ? "VIDEO" : "AUDIO"} CALL',
                  style: const TextStyle(
                    color: AppColors.primaryLight,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ),

              // Caller Details
              Column(
                children: [
                  CircleAvatar(
                    radius: 56,
                    backgroundColor: AppColors.primary,
                    child: Text(
                      peerName.isNotEmpty ? peerName[0].toUpperCase() : 'C',
                      style: const TextStyle(fontSize: 44, color: Colors.white, fontWeight: FontWeight.bold),
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
                  const Text(
                    'Ringing...',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 16),
                  ),
                ],
              ),

              // Action Buttons (Reject & Accept)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Reject Button
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () {
                          ref.read(callProvider.notifier).rejectCall();
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
                      const SizedBox(height: 8),
                      const Text('Decline', style: TextStyle(color: AppColors.textSecondary)),
                    ],
                  ),

                  // Accept Button
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () {
                          ref.read(callProvider.notifier).acceptCall();
                        },
                        child: Container(
                          padding: const EdgeInsets.all(20),
                          decoration: const BoxDecoration(
                            color: AppColors.callGreen,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            isVideo ? Icons.videocam : Icons.call,
                            color: Colors.white,
                            size: 32,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text('Accept', style: TextStyle(color: AppColors.textSecondary)),
                    ],
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
