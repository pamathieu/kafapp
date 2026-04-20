import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/language_provider.dart';
import 'screens/login_screen.dart';
import 'screens/member_login_screen.dart';

// Determined at build time:
//   Admin portal:  flutter build web --dart-define=PORTAL=admin
//   Member portal: flutter build web --dart-define=PORTAL=member
const _portal = String.fromEnvironment('PORTAL', defaultValue: 'admin');

// Stripe publishable key — use pk_test_... for development, pk_live_... for production.
// Set via --dart-define=STRIPE_KEY=pk_test_... at build time, or replace directly for local dev.
const _stripeKey = String.fromEnvironment(
  'STRIPE_KEY',
  defaultValue: 'pk_test_REPLACE_ME',
);

void main() async {
  // Set up error handling for uncaught exceptions
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrintStack(
      stackTrace: details.stack,
      label: 'Flutter Error: ${details.exception}',
    );
  };

  WidgetsFlutterBinding.ensureInitialized();

  // flutter_stripe registers a web MutationObserver at startup that reads
  // Stripe.publishableKey (a late String). It must be set before runApp or
  // the first render throws LateInitializationError → blank screen on web.
  // We always assign it; payment screens validate it's a real key at tap time.
  try {
    final hasRealKey = _stripeKey.isNotEmpty && !_stripeKey.contains('REPLACE_ME');
    Stripe.publishableKey = hasRealKey ? _stripeKey : '';
    if (hasRealKey) {
      try {
        await Stripe.instance.applySettings();
      } catch (e) {
        debugPrint('[Stripe] applySettings failed: $e');
      }
    }
  } catch (e) {
    debugPrint('[Stripe] initialization failed: $e');
    // Continue anyway, payment will fail at tap time if key is invalid
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => LanguageProvider()),
      ],
      child: const KAFAMemberApp(),
    ),
  );
}

class KAFAMemberApp extends StatelessWidget {
  const KAFAMemberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: _portal == 'member' ? 'KAFA Member Portal' : 'KAFA Admin',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFC8A96E),
          primary: const Color(0xFFC8A96E),
          secondary: const Color(0xFF1A5C2A),
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1A5C2A),
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFC8A96E),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFC8A96E), width: 2),
          ),
        ),
      ),
      home: _portal == 'member'
          ? const MemberLoginScreen()
          : const LoginScreen(),
    );
  }
}