import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../services/session_service.dart';
import 'member_dashboard_screen.dart';

class MemberLoginScreen extends StatefulWidget {
  const MemberLoginScreen({super.key});

  @override
  State<MemberLoginScreen> createState() => _MemberLoginScreenState();
}

class _MemberLoginScreenState extends State<MemberLoginScreen> {
  final _identifierCtrl = TextEditingController();
  final _passwordCtrl   = TextEditingController();
  bool _obscurePassword = true;
  bool _isLoading       = true; // true initially while checking saved session
  String? _errorMessage;

  static const String _loginUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod/member/login';

  @override
  void initState() {
    super.initState();
    _checkSavedSession();
  }

  Future<void> _checkSavedSession() async {
    try {
      final saved = await SessionService.loadSession();
      if (!mounted) return;
      if (saved != null) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => MemberDashboardScreen(member: saved)),
        );
        return;
      }
    } catch (_) {
      // If anything goes wrong reading storage, just show the login form
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _login() async {
    final identifier = _identifierCtrl.text.trim();
    final password   = _passwordCtrl.text;

    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);

    if (identifier.isEmpty || password.isEmpty) {
      setState(() => _errorMessage = s('loginErrorEmpty'));
      return;
    }

    setState(() { _isLoading = true; _errorMessage = null; });

    try {
      final response = await http.post(
        Uri.parse(_loginUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'identifier': identifier, 'password': password}),
      );

      if (!mounted) return;

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        final member = data['member'] as Map<String, dynamic>;
        try { await SessionService.saveSession(member); } catch (_) {}
        if (!mounted) return;
        setState(() => _isLoading = false);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
              builder: (_) => MemberDashboardScreen(member: member)),
        );
      } else {
        setState(() {
          _errorMessage = data['error'] ?? s('loginErrorInvalid');
          _isLoading    = false;
        });
      }
    } catch (e) {
      setState(() {
        _errorMessage = s('loginErrorConnection');
        _isLoading    = false;
      });
    }
  }

  @override
  void dispose() {
    _identifierCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Show splash while checking for a saved session
    if (_isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFF1A5C2A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFFC8A96E)),
        ),
      );
    }

    final langProvider = context.watch<LanguageProvider>();
    final locale = langProvider.locale;
    String s(String key) => AppStrings.get(key, locale);

    final canPop = Navigator.of(context).canPop();
    final currentLang = LanguageProvider.supportedLanguages
        .firstWhere((l) => l['code'] == locale,
            orElse: () => LanguageProvider.supportedLanguages.first);

    Widget langDropdown = PopupMenuButton<String>(
      offset: const Offset(0, 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (code) => context.read<LanguageProvider>().setLocale(code),
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
                    const Icon(Icons.check, size: 16, color: Color(0xFF1A5C2A)),
                  ],
                ]),
              ))
          .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.language, color: Colors.white70, size: 18),
          const SizedBox(width: 4),
          Text(currentLang['label']!.split(' ').first,
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const Icon(Icons.arrow_drop_down, color: Colors.white70, size: 18),
        ]),
      ),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF1A5C2A),
      appBar: canPop ? AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [langDropdown],
      ) : AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [langDropdown],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/images/kafa_logo.png',
                  width: 100,
                  height: 100,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: const Color(0xFFC8A96E),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(Icons.shield, color: Colors.white, size: 54),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('KAFA',
                    style: TextStyle(
                        color: Color(0xFFC8A96E),
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4)),
                const SizedBox(height: 4),
                Text(s('memberPortal'),
                    style: const TextStyle(color: Colors.white60, fontSize: 13)),
                const SizedBox(height: 40),

                Card(
                  elevation: 8,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(s('memberLogin'),
                            style: const TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center),
                        const SizedBox(height: 8),
                        Text(s('memberLoginSubtitle'),
                            style: const TextStyle(fontSize: 13, color: Colors.grey),
                            textAlign: TextAlign.center),
                        const SizedBox(height: 24),

                        TextField(
                          controller: _identifierCtrl,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(
                            labelText: s('emailOrPhone'),
                            prefixIcon: const Icon(Icons.person_outline),
                          ),
                          onSubmitted: (_) => _login(),
                        ),
                        const SizedBox(height: 16),

                        TextField(
                          controller: _passwordCtrl,
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
                            child: Row(children: [
                              const Icon(Icons.error_outline,
                                  color: Colors.red, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_errorMessage!,
                                    style: const TextStyle(
                                        color: Colors.red, fontSize: 13)),
                              ),
                            ]),
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
                                      strokeWidth: 2, color: Colors.white))
                              : Text(s('connect'),
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