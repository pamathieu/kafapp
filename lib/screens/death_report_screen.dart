import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Death Emergency / Death Report screen
//  POST /member/death-report → 200 OK (triggers SES email to KAFA admin)
// ─────────────────────────────────────────────────────────────────────────────

const _green = Color(0xFF1A5C2A);
const _red   = Color(0xFFB71C1C);
const _bg    = Color(0xFFF2F4F7);

const _relationships = [
  'Conjoint(e)',
  'Enfant',
  'Parent',
  'Frère / Sœur',
  'Autre membre de la famille',
  'Représentant légal',
  'Autre',
];

class DeathReportScreen extends StatefulWidget {
  final String memberId;
  final String memberName;
  final String policyNo;

  const DeathReportScreen({
    super.key,
    required this.memberId,
    required this.memberName,
    required this.policyNo,
  });

  @override
  State<DeathReportScreen> createState() => _DeathReportScreenState();
}

class _DeathReportScreenState extends State<DeathReportScreen> {
  static const _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  final _declarantNameCtrl  = TextEditingController();
  final _declarantPhoneCtrl = TextEditingController();
  final _notesCtrl          = TextEditingController();

  DateTime? _dateOfDeath;
  String _relationship = _relationships.first;
  bool _submitting = false;
  bool _submitted = false;

  @override
  void dispose() {
    _declarantNameCtrl.dispose();
    _declarantPhoneCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(primary: _green),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _dateOfDeath = picked);
  }

  Future<void> _submit() async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    if (_dateOfDeath == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${s('dateOfDeath')} requis.'),
          backgroundColor: Colors.red.shade700));
      return;
    }
    if (_declarantNameCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(s('beneficiaryNameRequired')),
          backgroundColor: Colors.red.shade700));
      return;
    }

    setState(() => _submitting = true);
    try {
      final body = json.encode({
        'memberId':         widget.memberId,
        'memberName':       widget.memberName,
        'policyNo':         widget.policyNo,
        'dateOfDeath':      _dateOfDeath!.toIso8601String().split('T').first,
        'declarantName':    _declarantNameCtrl.text.trim(),
        'declarantPhone':   _declarantPhoneCtrl.text.trim(),
        'relationship':     _relationship,
        'notes':            _notesCtrl.text.trim(),
      });
      final response = await http.post(
        Uri.parse('$_baseUrl/member/death-report'),
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
          content: Text('${s('deathReportError')}: $e'),
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
        title: Text(s('deathReportTitle'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _red,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: _submitted ? _SuccessView(locale: locale) : _buildForm(s, locale),
    );
  }

  Widget _buildForm(String Function(String) s, String locale) {
    final dateStr = _dateOfDeath == null
        ? s('dateOfDeath')
        : AppStrings.formatDate(
            _dateOfDeath!.toIso8601String().split('T').first, locale);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Warning banner
        Container(
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 24),
          decoration: BoxDecoration(
            color: const Color(0xFFFFEBEE),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _red.withValues(alpha: 0.3)),
          ),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, color: _red, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                s('deathReportSubtitle'),
                style: const TextStyle(
                    color: _red, fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ),
          ]),
        ),

        // Policy info (read-only)
        _InfoRow(label: 'Assuré', value: widget.memberName),
        _InfoRow(label: 'Numéro de police', value: widget.policyNo),
        const SizedBox(height: 20),

        // Date of death picker
        GestureDetector(
          onTap: _pickDate,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade400),
            ),
            child: Row(children: [
              Icon(Icons.calendar_today_outlined,
                  color: _dateOfDeath == null ? Colors.grey : _red, size: 20),
              const SizedBox(width: 12),
              Text(
                dateStr,
                style: TextStyle(
                    fontSize: 15,
                    color: _dateOfDeath == null
                        ? Colors.grey.shade600
                        : Colors.black87),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 14),

        // Relationship dropdown
        DropdownButtonFormField<String>(
          initialValue: _relationship,
          decoration: InputDecoration(
            labelText: s('declarantRelationship'),
            prefixIcon: const Icon(Icons.family_restroom),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            filled: true,
            fillColor: Colors.white,
          ),
          items: _relationships
              .map((r) => DropdownMenuItem(value: r, child: Text(r)))
              .toList(),
          onChanged: (v) => setState(() => _relationship = v ?? _relationship),
        ),
        const SizedBox(height: 14),

        // Declarant name
        TextField(
          controller: _declarantNameCtrl,
          decoration: InputDecoration(
            labelText: '${s('fullName')} (déclarant)',
            prefixIcon: const Icon(Icons.person_outline),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            filled: true,
            fillColor: Colors.white,
          ),
        ),
        const SizedBox(height: 14),

        // Declarant phone
        TextField(
          controller: _declarantPhoneCtrl,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: '${s('phone')} (déclarant)',
            prefixIcon: const Icon(Icons.phone_outlined),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            filled: true,
            fillColor: Colors.white,
          ),
        ),
        const SizedBox(height: 14),

        // Notes
        TextField(
          controller: _notesCtrl,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: s('notes'),
            prefixIcon: const Icon(Icons.notes),
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            filled: true,
            fillColor: Colors.white,
          ),
        ),
        const SizedBox(height: 28),

        // Submit button
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _red,
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
                : Text(s('reportDeathConfirm'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          Text('$label: ',
              style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w600)),
          Text(value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        ]),
      );
}

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
          Text(s('deathReportSent'),
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
