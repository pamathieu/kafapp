import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../services/dev_env.dart';
import '../services/session_service.dart';
import '../widgets/reset_password_dialog.dart';
import 'member_dashboard_screen.dart';
import 'member_login_screen.dart';

class SetPasswordScreen extends StatefulWidget {
  final String token;
  const SetPasswordScreen({super.key, required this.token});

  @override
  State<SetPasswordScreen> createState() => _SetPasswordScreenState();
}

class _SetPasswordScreenState extends State<SetPasswordScreen> {
  final _passwordCtrl = TextEditingController();
  final _confirmCtrl  = TextEditingController();
  bool   _loading     = false;
  bool   _obscure1    = true;
  bool   _obscure2    = true;
  String? _error;
  bool   _success     = false;

  bool _checkingLink = true;
  bool _linkBlocked  = false;
  // Resolved while the (possibly expired) token still traced back to its
  // owner, so "request new password" stays scoped to this member even
  // after that token itself gets rotated away by a later request.
  String? _linkOwnerMemberId;

  static String get _loginUrl => '$kApiBaseUrl${devPath('/member/login')}';

  @override
  void initState() {
    super.initState();
    _checkLinkValidity();
  }

  Future<void> _checkLinkValidity() async {
    try {
      final res = await http.post(
        Uri.parse(_loginUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'setupToken': widget.token}),
      );
      if (res.statusCode == 410 || res.statusCode == 401) {
        if (!mounted) return;
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        setState(() {
          _checkingLink = false;
          _linkBlocked  = true;
          _linkOwnerMemberId = data['memberId'] as String?;
        });
        return;
      }
    } catch (_) {
      // Network hiccup during the precheck — fall through and let the form's
      // own submit still enforce validity server-side.
    }
    if (!mounted) return;
    setState(() => _checkingLink = false);
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    final password = _passwordCtrl.text.trim();
    final confirm  = _confirmCtrl.text.trim();

    if (password.isEmpty || confirm.isEmpty) {
      setState(() => _error = s('fillBothFields'));
      return;
    }
    if (password.length < 6) {
      setState(() => _error = s('passwordMinLength'));
      return;
    }
    if (password != confirm) {
      setState(() => _error = s('passwordsDoNotMatch'));
      return;
    }

    setState(() { _loading = true; _error = null; });

    try {
      final res = await http.post(
        Uri.parse(_loginUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'setupToken': widget.token, 'setupPassword': password}),
      );
      final data = jsonDecode(res.body) as Map<String, dynamic>;

      if (res.statusCode == 200) {
        final member = data['member'] as Map<String, dynamic>;
        try { await SessionService.saveSession(member); } catch (_) {}
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => MemberDashboardScreen(member: member)),
        );
        return;
      } else if (res.statusCode == 410) {
        setState(() {
          _loading = false;
          _error = s('setupLinkExpired');
        });
      } else if (res.statusCode == 401) {
        setState(() {
          _loading = false;
          _error = s('invalidSetupLink');
        });
      } else {
        setState(() {
          _loading = false;
          _error = data['error'] ?? s('somethingWentWrong');
        });
      }
    } catch (_) {
      setState(() {
        _loading = false;
        _error = s('connectionErrorCheckInternet');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final langProvider = context.watch<LanguageProvider>();
    final locale = langProvider.locale;
    String s(String key) => AppStrings.get(key, locale);

    final currentLang = LanguageProvider.supportedLanguages
        .firstWhere((l) => l['code'] == locale,
            orElse: () => LanguageProvider.supportedLanguages.first);

    final langDropdown = PopupMenuButton<String>(
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
      appBar: AppBar(
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
                  width: 100, height: 100, fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Container(
                    width: 100, height: 100,
                    decoration: BoxDecoration(
                      color: const Color(0xFFC8A96E),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.shield, color: Colors.white, size: 56),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('KAFA',
                    style: TextStyle(color: Color(0xFFC8A96E), fontSize: 28,
                        fontWeight: FontWeight.bold, letterSpacing: 4)),
                const SizedBox(height: 4),
                const Text('Koperativ Asirans Fòs Ayiti',
                    style: TextStyle(color: Colors.white60, fontSize: 13)),
                const SizedBox(height: 40),

                if (_checkingLink) ...[
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                ] else if (_linkBlocked) ...[
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red, size: 56),
                        const SizedBox(height: 16),
                        Text(s('setupLinkExpiredContactAdmin'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                                color: Color(0xFF1A5C2A))),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFF1A5C2A),
                              side: const BorderSide(color: Color(0xFF1A5C2A)),
                            ),
                            onPressed: () => showRequestNewPasswordDialog(
                              context,
                              fromExpiredLink: true,
                              scopedMemberId: _linkOwnerMemberId,
                            ),
                            child: Text(s('requestNewPasswordBtn')),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else if (_success) ...[
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.check_circle, color: Color(0xFF1A5C2A), size: 56),
                        const SizedBox(height: 16),
                        Text(s('passwordCreatedTitle'),
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                                color: Color(0xFF1A5C2A))),
                        const SizedBox(height: 8),
                        Text(s('accountReadyLogin'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.black54)),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () async {
                              await SessionService.clearSession();
                              if (!context.mounted) return;
                              Navigator.of(context).pushReplacement(
                                MaterialPageRoute(builder: (_) => const MemberLoginScreen()),
                              );
                            },
                            child: Text(s('goToLogin')),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s('createYourPassword'),
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                                color: Color(0xFF1A5C2A))),
                        const SizedBox(height: 24),

                        TextField(
                          controller: _passwordCtrl,
                          obscureText: _obscure1,
                          decoration: InputDecoration(
                            labelText: s('newPassword'),
                            suffixIcon: IconButton(
                              icon: Icon(_obscure1 ? Icons.visibility : Icons.visibility_off),
                              onPressed: () => setState(() => _obscure1 = !_obscure1),
                            ),
                          ),
                          onSubmitted: (_) => _submit(),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _confirmCtrl,
                          obscureText: _obscure2,
                          decoration: InputDecoration(
                            labelText: s('confirmPassword'),
                            suffixIcon: IconButton(
                              icon: Icon(_obscure2 ? Icons.visibility : Icons.visibility_off),
                              onPressed: () => setState(() => _obscure2 = !_obscure2),
                            ),
                          ),
                          onSubmitted: (_) => _submit(),
                        ),

                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(_error!,
                              style: const TextStyle(color: Colors.red, fontSize: 13)),
                        ],

                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _loading ? null : _submit,
                            child: _loading
                                ? const SizedBox(width: 20, height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : Text(s('createPasswordBtn'),
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
