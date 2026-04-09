import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import 'beneficiaries_screen.dart';

class PolicyScreen extends StatefulWidget {
  final Map<String, dynamic> member;
  final bool embedded;
  const PolicyScreen({super.key, required this.member, this.embedded = false});

  @override
  State<PolicyScreen> createState() => _PolicyScreenState();
}

class _PolicyScreenState extends State<PolicyScreen> {
  static const _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  List<Map<String, dynamic>> _policies = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPolicies();
  }

  Future<void> _loadPolicies() async {
    setState(() { _loading = true; _error = null; });
    try {
      final memberId = widget.member['memberId'] as String? ?? '';
      final uri = Uri.parse(
          '$_baseUrl/member/policy?memberId=${Uri.encodeComponent(memberId)}');
      final response = await http.get(uri);
      if (!mounted) return;
      final data = json.decode(response.body) as Map<String, dynamic>;
      setState(() {
        _policies = List<Map<String, dynamic>>.from(data['policies'] ?? []);
        _loading  = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Widget _buildBody() {
    final locale = context.watch<LanguageProvider>().locale;

    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF1A5C2A)));
    }
    if (_error != null) {
      return _ErrorView(error: _error!, onRetry: _loadPolicies);
    }
    if (_policies.isEmpty) {
      return _EmptyView(locale: locale);
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      itemCount: _policies.length,
      itemBuilder: (ctx, i) => _PolicyCard(
        data: _policies[i],
        member: widget.member,
        locale: locale,
        onRefresh: _loadPolicies,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;

    if (widget.embedded) return _buildBody();

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: Text(locale == 'fr' ? 'Mes Polices' : 'My Policies',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1A5C2A),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadPolicies,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }
}

// ── Single policy card ────────────────────────────────────────────────────────

class _PolicyCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final Map<String, dynamic> member;
  final String locale;
  final VoidCallback onRefresh;
  const _PolicyCard({
    required this.data,
    required this.member,
    required this.locale,
    required this.onRefresh,
  });

  @override
  State<_PolicyCard> createState() => _PolicyCardState();
}

class _PolicyCardState extends State<_PolicyCard> {
  static const _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  bool _payExpanded   = false;
  bool _claimExpanded = false;

  List<Map<String, dynamic>> _beneficiaries    = [];
  bool                       _loadingBenefits  = true;

  @override
  void initState() {
    super.initState();
    _loadBeneficiaries();
  }

  Future<void> _loadBeneficiaries() async {
    final memberId = widget.member['memberId'] as String? ?? '';
    if (memberId.isEmpty) { setState(() => _loadingBenefits = false); return; }
    try {
      final uri = Uri.parse(
          '$_baseUrl/member/beneficiaries?memberId=${Uri.encodeComponent(memberId)}');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        setState(() {
          _beneficiaries = List<Map<String, dynamic>>.from(
              data['beneficiaries'] as List? ?? []);
          _loadingBenefits = false;
        });
      } else {
        setState(() => _loadingBenefits = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingBenefits = false);
    }
  }

  String s(String k) => AppStrings.get(k, widget.locale);

  Map<String, dynamic> get _policy  => widget.data['policy']  as Map<String, dynamic>? ?? {};
  Map<String, dynamic> get _lastPay => widget.data['lastPay'] as Map<String, dynamic>? ?? {};
  Map<String, dynamic> get _nextSched => widget.data['nextSched'] as Map<String, dynamic>? ?? {};
  List<dynamic>        get _claims   => widget.data['claims']  as List<dynamic>? ?? [];

  // ── Make Payment ────────────────────────────────────────────────────────────

