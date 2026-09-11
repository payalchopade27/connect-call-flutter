import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../core/constants/app_constants.dart';
import '../models/call_model.dart';

/// Call history service with in-memory cache and optional Firestore sync
class CallHistoryService {
  final FirebaseFirestore? _firestore;

  CallHistoryService([this._firestore]);

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
  void addCall(CallModel call, {String? userUid}) {
    _history.insert(0, call);

    // Asynchronously persist to Firestore if available
    _persistToFirestore(call, userUid: userUid);
  }

  Future<void> _persistToFirestore(CallModel call, {String? userUid}) async {
    try {
      final fs = _firestore ?? FirebaseFirestore.instance;
      final uid = userUid ??
          (call.direction == CallDirection.outgoing
              ? call.callerId
              : call.receiverId);
      if (uid.isNotEmpty) {
        await fs
            .collection('users')
            .doc(uid)
            .collection('calls')
            .doc(call.callId)
            .set(call.toMap(), SetOptions(merge: true));
        debugPrint('✅ [CallHistoryService] Persisted call ${call.callId} to Firestore.');
      }
    } catch (e) {
      // In unit test or offline mode, Firestore may not be available; ignore silently
      debugPrint('ℹ️ [CallHistoryService] Firestore write skipped/fallback: $e');
    }
  }

  /// Stream of call records from Firestore for a given user
  Stream<List<CallModel>> streamUserCalls(String uid) {
    try {
      final fs = _firestore ?? FirebaseFirestore.instance;
      return fs
          .collection('users')
          .doc(uid)
          .collection('calls')
          .orderBy('startedAt', descending: true)
          .snapshots()
          .map((snapshot) {
        return snapshot.docs.map((doc) {
          return CallModel.fromMap(doc.data(), doc.id);
        }).toList();
      });
    } catch (e) {
      debugPrint('ℹ️ [CallHistoryService] Firestore stream fallback: $e');
      return Stream.value(getHistory());
    }
  }
}
