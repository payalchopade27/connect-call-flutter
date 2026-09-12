import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../models/user_model.dart';
import '../../providers/auth_provider.dart';
import '../../providers/call_provider.dart';
import '../../providers/users_provider.dart';
import '../../widgets/user_tile.dart';
import '../call/call_screen.dart';

class ContactsScreen extends ConsumerWidget {
  const ContactsScreen({super.key});

  void _triggerOutgoingCall({
    required BuildContext context,
    required WidgetRef ref,
    required UserModel targetUser,
    required CallType callType,
  }) {
    final currentProfile = ref.read(currentProfileProvider).value;
    final fallbackAuth = ref.read(currentUserProvider);

    final currentUser = currentProfile ??
        UserModel(
          uid: fallbackAuth?.uid ?? 'me',
          name: fallbackAuth?.displayName ?? 'Me',
          email: fallbackAuth?.email ?? 'me@connectcall.com',
        );

    ref.read(callProvider.notifier).startOutgoingCall(
          targetUser: targetUser,
          callType: callType,
          currentUser: currentUser,
        );

    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CallScreen()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filteredUsersAsync = ref.watch(filteredUsersProvider);
    final searchQuery = ref.watch(searchQueryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Contacts & Search'),
      ),
      body: Column(
        children: [
          // Search Input Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              onChanged: (val) {
                ref.read(searchQueryProvider.notifier).state = val;
              },
              decoration: InputDecoration(
                hintText: 'Search contacts by name...',
                prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
                suffixIcon: searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: AppColors.textSecondary),
                        onPressed: () {
                          ref.read(searchQueryProvider.notifier).state = '';
                        },
                      )
                    : null,
              ),
            ),
          ),

          // Contacts List Body
          Expanded(
            child: filteredUsersAsync.when(
              data: (users) {
                if (users.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.people_outline_rounded,
                          size: 64,
                          color: AppColors.textSecondary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          searchQuery.isNotEmpty
                              ? 'No contacts matching "$searchQuery"'
                              : 'No other contacts registered yet.',
                          style: const TextStyle(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: users.length,
                  itemBuilder: (context, index) {
                    final user = users[index];
                    return UserTile(
                      user: user,
                      onAudioCall: () => _triggerOutgoingCall(
                        context: context,
                        ref: ref,
                        targetUser: user,
                        callType: CallType.audio,
                      ),
                      onVideoCall: () => _triggerOutgoingCall(
                        context: context,
                        ref: ref,
                        targetUser: user,
                        callType: CallType.video,
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Text('Unable to load contacts: $error'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
