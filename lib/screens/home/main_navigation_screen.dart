import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_constants.dart';
import '../../providers/auth_provider.dart';
import '../../providers/call_provider.dart';
import '../../services/signaling_service.dart';
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

class _MainNavigationScreenState extends ConsumerState<MainNavigationScreen>
    with WidgetsBindingObserver {
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
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await ref.read(callProvider.notifier).connectSignaling();
      } catch (e) {
        debugPrint('⚠️ [MainNavigationScreen] Failed to connect signaling: $e');
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Reconnect signaling automatically when user unlocks screen or returns to app
    if (state == AppLifecycleState.resumed) {
      debugPrint('📱 [MainNavigationScreen] App resumed. Ensuring signaling connection...');
      ref.read(callProvider.notifier).connectSignaling();
    }
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

    // Watch live signaling connection state
    final liveState = ref.watch(signalingConnectionStateProvider).value ??
        ref.watch(signalingServiceProvider).connectionState;

    final isConnecting = liveState == SignalingConnectionState.connecting ||
        liveState == SignalingConnectionState.authenticating;
    final isDisconnected = liveState == SignalingConnectionState.disconnected ||
        liveState == SignalingConnectionState.error;

    return Scaffold(
      body: Column(
        children: [
          // Connection status banner when waking up Render or reconnecting
          if (isConnecting || isDisconnected)
            SafeArea(
              bottom: false,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: isConnecting
                    ? AppColors.primary.withValues(alpha: 0.2)
                    : AppColors.callRed.withValues(alpha: 0.2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: isConnecting
                          ? const CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(AppColors.primaryLight),
                            )
                          : const Icon(
                              Icons.wifi_off_rounded,
                              size: 14,
                              color: AppColors.callRed,
                            ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isConnecting
                            ? 'Connecting to call server...'
                            : 'Call server disconnected.',
                        style: TextStyle(
                          fontSize: 12,
                          color: isConnecting ? AppColors.primaryLight : AppColors.callRed,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (isDisconnected)
                      GestureDetector(
                        onTap: () {
                          ref.read(callProvider.notifier).connectSignaling();
                        },
                        child: const Text(
                          'Retry',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.primaryLight,
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: IndexedStack(
              index: _selectedIndex,
              children: _pages,
            ),
          ),
        ],
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
