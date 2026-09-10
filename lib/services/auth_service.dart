import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/user_model.dart';
import 'user_service.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final UserService _userService = UserService();

  /// Stream of authentication state changes
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  /// Current authenticated user
  User? get currentUser => _auth.currentUser;

  /// Register a new user with Email and Password
  Future<UserCredential> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );

      if (credential.user != null) {
        final uid = credential.user!.uid;
        final name = displayName.trim().isNotEmpty ? displayName.trim() : 'User';

        await credential.user!.updateDisplayName(name);

        // Create Firestore user document users/{uid}
        final newUser = UserModel(
          uid: uid,
          name: name,
          email: email.trim(),
          isOnline: true,
          createdAt: DateTime.now(),
          lastSeen: DateTime.now(),
        );

        await _userService.createUserProfile(newUser);
      }

      return credential;
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      throw 'An unexpected error occurred. Please try again.';
    }
  }

  /// Sign in with Email and Password
  Future<UserCredential> login({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );

      if (credential.user != null) {
        final uid = credential.user!.uid;
        
        // Ensure Firestore profile exists and mark user as online
        final existingProfile = await _userService.getUserProfileOnce(uid);
        if (existingProfile == null) {
          final newProfile = UserModel(
            uid: uid,
            name: credential.user!.displayName ?? 'User',
            email: credential.user!.email ?? email.trim(),
            isOnline: true,
            createdAt: DateTime.now(),
          );
          await _userService.createUserProfile(newProfile);
        } else {
          await _userService.updateOnlineStatus(uid, true);
        }
      }

      return credential;
    } on FirebaseAuthException catch (e) {
      throw _handleAuthException(e);
    } catch (e) {
      throw 'An unexpected error occurred. Please try again.';
    }
  }

  /// Sign out current user
  Future<void> logout() async {
    try {
      if (currentUser != null) {
        await _userService.updateOnlineStatus(currentUser!.uid, false);
      }
      await _auth.signOut();
    } catch (e) {
      debugPrint('[AuthService] Logout error: $e');
    }
  }

  /// Map raw Firebase error codes to clean, user-friendly messages
  String _handleAuthException(FirebaseAuthException e) {
    debugPrint('[AuthService] Error code: ${e.code}');
    switch (e.code) {
      case 'invalid-email':
        return 'The email address format is invalid.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'user-not-found':
        return 'No account found with this email address.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect password or email credentials.';
      case 'email-already-in-use':
        return 'An account already exists with this email address.';
      case 'operation-not-allowed':
        return 'Email/Password sign-in is not enabled in Firebase Console.';
      case 'weak-password':
        return 'The password is too weak. Please use at least 6 characters.';
      case 'network-request-failed':
        return 'Network connection failed. Please check your internet connection.';
      default:
        return e.message ?? 'Authentication failed. Please check your details.';
    }
  }
}
