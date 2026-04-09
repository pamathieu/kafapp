import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Express Enrollment screen
//  POST /member/enrollment → 200/201 OK
//  Pre-fills known member data; lets member choose a plan and confirm.
// ─────────────────────────────────────────────────────────────────────────────

const _green = Color(0xFF1A5C2A);
const _bg    = Color(0xFFF2F4F7);

const _plans = ['BASIC', 'PLUS', 'PREMIUM'];

class EnrollmentFormScreen extends StatefulWidget {
  final String memberId;
  final String memberName;
  final String? phone;
  final String? email;

  const EnrollmentFormScreen({
    super.key,
    required this.memberId,
    required this.memberName,
    this.phone,
    this.email,
  });

  @override
  State<EnrollmentFormScreen> createState() => _EnrollmentFormScreenState();
}

class _EnrollmentFormScreenState extends State<EnrollmentFormScreen> {
  static const _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  final _nameCtrl    = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _addressCtrl = TextEditingController();

  String _selectedPlan = _plans.first;
  bool _submitting = false;
  bool _submitted  = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl.text  = widget.memberName;
    _phoneCtrl.text = widget.phone  ?? '';
    _emailCtrl.text = widget.email  ?? '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    if (_nameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s('beneficiaryNameRequired')),
          backgroundColor: Colors.red.shade700));
      return;
    }

    setState(() => _submitting = true);
    try {
      final body = json.encode({
        'memberId': widget.memberId,
        'name':     _nameCtrl.text.trim(),
        'phone':    _phoneCtrl.text.trim(),
        'email':    _emailCtrl.text.trim(),
        'address':  _addressCtrl.text.trim(),
        'plan':     _selectedPlan,
      });
      final response = await http.post(
        Uri.parse('$_baseUrl/member/enrollment'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      if (!mounted) return;
      if (response.statusCode == 200 || response.statusCode == 201) {
        setState(() { _submitted = true; _submitting = false; });
      } else {
        Map<String, dynamic> data = {};
        try { data = json.decode(response.body) as Map<String, dynamic>; } catch (_) {}
        throw Exception(data['error'] ?? 'HTTP ${response.statusCode}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: Colors.red.shade700));
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Text(s('enrollmentTitle'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _green,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _submitted
          ? _SuccessView(locale: locale)
          : _buildForm(s),
    );
  }

  Widget _buildForm(String Function(String) s) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Info banner
        Container(
          padding: const EdgeInsets.all(14),
          margin: const EdgeInsets.only(bottom: 24),
          decoration: BoxDecoration(
            color: _green.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _green.withValues(alpha: 0.2)),
          ),
          child: Row(children: [
            const Icon(Icons.info_outline, color: _green, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                s('enrollmentNote'),
                style: const TextStyle(
                    fontSize: 13,
                    color: _green,
                    fontWeight: FontWeight.w500),
              ),
            ),
          ]),
        ),

        _label(s('fullName')),
        TextField(
          controller: _nameCtrl,
          decoration: _inputDeco(Icons.person_outline),
        ),
        const SizedBox(height: 14),

        _label(s('phone')),
        TextField(
          controller: _phoneCtrl,
          keyboardType: TextInputType.phone,
          decoration: _inputDeco(Icons.phone_outlined),
        ),
        const SizedBox(height: 14),

        _label(s('email')),
        TextField(
          controller: _emailCtrl,
          keyboardType: TextInputType.emailAddress,
          decoration: _inputDeco(Icons.email_outlined),
        ),
        const SizedBox(height: 14),

        _label(s('address')),
        TextField(
          controller: _addressCtrl,
          decoration: _inputDeco(Icons.home_outlined),
        ),
        const SizedBox(height: 14),

        _label(s('selectPlan')),
        DropdownButtonFormField<String>(
          initialValue: _selectedPlan,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.shield_outlined),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            filled: true,
            fillColor: Colors.white,
          ),
          items: _plans.map((p) {
            final label = switch (p) {
              'BASIC'   => 'Basique — HTG 250/mois',
              'PLUS'    => 'Plus — HTG 450/mois',
              'PREMIUM' => 'Premium — HTG 750/mois',
              _         => p,
            };
            return DropdownMenuItem(value: p, child: Text(label));
          }).toList(),
          onChanged: (v) => setState(() => _selectedPlan = v ?? _selectedPlan),
        ),
        const SizedBox(height: 28),

        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _green,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : Text(s('enrollmentSubmit'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ]),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700)),
      );

  InputDecoration _inputDeco(IconData icon) => InputDecoration(
        prefixIcon: Icon(icon),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        filled: true,
        fillColor: Colors.white,
      );
}

// ─────────────────────────────────────────────────────────────────────────────

class _SuccessView extends StatelessWidget {
  final String locale;
  const _SuccessView({required this.locale});

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle_outline,
              color: Color(0xFF1A5C2A), size: 72),
          const SizedBox(height: 20),
          Text(s('enrollmentSent'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 28),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A5C2A),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s('ok')),
          ),
        ]),
      ),
    );
  }
}
