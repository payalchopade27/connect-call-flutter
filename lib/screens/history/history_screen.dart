import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../providers/auth_provider.dart';
import '../../providers/history_provider.dart';

class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  String _formatDuration(int seconds) {
    if (seconds == 0) return '';
    final mins = seconds ~/ 60;
    final secs = seconds % 60;
    if (mins > 0) return '${mins}m ${secs}s';
    return '${secs}s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final calls = ref.watch(callHistoryProvider);
    final currentUid = ref.watch(currentUserProvider)?.uid ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calls & History'),
      ),
      body: calls.isEmpty
          ? const Center(
              child: Text(
                'No call history.',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            )
          : ListView.builder(
              itemCount: calls.length,
              itemBuilder: (context, index) {
                final call = calls[index];
                final isVideo = call.callType == CallType.video;
                final isMissed = call.state == CallState.missed;
                final peerName = call.getPeerName(currentUid);

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: isMissed ? AppColors.callRed : AppColors.primary,
                      child: Icon(
                        isVideo ? Icons.videocam : Icons.call,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    title: Text(
                      peerName.isNotEmpty ? peerName : call.callerName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    subtitle: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          call.isIncoming ? Icons.call_received : Icons.call_made,
                          size: 14,
                          color: isMissed ? AppColors.callRed : AppColors.textSecondary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${call.callType.name.toUpperCase()} ${call.duration > 0 ? "• ${_formatDuration(call.duration)}" : ""}',
                          style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceLight,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        call.state.name.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isMissed ? AppColors.callRed : AppColors.primaryLight,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
