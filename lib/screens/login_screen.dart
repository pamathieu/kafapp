import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import 'members_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _errorMessage;

  Future<void> _login() async {
    setState(() {
      _isLoading    = true;
      _errorMessage = null;
    });

    final auth    = context.read<AuthProvider>();
    final success = await auth.login(
      _usernameController.text.trim(),
      _passwordController.text,
    );

    if (!mounted) return;

    if (success) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const MembersScreen()),
      );
    } else {
      setState(() {
        _isLoading    = false;
        _errorMessage = auth.errorMessage;
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final langProvider = context.watch<LanguageProvider>();
    final locale = langProvider.locale;
    String s(String key) => AppStrings.get(key, locale);

    return Scaffold(
      backgroundColor: const Color(0xFF1A5C2A),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Language dropdown
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    PopupMenuButton<String>(
                      offset: const Offset(0, 40),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      onSelected: (code) =>
                          context.read<LanguageProvider>().setLocale(code),
                      itemBuilder: (_) => LanguageProvider.supportedLanguages
                          .map((lang) => PopupMenuItem<String>(
                                value: lang['code'],
                                child: Row(children: [
                                  Text(lang['label']!,
                                      style: TextStyle(
                                          fontWeight: lang['code'] == locale
                                              ? FontWeight.bold
                                              : FontWeight.normal)),
                                  if (lang['code'] == locale) ...[
                                    const Spacer(),
                                    const Icon(Icons.check,
                                        size: 16,
                                        color: Color(0xFF1A5C2A)),
                                  ],
                                ]),
                              ))
                          .toList(),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.language,
                              color: Colors.white70, size: 18),
                          const SizedBox(width: 4),
                          Text(
                            LanguageProvider.supportedLanguages
                                .firstWhere((l) => l['code'] == locale,
                                    orElse: () =>
                                        LanguageProvider.supportedLanguages
                                            .first)['label']!
                                .split(' ')
                                .first,
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 13),
                          ),
                          const Icon(Icons.arrow_drop_down,
                              color: Colors.white70, size: 18),
                        ]),
                      ),
                    ),
                  ],
                ),

                // KAFA Logo
                Image.asset(
                  'images/kafa_logo.png',
                  width: 150,
                  height: 150,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => Container(
                    width: 150,
                    height: 150,
                    decoration: BoxDecoration(
                      color: const Color(0xFFC8A96E),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.shield, color: Colors.white, size: 64),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'KAFA',
                  style: TextStyle(
                    color: Color(0xFFC8A96E),
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  s('appSubtitle'),
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                ),
                const SizedBox(height: 48),

                // Login card
                Card(
                  elevation: 8,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          s('adminLogin'),
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.bold),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),

                        // Username
                        TextField(
                          controller: _usernameController,
                          decoration: InputDecoration(
                            labelText: s('username'),
                            prefixIcon: const Icon(Icons.person_outline),
                          ),
                          onSubmitted: (_) => _login(),
                        ),
                        const SizedBox(height: 16),

                        // Password
                        TextField(
                          controller: _passwordController,
                          obscureText: _obscurePassword,
                          decoration: InputDecoration(
                            labelText: s('password'),
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              icon: Icon(_obscurePassword
                                  ? Icons.visibility_off
                                  : Icons.visibility),
                              onPressed: () => setState(
                                  () => _obscurePassword = !_obscurePassword),
                            ),
                          ),
                          onSubmitted: (_) => _login(),
                        ),

                        if (_errorMessage != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.red.shade200),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.error_outline,
                                    color: Colors.red, size: 18),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(_errorMessage!,
                                      style: const TextStyle(
                                          color: Colors.red, fontSize: 13)),
                                ),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: _isLoading ? null : _login,
                          child: _isLoading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : Text(s('login'),
                                  style: const TextStyle(fontSize: 16)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
