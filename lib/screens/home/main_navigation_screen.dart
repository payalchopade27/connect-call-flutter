import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_constants.dart';
import '../../providers/auth_provider.dart';
import '../../providers/call_provider.dart';
import '../call/call_screen.dart';
import 'home_screen.dart';
import '../contacts/contacts_screen.dart';
import '../history/history_screen.dart';
import '../profile/profile_screen.dart';

class MainNavigationScreen extends ConsumerStatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  ConsumerState<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends ConsumerState<MainNavigationScreen> {
  int _selectedIndex = 0;

  final List<Widget> _pages = const [
    HomeScreen(),
    ContactsScreen(),
    HistoryScreen(),
    ProfileScreen(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await ref.read(callProvider.notifier).connectSignaling();
      } catch (e) {
        debugPrint('⚠️ [MainNavigationScreen] Failed to connect signaling: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Automatically open CallScreen when an incoming call arrives
    ref.listen<ActiveCallState>(callProvider, (previous, next) {
      if (previous?.callState != CallState.ringing &&
          next.callState == CallState.ringing &&
          next.activeCall?.direction == CallDirection.incoming) {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CallScreen()),
        );
      }
    });

    // Reconnect/disconnect signaling when authentication state changes
    ref.listen(currentUserProvider, (previous, next) {
      if (next == null) {
        ref.read(callProvider.notifier).disconnectSignaling();
      } else if (previous?.uid != next.uid) {
        ref.read(callProvider.notifier).connectSignaling();
      }
    });

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_rounded),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.contacts_rounded),
            label: 'Contacts',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history_rounded),
            label: 'Calls',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_rounded),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
