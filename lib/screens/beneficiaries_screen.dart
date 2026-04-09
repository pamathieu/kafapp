import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Beneficiaries screen — list + add/edit form
//  GET  /member/beneficiaries?memberId=X  → {beneficiaries: [...]}
//  POST /member/beneficiaries             → {beneficiaryId: "BENEF#..."}
// ─────────────────────────────────────────────────────────────────────────────

const _green = Color(0xFF1A5C2A);
const _gold  = Color(0xFFC8A96E);
const _bg    = Color(0xFFF2F4F7);

class BeneficiariesScreen extends StatefulWidget {
  final String memberId;
  final String policyNo;

  const BeneficiariesScreen({
    super.key,
    required this.memberId,
    required this.policyNo,
  });

  @override
  State<BeneficiariesScreen> createState() => _BeneficiariesScreenState();
}

class _BeneficiariesScreenState extends State<BeneficiariesScreen> {
  static const _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  List<Map<String, dynamic>> _beneficiaries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final uri = Uri.parse(
          '$_baseUrl/member/beneficiaries?memberId=${Uri.encodeComponent(widget.memberId)}');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        setState(() {
          _beneficiaries =
              List<Map<String, dynamic>>.from(data['beneficiaries'] ?? []);
          _loading = false;
        });
      } else {
        setState(() { _error = 'HTTP ${response.statusCode}'; _loading = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ── Show add/edit form ────────────────────────────────────────────────────

  Future<void> _showForm({Map<String, dynamic>? existing}) async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    final nameCtrl         = TextEditingController(text: existing?['name'] as String? ?? '');
    final relationshipCtrl = TextEditingController(text: existing?['relationship'] as String? ?? '');
    final shareCtrl        = TextEditingController(
        text: existing?['sharePercent']?.toString() ?? '');

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(existing == null ? Icons.person_add : Icons.edit,
                  color: _green),
              const SizedBox(width: 10),
              Text(
                existing == null ? s('addBeneficiary') : s('editBeneficiary'),
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ]),
            const SizedBox(height: 20),
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                labelText: s('beneficiaryName'),
                prefixIcon: const Icon(Icons.person_outline),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: relationshipCtrl,
              decoration: InputDecoration(
                labelText: s('beneficiaryRelationship'),
                prefixIcon: const Icon(Icons.family_restroom),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: shareCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: s('beneficiaryShare'),
                prefixIcon: const Icon(Icons.pie_chart_outline),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(s('cancel')),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _green,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () async {
                    final name  = nameCtrl.text.trim();
                    final rel   = relationshipCtrl.text.trim();
                    final share = int.tryParse(shareCtrl.text.trim());

                    if (name.isEmpty) {
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content: Text(s('beneficiaryNameRequired')),
                          backgroundColor: Colors.red.shade700));
                      return;
                    }
                    if (rel.isEmpty) {
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content: Text(s('beneficiaryRelationshipRequired')),
                          backgroundColor: Colors.red.shade700));
                      return;
                    }
                    if (share == null || share < 1 || share > 100) {
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content: Text(s('beneficiaryShareRequired')),
                          backgroundColor: Colors.red.shade700));
                      return;
                    }
                    Navigator.pop(ctx, true);
                    await _save(
                      id:           existing?['beneficiaryId'] as String?,
                      name:         name,
                      relationship: rel,
                      sharePercent: share,
                    );
                  },
                  child: Text(s('saveBeneficiary')),
                ),
              ),
            ]),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
  }

  // ── Save to backend ───────────────────────────────────────────────────────

  Future<void> _save({
    String? id,
    required String name,
    required String relationship,
    required int sharePercent,
  }) async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    try {
      final body = json.encode({
        'memberId':      widget.memberId,
        'policyNo':      widget.policyNo,
        if (id != null) 'beneficiaryId': id,
        'name':          name,
        'relationship':  relationship,
        'sharePercent':  sharePercent,
      });
      final response = await http.post(
        Uri.parse('$_baseUrl/member/beneficiaries'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      if (!mounted) return;
      if (response.statusCode == 200 || response.statusCode == 201) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(s('beneficiarySaved')),
            backgroundColor: Colors.green.shade700));
        _load();
      } else {
        final data = json.decode(response.body);
        throw Exception(data['error'] ?? 'Save failed');
      }
    } catch (e) {
      if (!mounted) return;
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
        title: Text(s('editBeneficiaries'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _green,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showForm(),
        backgroundColor: _green,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add),
        label: Text(s('addBeneficiary')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _green))
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  color: _green,
                  child: _beneficiaries.isEmpty
                      ? _EmptyView(locale: locale)
                      : _BeneficiaryList(
                          beneficiaries: _beneficiaries,
                          locale: locale,
                          onEdit: (b) => _showForm(existing: b),
                        ),
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Beneficiary list
// ─────────────────────────────────────────────────────────────────────────────

class _BeneficiaryList extends StatelessWidget {
  final List<Map<String, dynamic>> beneficiaries;
  final String locale;
  final void Function(Map<String, dynamic>) onEdit;

  const _BeneficiaryList({
    required this.beneficiaries,
    required this.locale,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);
    final total = beneficiaries.fold<int>(
        0, (sum, b) => sum + ((b['sharePercent'] as num?)?.toInt() ?? 0));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 100),
      children: [
        // Share total indicator
        Container(
          padding: const EdgeInsets.all(14),
          margin: const EdgeInsets.only(bottom: 16),
          decoration: BoxDecoration(
            color: total == 100
                ? const Color(0xFFE8F5E9)
                : const Color(0xFFFFF3CD),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(children: [
            Icon(
              total == 100 ? Icons.check_circle : Icons.warning_amber_rounded,
              color: total == 100 ? Colors.green.shade700 : Colors.orange,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                total == 100
                    ? 'Total: 100%'
                    : '${s('totalShareWarning')} (${s('sharePercent')}: $total%)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: total == 100
                      ? Colors.green.shade800
                      : Colors.orange.shade900,
                ),
              ),
            ),
          ]),
        ),

        ...beneficiaries.map((b) => _BeneficiaryCard(
              data: b,
              locale: locale,
              onEdit: () => onEdit(b),
            )),
      ],
    );
  }
}

class _BeneficiaryCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final String locale;
  final VoidCallback onEdit;

  const _BeneficiaryCard({
    required this.data,
    required this.locale,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);
    final name         = data['name']         as String? ?? '—';
    final relationship = data['relationship'] as String? ?? '—';
    final share        = data['sharePercent'];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: _green.withValues(alpha: 0.1),
          child: const Icon(Icons.person, color: _green, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 2),
            Text(relationship,
                style: TextStyle(
                    fontSize: 13, color: Colors.grey.shade600)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              share != null ? '$share%' : '—',
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: Color(0xFF8B6914)),
            ),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: onEdit,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.edit_outlined, size: 14, color: _green),
              const SizedBox(width: 4),
              Text(s('editBeneficiary'),
                  style: const TextStyle(
                      fontSize: 12,
                      color: _green,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
        ]),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Empty / error views
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyView extends StatelessWidget {
  final String locale;
  const _EmptyView({required this.locale});

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.people_outline, size: 64, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Text(s('noBeneficiaries'),
            style: TextStyle(color: Colors.grey.shade600, fontSize: 15)),
        const SizedBox(height: 8),
        Text(s('addBeneficiary'),
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
      ]),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline, color: Colors.red.shade400, size: 48),
          const SizedBox(height: 12),
          Text(error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(backgroundColor: _green, foregroundColor: Colors.white),
              child: const Text('Retry')),
        ]),
      );
}
