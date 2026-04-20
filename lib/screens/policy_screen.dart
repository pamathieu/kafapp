import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import 'beneficiaries_screen.dart';
import 'policy_detail_screen.dart';

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

  double _parseNum(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  Map<String, dynamic> get _policy  => widget.data['policy']  as Map<String, dynamic>? ?? {};
  Map<String, dynamic> get _lastPay => widget.data['lastPay'] as Map<String, dynamic>? ?? {};
  Map<String, dynamic> get _nextSched => widget.data['nextSched'] as Map<String, dynamic>? ?? {};
  List<dynamic>        get _claims   => widget.data['claims']  as List<dynamic>? ?? [];

  // ── View Details (navigates to PolicyDetailScreen) ──────────────────────────

  void _openPolicyDetail() {
    final memberId   = widget.member['memberId'] as String? ?? '';
    final memberName = widget.member['full_name'] as String? ?? 'Member';

    // Parse payment history from lastPay + any history list in the payload
    final List<PaymentHistory> paymentHistory = [];
    if (_lastPay.isNotEmpty && _lastPay['paymentDate'] != null) {
      paymentHistory.add(PaymentHistory(
        paymentId:   _lastPay['referenceNo']  as String? ?? '',
        date:        _lastPay['paymentDate']  as String? ?? '',
        amountCents: (_parseNum(_lastPay['amountPaid']) * 100).round(),
        status:      'SUCCEEDED',
        period:      _lastPay['paymentPeriod'] as String? ?? '',
      ));
    }

    // Parse beneficiaries already loaded
    final List<Beneficiary> beneficiaries = _beneficiaries.map((b) => Beneficiary(
      name:         b['name']         as String? ?? '',
      relationship: b['relationship'] as String? ?? '',
      percentage:   _parseNum(b['sharePercent']).toInt(),
    )).toList();

    final premiumAmount = _parseNum(_policy['premiumAmount']);
    final sumAssured    = _parseNum(_policy['sumAssured']);

    final detail = PolicyDetail(
      policyId:            _policy['policyNo']    as String? ?? '',
      memberId:            memberId,
      memberName:          memberName,
      planName:            _policy['productCode'] as String? ?? 'KAFA Plan',
      monthlyPremiumCents: (premiumAmount * 100).round(),
      coverageAmountCents: (sumAssured    * 100).round(),
      startDate:           _policy['startDate']   as String? ?? '',
      nextDueDate:         _nextSched['dueDate']  as String? ?? _policy['nextDueDate'] as String? ?? '',
      nextPeriodStart:     _nextSched['dueDate']  as String? ?? '',
      nextPeriodEnd:       _nextSched['dueDate']  as String? ?? '',
      status: () {
        switch ((_policy['policyStatus'] as String? ?? '').toUpperCase()) {
          case 'ACTIVE':    return PolicyStatus.active;
          case 'PENDING':   return PolicyStatus.pending;
          case 'LAPSED':    return PolicyStatus.lapsed;
          case 'CANCELLED': return PolicyStatus.cancelled;
          default:          return PolicyStatus.active;
        }
      }(),
      beneficiaries:  beneficiaries,
      paymentHistory: paymentHistory,
    );

    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, animation, __) => FadeTransition(
          opacity: animation,
          child: PolicyDetailScreen(policy: detail),
        ),
        transitionDuration: const Duration(milliseconds: 300),
      ),
    ).then((_) => widget.onRefresh());
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

                const SizedBox(height: 16),

                // ── View Details button ──────────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _openPolicyDetail,
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: Text(fr ? 'Voir les détails' : 'View Details'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1A5C2A),
                      side: const BorderSide(color: Color(0xFF1A5C2A)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
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