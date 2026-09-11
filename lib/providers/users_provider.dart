import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/user_model.dart';
import '../services/user_service.dart';
import 'auth_provider.dart';

/// Provider for UserService singleton
final userServiceProvider = Provider<UserService>((ref) {
  return UserService();
});

/// StreamProvider exposing current user's Firestore profile
final currentProfileProvider = StreamProvider<UserModel?>((ref) {
  final userService = ref.watch(userServiceProvider);
  final currentUser = ref.watch(currentUserProvider);

  if (currentUser == null) {
    return Stream.value(null);
  }

  return userService.getUserProfileStream(currentUser.uid);
});

/// StreamProvider exposing all other contacts from Firestore
final otherUsersProvider = StreamProvider<List<UserModel>>((ref) {
  final userService = ref.watch(userServiceProvider);
  final currentUser = ref.watch(currentUserProvider);

  if (currentUser == null) {
    return Stream.value([]);
  }

  return userService.getOtherUsersStream(currentUser.uid);
});

/// StateProvider holding active search query text
final searchQueryProvider = StateProvider<String>((ref) => '');

/// Provider exposing filtered contacts list based on search query
final filteredUsersProvider = Provider<AsyncValue<List<UserModel>>>((ref) {
  final usersAsync = ref.watch(otherUsersProvider);
  final searchQuery = ref.watch(searchQueryProvider).trim().toLowerCase();

  return usersAsync.whenData((users) {
    if (searchQuery.isEmpty) {
      return users;
    }
    return users.where((user) {
      return user.name.toLowerCase().contains(searchQuery) ||
          user.email.toLowerCase().contains(searchQuery);
    }).toList();
  });
});
