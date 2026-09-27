import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import './core/env.dart';
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
      systemNavigationBarColor: Colors.transparent, // <-- Ensure this is transparent
      systemNavigationBarContrastEnforced: false,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );


  await Supabase.initialize(
    url: Env.supabaseUrl,
    anonKey: Env.supabaseAnonKey,
  );

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tumaini Investments',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF6F8F5),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B4A43),
          primary: const Color(0xFF0B4A43),
          surface: Colors.white,
        ),
      ),
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
    );
  }
}