import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_constants.dart';
import '../../providers/call_provider.dart';
import 'audio_call_screen.dart';
import 'incoming_call_screen.dart';
import 'outgoing_call_screen.dart';
import 'video_call_screen.dart';

class CallScreen extends ConsumerWidget {
  const CallScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final callState = ref.watch(callProvider);
    final activeCall = callState.activeCall;

    // Pop screen if call is completely idle
    if (callState.callState == CallState.idle && activeCall == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      });
    }

    if (activeCall == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Incoming Call Ringing UI
    if (activeCall.direction == CallDirection.incoming && callState.callState == CallState.ringing) {
      return const IncomingCallScreen();
    }

    // Connected Active Call UI
    if (callState.callState == CallState.connected) {
      if (activeCall.callType == CallType.video) {
        return const VideoCallScreen();
      }
      return const AudioCallScreen();
    }

    // Default Outgoing Calling / Ringing / Connecting UI
    return const OutgoingCallScreen();
  }
}
