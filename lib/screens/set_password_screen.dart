import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/dev_env.dart';
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

  static String get _loginUrl =>
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod${devPath('/member/login')}';

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _passwordCtrl.text.trim();
    final confirm  = _confirmCtrl.text.trim();

    if (password.isEmpty || confirm.isEmpty) {
      setState(() => _error = 'Please fill in both fields.');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'Passwords do not match.');
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
        setState(() { _loading = false; _success = true; });
      } else if (res.statusCode == 409) {
        setState(() {
          _loading = false;
          _error = 'A password is already set for this account. Please log in normally.';
        });
      } else if (res.statusCode == 410) {
        setState(() {
          _loading = false;
          _error = 'This setup link has expired. Use the login screen to request a new one.';
        });
      } else if (res.statusCode == 401) {
        setState(() {
          _loading = false;
          _error = 'Invalid setup link. Please use the link from your email or request a new one.';
        });
      } else {
        setState(() {
          _loading = false;
          _error = data['error'] ?? 'Something went wrong. Please try again.';
        });
      }
    } catch (_) {
      setState(() {
        _loading = false;
        _error = 'Connection error. Please check your internet and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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

                if (_success) ...[
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
                        const Text('Password Created!',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                                color: Color(0xFF1A5C2A))),
                        const SizedBox(height: 8),
                        const Text('Your account is ready. You can now log in.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.black54)),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () => Navigator.of(context).pushReplacement(
                              MaterialPageRoute(builder: (_) => const MemberLoginScreen()),
                            ),
                            child: const Text('Go to Login'),
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
                        const Text('Create Your Password',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                                color: Color(0xFF1A5C2A))),
                        const SizedBox(height: 24),

                        TextField(
                          controller: _passwordCtrl,
                          obscureText: _obscure1,
                          decoration: InputDecoration(
                            labelText: 'New Password',
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
                            labelText: 'Confirm Password',
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
                                : const Text('Create Password',
                                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
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
