import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
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

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = DateTime(dt.year, dt.month, dt.day);

    if (date == today) {
      return 'Today, ${DateFormat.jm().format(dt)}';
    } else if (date == today.subtract(const Duration(days: 1))) {
      return 'Yesterday, ${DateFormat.jm().format(dt)}';
    } else {
      return DateFormat('MMM d, h:mm a').format(dt);
    }
  }

  Color _getStatusColor(CallState state) {
    switch (state) {
      case CallState.ended:
        return AppColors.callGreen;
      case CallState.missed:
      case CallState.failed:
        return AppColors.callRed;
      case CallState.rejected:
      case CallState.busy:
        return Colors.orangeAccent;
      case CallState.disconnected:
        return Colors.amber;
      default:
        return AppColors.primaryLight;
    }
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
                final statusColor = _getStatusColor(call.state);

                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    leading: CircleAvatar(
                      radius: 22,
                      backgroundColor: isMissed
                          ? AppColors.callRed.withValues(alpha: 0.15)
                          : AppColors.primary.withValues(alpha: 0.15),
                      child: Icon(
                        isVideo ? Icons.videocam : Icons.call,
                        color: isMissed ? AppColors.callRed : AppColors.primaryLight,
                        size: 22,
                      ),
                    ),
                    title: Text(
                      peerName.isNotEmpty ? peerName : call.callerName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                        fontSize: 15,
                      ),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                call.isIncoming ? Icons.call_received : Icons.call_made,
                                size: 13,
                                color: isMissed ? AppColors.callRed : AppColors.textSecondary,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${call.callType.name.toUpperCase()} ${call.duration > 0 ? "• ${_formatDuration(call.duration)}" : ""}',
                                style: const TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _formatDate(call.startedAt),
                            style: TextStyle(
                              color: AppColors.textSecondary.withValues(alpha: 0.8),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: statusColor.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: Text(
                        call.state.name.toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: statusColor,
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
