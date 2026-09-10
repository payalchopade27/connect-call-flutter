import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'core/theme/app_theme.dart';
import 'screens/splash/splash_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp();
    debugPrint('[Firebase] Firebase.initializeApp() successful!');
  } catch (e) {
    debugPrint('[Firebase Configuration Required] Firebase initialization skipped or google-services.json missing: $e');
  }

  runApp(
    const ProviderScope(
      child: ConnectCallApp(),
    ),
  );
}

class ConnectCallApp extends StatelessWidget {
  const ConnectCallApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ConnectCall',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const SplashScreen(),
    );
  }
}
