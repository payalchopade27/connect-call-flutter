import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/user_model.dart';

class UserService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _usersRef =>
      _firestore.collection('users');

  /// Create or update user profile document at users/{uid}
  Future<void> createUserProfile(UserModel user) async {
    try {
      final docRef = _usersRef.doc(user.uid);
      final docSnapshot = await docRef.get();

      if (!docSnapshot.exists) {
        debugPrint('[UserService] Creating new user profile for UID: ${user.uid}');
        await docRef.set(user.toFirestore(), SetOptions(merge: true));
      } else {
        debugPrint('[UserService] User profile already exists for UID: ${user.uid}');
        await updateOnlineStatus(user.uid, true);
      }
    } catch (e) {
      debugPrint('[UserService] Error creating user profile: $e');
    }
  }

  /// Get real-time stream of current user's profile
  Stream<UserModel?> getUserProfileStream(String uid) {
    return _usersRef.doc(uid).snapshots().map((doc) {
      if (doc.exists && doc.data() != null) {
        return UserModel.fromFirestore(doc);
      }
      return null;
    });
  }

  /// Get user profile once by Firebase UID
  Future<UserModel?> getUserProfileOnce(String uid) async {
    try {
      final doc = await _usersRef.doc(uid).get();
      if (doc.exists && doc.data() != null) {
        return UserModel.fromFirestore(doc);
      }
    } catch (e) {
      debugPrint('[UserService] Error fetching user profile: $e');
    }
    return null;
  }

  /// Get real-time stream of all other registered users (contacts)
  Stream<List<UserModel>> getOtherUsersStream(String currentUid) {
    return _usersRef.snapshots().map((snapshot) {
      return snapshot.docs
          .where((doc) => doc.id != currentUid)
          .map((doc) => UserModel.fromFirestore(doc))
          .toList();
    });
  }

  /// Update user profile details (name, phone, bio)
  Future<void> updateUserProfile({
    required String uid,
    required String name,
    String? phone,
    String? bio,
  }) async {
    try {
      await _usersRef.doc(uid).update({
        'name': name.trim(),
        'phone': phone?.trim(),
        'bio': bio?.trim(),
      });
      debugPrint('[UserService] User profile updated for UID: $uid');
    } catch (e) {
      debugPrint('[UserService] Error updating profile: $e');
      throw 'Failed to update profile. Please try again.';
    }
  }

  /// Update online status and lastSeen timestamp
  Future<void> updateOnlineStatus(String uid, bool isOnline) async {
    try {
      await _usersRef.doc(uid).update({
        'isOnline': isOnline,
        'lastSeen': FieldValue.serverTimestamp(),
      });
      debugPrint('[UserService] Updated online status for $uid: $isOnline');
    } catch (e) {
      debugPrint('[UserService] Error updating online status: $e');
    }
  }
}
