import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/call_model.dart';
import '../services/call_history_service.dart';
import 'auth_provider.dart';

final historyServiceProvider = Provider<CallHistoryService>((ref) {
  return CallHistoryService();
});

class CallHistoryNotifier extends StateNotifier<List<CallModel>> {
  final CallHistoryService _service;

  CallHistoryNotifier(this._service) : super(_service.getHistory());

  /// Record a call record to history and emit updated state
  void addCallRecord(CallModel call, {String? userUid}) {
    _service.addCall(call, userUid: userUid);
    state = _service.getHistory();
  }
}

final callHistoryNotifierProvider =
    StateNotifierProvider<CallHistoryNotifier, List<CallModel>>((ref) {
  final service = ref.watch(historyServiceProvider);
  return CallHistoryNotifier(service);
});

/// Reactive provider exposing the call history list
final callHistoryProvider = Provider<List<CallModel>>((ref) {
  return ref.watch(callHistoryNotifierProvider);
});

/// Stream provider for Firestore call history when user is signed in
final userCallHistoryStreamProvider = StreamProvider<List<CallModel>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null || user.uid.isEmpty) {
    return Stream.value([]);
  }
  final service = ref.watch(historyServiceProvider);
  return service.streamUserCalls(user.uid);
});