  Future<void> _showPaymentDialog() async {
    final methods = ['MOBILE_MONEY', 'BANK_TRANSFER', 'CASH'];
    String selectedMethod = 'MOBILE_MONEY';
    final amountCtrl = TextEditingController(
        text: _policy['premiumAmount']?.toString() ?? '');
    String? result;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            widget.locale == 'fr' ? 'Effectuer un paiement' : 'Make Payment',
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Color(0xFF1A5C2A)),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.locale == 'fr'
                    ? 'Police : ${_policy['policyNo'] ?? ''}'
                    : 'Policy: ${_policy['policyNo'] ?? ''}',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: widget.locale == 'fr'
                      ? 'Montant (HTG)'
                      : 'Amount (HTG)',
                  prefixIcon: const Icon(Icons.attach_money),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: selectedMethod,
                decoration: InputDecoration(
                  labelText: widget.locale == 'fr'
                      ? 'Méthode de paiement'
                      : 'Payment Method',
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                items: methods
                    .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                    .toList(),
                onChanged: (v) => setLocal(() => selectedMethod = v!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s('cancel')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A5C2A),
                  foregroundColor: Colors.white),
              onPressed: () async {
                final amount =
                    double.tryParse(amountCtrl.text.trim()) ?? 0;
                if (amount <= 0) return;
                Navigator.pop(ctx, {'amount': amount, 'method': selectedMethod});
              },
              child: Text(
                  widget.locale == 'fr' ? 'Confirmer' : 'Confirm'),
            ),
          ],
        ),
      ),
    ).then((res) => result = res?.toString());

    if (result == null) return; // cancelled

    // Re-parse because showDialog result is a map not a string
    // We call directly after dialog closes
  }

  Future<void> _submitPayment() async {
    final methods = ['MOBILE_MONEY', 'BANK_TRANSFER', 'CASH'];
    String selectedMethod = 'MOBILE_MONEY';
    final amountCtrl = TextEditingController(
        text: _policy['premiumAmount']?.toString() ?? '');

    final confirmed = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            widget.locale == 'fr' ? 'Effectuer un paiement' : 'Make Payment',
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Color(0xFF1A5C2A)),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.locale == 'fr'
                    ? 'Police : ${_policy['policyNo'] ?? ''}'
                    : 'Policy: ${_policy['policyNo'] ?? ''}',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: widget.locale == 'fr' ? 'Montant (HTG)' : 'Amount (HTG)',
                  prefixIcon: const Icon(Icons.attach_money),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: selectedMethod,
                decoration: InputDecoration(
                  labelText: widget.locale == 'fr' ? 'Méthode de paiement' : 'Payment Method',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                items: methods.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                onChanged: (v) => setLocal(() => selectedMethod = v!),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s('cancel')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A5C2A),
                  foregroundColor: Colors.white),
              onPressed: () {
                final amount = double.tryParse(amountCtrl.text.trim()) ?? 0;
                if (amount <= 0) return;
                Navigator.pop(ctx, {'amount': amount, 'method': selectedMethod});
              },
              child: Text(widget.locale == 'fr' ? 'Confirmer' : 'Confirm'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == null || !mounted) return;

    try {
      final body = json.encode({
        'policyNo':      _policy['policyNo'],
        'memberId':      widget.member['memberId'],
        'amount':        confirmed['amount'],
        'paymentMethod': confirmed['method'],
        'schedSK':       _nextSched['SK'] ?? '',
      });
      final response = await http.post(
        Uri.parse('$_baseUrl/member/payment'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      if (!mounted) return;
      final data = json.decode(response.body);
      if (response.statusCode == 201) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.locale == 'fr'
              ? 'Paiement enregistré ✓  Réf: ${data['referenceNo']}'
              : 'Payment recorded ✓  Ref: ${data['referenceNo']}'),
          backgroundColor: Colors.green.shade700,
        ));
        widget.onRefresh();
      } else {
        throw Exception(data['error'] ?? 'Payment failed');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  // ── Create Claim ────────────────────────────────────────────────────────────

  Future<void> _submitClaim() async {
    final claimTypes = ['DEATH', 'DISABILITY', 'CRITICAL_ILLNESS', 'OTHER'];
    String selectedType = 'DEATH';
    final descCtrl = TextEditingController();

    final confirmed = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            widget.locale == 'fr' ? 'Soumettre une réclamation' : 'Submit a Claim',
            style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1A5C2A)),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.locale == 'fr'
                    ? 'Police : ${_policy['policyNo'] ?? ''}'
                    : 'Policy: ${_policy['policyNo'] ?? ''}',
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: selectedType,
                decoration: InputDecoration(
                  labelText: widget.locale == 'fr' ? 'Type de réclamation' : 'Claim Type',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
                items: claimTypes.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                onChanged: (v) => setLocal(() => selectedType = v!),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: descCtrl,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: widget.locale == 'fr' ? 'Description' : 'Description',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(s('cancel')),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A5C2A),
                  foregroundColor: Colors.white),
              onPressed: () {
                if (descCtrl.text.trim().isEmpty) return;
                Navigator.pop(ctx, {
                  'claimType':   selectedType,
                  'description': descCtrl.text.trim(),
                });
              },
              child: Text(widget.locale == 'fr' ? 'Soumettre' : 'Submit'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == null || !mounted) return;

    try {
      final body = json.encode({
        'policyNo':    _policy['policyNo'],
        'memberId':    widget.member['memberId'],
        'claimType':   confirmed['claimType'],
        'description': confirmed['description'],
      });
      final response = await http.post(
        Uri.parse('$_baseUrl/member/claim'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      if (!mounted) return;
      final data = json.decode(response.body);
      if (response.statusCode == 201) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.locale == 'fr'
              ? 'Réclamation soumise ✓  N°: ${data['claimNo']}'
              : 'Claim submitted ✓  No: ${data['claimNo']}'),
          backgroundColor: Colors.green.shade700,
        ));
        widget.onRefresh();
      } else {
        throw Exception(data['error'] ?? 'Claim failed');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final fr = widget.locale == 'fr';
    final policyNo    = _policy['policyNo']    ?? '—';
    final productCode = _policy['productCode'] ?? '—';
    final status      = _policy['policyStatus'] ?? '—';
    final startDate   = _policy['startDate']   ?? '—';
    final sumAssured  = _policy['sumAssured']  ?? '—';
    final premAmount  = _policy['premiumAmount'] ?? '—';
    final frequency   = _policy['frequency']   ?? '—';
    final isActive    = status == 'ACTIVE';

    // Last payment
    final lastPayDate   = _lastPay['paymentDate']  ?? '—';
    final lastPayAmount = _lastPay['amountPaid']   ?? '—';

    // Next due
    final nextDueDate   = _nextSched['dueDate']    ?? _policy['nextDueDate'] ?? '—';
    final nextDueAmount = _nextSched['amountDue']  ?? _policy['premiumAmount'] ?? '—';
    final nextSchedSK   = _nextSched['SK']         ?? '';

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [

          // ── Header ──────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              gradient: LinearGradient(
                colors: isActive
                    ? [const Color(0xFF1A5C2A), const Color(0xFF2E7D45)]
                    : [Colors.grey.shade600, Colors.grey.shade500],
              ),
            ),
            child: Row(children: [
              const Icon(Icons.policy, color: Colors.white, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(policyNo,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    Text(productCode,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 13)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isActive ? Colors.green.shade300 : Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  status,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: isActive ? Colors.green.shade900 : Colors.grey.shade700,
                  ),
                ),
              ),
            ]),
          ),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // ── Policy info ──────────────────────────────────────────────
                _SectionTitle(fr ? 'Détails de la police' : 'Policy Details'),
                const SizedBox(height: 8),
                _InfoRow2(fr ? 'Début' : 'Start Date', startDate),
                _InfoRow2(fr ? 'Montant assuré' : 'Sum Assured', 'HTG $sumAssured'),
                _InfoRow2(fr ? 'Prime' : 'Premium', 'HTG $premAmount / $frequency'),

                const Divider(height: 24),

                // ── Payment summary ──────────────────────────────────────────
                _SectionTitle(fr ? 'Paiements' : 'Payments'),
                const SizedBox(height: 8),
                _InfoRow2(fr ? 'Dernier paiement' : 'Last Payment Date', lastPayDate),
                _InfoRow2(fr ? 'Dernier montant' : 'Last Amount', lastPayAmount != '—' ? 'HTG $lastPayAmount' : '—'),
                _InfoRow2(fr ? 'Prochaine échéance' : 'Next Due Date', nextDueDate,
                    highlight: nextSchedSK.isNotEmpty),
                _InfoRow2(fr ? 'Montant dû' : 'Amount Due', nextDueAmount != '—' ? 'HTG $nextDueAmount' : '—',
                    highlight: nextSchedSK.isNotEmpty),

                const SizedBox(height: 16),

                // ── Claims list ──────────────────────────────────────────────
                if (_claims.isNotEmpty) ...[
                  const Divider(height: 24),
                  _SectionTitle(fr ? 'Réclamations' : 'Claims'),
                  const SizedBox(height: 8),
                  ..._claims.map((c) {
                    final claim = c as Map<String, dynamic>;
                    return _ClaimTile(claim: claim);
                  }),
                ],

                // ── Beneficiaries ─────────────────────────────────────────────
                const Divider(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _SectionTitle(s('beneficiaries')),
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => BeneficiariesScreen(
                            memberId: widget.member['memberId'] as String? ?? '',
                            policyNo: _policy['policyNo'] as String? ?? '',
                          ),
                        ),
                      ).then((_) => _loadBeneficiaries()),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.edit_outlined,
                            size: 13, color: Color(0xFF1A5C2A)),
                        const SizedBox(width: 4),
                        Text(s('editBeneficiaries'),
                            style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF1A5C2A),
                                fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (_loadingBenefits)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(children: [
                      const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF1A5C2A)),
                      ),
                      const SizedBox(width: 10),
                      Text(s('loadingBeneficiaries'),
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey.shade500)),
                    ]),
                  )
                else if (_beneficiaries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(s('noBeneficiaries'),
                        style: TextStyle(
                            fontSize: 13, color: Colors.grey.shade500)),
                  )
                else
                  ..._beneficiaries.map((b) => _BeneficiaryTile(
                      data: b, locale: widget.locale)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Helper widgets ────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 13,
            color: Color(0xFF1A5C2A)),
      );
}

