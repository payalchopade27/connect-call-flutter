import '../core/constants/app_constants.dart';
import '../models/call_model.dart';

/// In-memory call history service with foundation for future Firestore sync
class CallHistoryService {
  final List<CallModel> _history = [
    CallModel(
      callId: 'call_1',
      callerId: 'user_alex_999',
      receiverId: 'user_tup_123',
      callerName: 'Alex Rivers',
      receiverName: 'TUP Intern',
      callType: CallType.video,
      state: CallState.ended,
      direction: CallDirection.incoming,
      startedAt: DateTime.now().subtract(const Duration(hours: 2)),
      duration: 245,
    ),
    CallModel(
      callId: 'call_2',
      callerId: 'user_tup_123',
      receiverId: 'user_person1_888',
      callerName: 'TUP Intern',
      receiverName: 'Person 1 (Backend Dev)',
      callType: CallType.audio,
      state: CallState.ended,
      direction: CallDirection.outgoing,
      startedAt: DateTime.now().subtract(const Duration(days: 1)),
      duration: 120,
    ),
    CallModel(
      callId: 'call_3',
      callerId: 'user_sarah_777',
      receiverId: 'user_tup_123',
      callerName: 'Sarah Connor',
      receiverName: 'TUP Intern',
      callType: CallType.video,
      state: CallState.missed,
      direction: CallDirection.incoming,
      startedAt: DateTime.now().subtract(const Duration(days: 2)),
      duration: 0,
    ),
  ];

  /// Get current call history list (newest first)
  List<CallModel> getHistory() {
    return List.unmodifiable(_history);
  }

  /// Backward compatibility for existing callers
  List<CallModel> getMockHistory() => getHistory();

  /// Record a newly completed/missed/rejected call to history
  void addCall(CallModel call) {
    _history.insert(0, call);
  }
}
