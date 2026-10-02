import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import './appPrefs.dart';
import './core/env.dart';
import './services/updater.dart';
import './screens/admin/home.dart';
import './screens/employer/home.dart';
import './screens/forgotPassword.dart';
import './screens/login.dart';
import './screens/signup.dart';
import './screens/splashScreen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Draw behind the status/nav bars...
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // ...and make sure Android doesn't paint a black contrast scrim behind
  // the gesture nav bar.

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor:
          Colors.transparent, // <-- Ensure this is transparent
      systemNavigationBarContrastEnforced: false,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  await Supabase.initialize(url: Env.supabaseUrl, anonKey: Env.supabaseAnonKey);

  await EmpPrefs.applySavedAppearance();

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
  }

  Future<void> _checkForUpdate() async {
    if (!(Platform.isWindows || Platform.isAndroid)) return;

    try {
      final update = await Updater.check();
      if (update == null || !mounted) return;

      final install = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Update available'),
          content: Text('Version ${update['version']} is ready to install.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Update now'),
            ),
          ],
        ),
      );

      if (install == true) await Updater.install(update);
    } catch (_) {
      // Updates are optional and may be unavailable while offline.
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (_, mode, _) => MaterialApp(
        title: 'Tumaini Investments',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          scaffoldBackgroundColor: const Color(0xFFF7F9FF),
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF143D9E),
            primary: const Color(0xFF143D9E),
            surface: Colors.white,
          ),
        ),
        darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF143D9E),
            primary: const Color(0xFF9DB8FF),
            brightness: Brightness.dark,
          ),
        ),
        themeMode: mode,
        initialRoute: '/',
        routes: {
          // SplashScreen decides where to go on its own (session + role check)
          '/': (context) => const SplashScreen(),
          '/login': (context) => const LoginScreen(),
          '/signup': (context) => const SignupScreen(),
          '/forgot-password': (context) => const ForgotPasswordScreen(),
          '/home': (context) => const EmployeeHomeRoute(),
          '/admin-home': (context) => const AdminHomeRoute(),
        },
      ),
    );
  }
}