class _InfoRow2 extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;
  const _InfoRow2(this.label, this.value, {this.highlight = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          Text(value,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight:
                      highlight ? FontWeight.bold : FontWeight.normal,
                  color: highlight
                      ? const Color(0xFF1A5C2A)
                      : const Color(0xFF1A1A1A))),
        ],
      ),
    );
  }
}

class _ClaimTile extends StatelessWidget {
  final Map<String, dynamic> claim;
  const _ClaimTile({required this.claim});

  Color _statusColor(String s) {
    switch (s) {
      case 'APPROVED': return Colors.green.shade700;
      case 'REJECTED': return Colors.red.shade700;
      default:         return Colors.orange.shade700;
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = claim['claimStatus'] ?? 'SUBMITTED';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(claim['claimNo'] ?? '—',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 13)),
            Text(claim['claimType'] ?? '—',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            Text(claim['submittedAt']?.toString().substring(0, 10) ?? '—',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ]),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _statusColor(status).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              status,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: _statusColor(status)),
            ),
          ),
        ],
      ),
    );
  }
}

class _BeneficiaryTile extends StatelessWidget {
  final Map<String, dynamic> data;
  final String locale;
  const _BeneficiaryTile({required this.data, required this.locale});

  @override
  Widget build(BuildContext context) {
    final name         = data['name']         as String? ?? '—';
    final relationship = data['relationship'] as String? ?? '—';
    final share        = data['sharePercent'];
    final shareStr     = share != null ? '$share%' : '—';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1A5C2A).withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1A5C2A).withValues(alpha: 0.15)),
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: const Color(0xFF1A5C2A).withValues(alpha: 0.12),
          child: const Icon(Icons.person, size: 18, color: Color(0xFF1A5C2A)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
            Text(relationship,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFC8A96E).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            shareStr,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Color(0xFF8B6914)),
          ),
        ),
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
          ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
        ]),
      );
}

class _EmptyView extends StatelessWidget {
  final String locale;
  const _EmptyView({required this.locale});
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.policy_outlined, color: Colors.grey.shade400, size: 64),
          const SizedBox(height: 16),
          Text(
            locale == 'fr'
                ? 'Aucune police trouvée'
                : 'No policies found',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
          ),
        ]),
      );
}