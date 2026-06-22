import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'providers/language_provider.dart';
import 'screens/login_screen.dart';
import 'screens/member_login_screen.dart';
import 'screens/set_password_screen.dart';
import 'screens/admin_dashboard_screen.dart';

const _portal = String.fromEnvironment('PORTAL', defaultValue: 'admin');

const _stripeKey = String.fromEnvironment(
  'STRIPE_KEY',
  defaultValue: 'pk_test_REPLACE_ME',
);

void main() async {
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrintStack(
      stackTrace: details.stack,
      label: 'Flutter Error: ${details.exception}',
    );
  };

  WidgetsFlutterBinding.ensureInitialized();

  final hasRealKey = _stripeKey.isNotEmpty && !_stripeKey.contains('REPLACE_ME');
  if (hasRealKey) {
    try {
      Stripe.publishableKey = _stripeKey;
      if (!kIsWeb) await Stripe.instance.applySettings();
    } catch (_) {}
  }

  // Restore session before the UI is shown so the correct screen renders first.
  final authProvider = AuthProvider();
  final hasSession   = await authProvider.tryRestoreSession();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: authProvider),
        ChangeNotifierProvider(create: (_) => LanguageProvider()),
      ],
      child: KAFAMemberApp(hasSession: hasSession),
    ),
  );
}

class KAFAMemberApp extends StatelessWidget {
  final bool hasSession;
  const KAFAMemberApp({super.key, required this.hasSession});

  @override
  Widget build(BuildContext context) {
    Widget home;
    if (_portal == 'member') {
      final setupToken = kIsWeb ? Uri.base.queryParameters['setup'] : null;
      home = (setupToken != null && setupToken.isNotEmpty)
          ? SetPasswordScreen(token: setupToken)
          : const MemberLoginScreen();
    } else if (hasSession) {
      home = const AdminDashboardScreen();
    } else {
      home = const LoginScreen();
    }

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
      home: home,
    );
  }
}
