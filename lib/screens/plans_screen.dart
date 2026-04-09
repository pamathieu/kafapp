import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Plans & Coverage screen
//  Fetches GET /member/plans — falls back to hardcoded tiers if unavailable.
// ─────────────────────────────────────────────────────────────────────────────

const _green = Color(0xFF1A5C2A);
const _bg    = Color(0xFFF2F4F7);

/// Hardcoded fallback plans — shown when the backend endpoint isn't ready yet.
const _fallbackPlans = [
  {
    'planCode':      'BASIC',
    'premiumAmount': 250,
    'sumAssured':    25000,
    'features': [
      'Couverture funèbre de base',
      'Transport local inclus',
      'Cercueil standard',
      'Assistance téléphonique',
    ],
  },
  {
    'planCode':      'PLUS',
    'premiumAmount': 450,
    'sumAssured':    50000,
    'features': [
      'Couverture funèbre étendue',
      'Transport régional inclus',
      'Cercueil de qualité supérieure',
      'Assistance 24h/24',
      'Cérémonie de base incluse',
    ],
  },
  {
    'planCode':      'PREMIUM',
    'premiumAmount': 750,
    'sumAssured':    100000,
    'features': [
      'Couverture funèbre complète',
      'Transport national & international',
      'Cercueil premium',
      'Assistance 24h/24 dédiée',
      'Cérémonie complète incluse',
      'Rapatriement de corps',
    ],
  },
];

class PlansScreen extends StatefulWidget {
  /// The policyStatus from the member's active policy, used to highlight
  /// their current tier when we can match it.
  final String? currentPlanCode;
  final String memberId;

  const PlansScreen({
    super.key,
    required this.memberId,
    this.currentPlanCode,
  });

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  static const _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  List<Map<String, dynamic>> _plans = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPlans();
  }

  Future<void> _loadPlans() async {
    setState(() => _loading = true);
    try {
      final uri = Uri.parse('$_baseUrl/member/plans');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final plans = data['plans'] as List?;
        setState(() {
          _plans   = plans != null
              ? List<Map<String, dynamic>>.from(plans)
              : List<Map<String, dynamic>>.from(_fallbackPlans);
          _loading = false;
        });
      } else {
        // Backend not ready yet — use hardcoded fallback
        setState(() {
          _plans   = List<Map<String, dynamic>>.from(_fallbackPlans);
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _plans   = List<Map<String, dynamic>>.from(_fallbackPlans);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Text(s('plansTitle'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _green,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadPlans),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _green))
          : RefreshIndicator(
              onRefresh: _loadPlans,
              color: _green,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                children: [
                  Text(s('plansSubtitle'),
                      style: TextStyle(
                          fontSize: 14, color: Colors.grey.shade600)),
                  const SizedBox(height: 20),
                  ..._plans.asMap().entries.map((entry) {
                    final idx  = entry.key;
                    final plan = entry.value;
                    final code = (plan['planCode'] as String? ?? '').toUpperCase();
                    final isCurrent = widget.currentPlanCode != null &&
                        widget.currentPlanCode!.toUpperCase().contains(code);
                    return _PlanCard(
                      plan:      plan,
                      locale:    locale,
                      isCurrent: isCurrent,
                      tierIndex: idx,
                    );
                  }),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _green.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _green.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.info_outline, color: _green, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(s('planContactAdmin'),
                              style: TextStyle(
                                  fontSize: 13, color: Colors.grey.shade700)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Single plan card
// ─────────────────────────────────────────────────────────────────────────────

class _PlanCard extends StatelessWidget {
  final Map<String, dynamic> plan;
  final String locale;
  final bool isCurrent;
  final int tierIndex; // 0=Basic, 1=Plus, 2=Premium

  const _PlanCard({
    required this.plan,
    required this.locale,
    required this.isCurrent,
    required this.tierIndex,
  });

  static const _tierColors = [
    Color(0xFF1565C0), // Basic — blue
    _green,            // Plus  — green
    Color(0xFF8B6914), // Premium — gold/dark
  ];

  static const _tierAccents = [
    Color(0xFFE3F2FD),
    Color(0xFFE8F5E9),
    Color(0xFFFFF8E1),
  ];

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);

    final code     = plan['planCode']      as String? ?? '';
    final premium  = plan['premiumAmount'];
    final assured  = plan['sumAssured'];
    final features = (plan['features'] as List?)?.cast<String>() ?? [];

    final planNameKey = code.toLowerCase() == 'basic'   ? 'planBasic'
                      : code.toLowerCase() == 'plus'    ? 'planPlus'
                      : code.toLowerCase() == 'premium' ? 'planPremium'
                      : null;
    final planName = planNameKey != null ? s(planNameKey) : code;

    final tierColor  = tierIndex < _tierColors.length
        ? _tierColors[tierIndex] : _green;
    final accentColor = tierIndex < _tierAccents.length
        ? _tierAccents[tierIndex] : const Color(0xFFE8F5E9);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: isCurrent
            ? Border.all(color: tierColor, width: 2)
            : Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                      color: tierColor.withValues(alpha: 0.15),
                      shape: BoxShape.circle),
                  child: Icon(
                    tierIndex == 0 ? Icons.shield_outlined
                    : tierIndex == 1 ? Icons.shield
                    : Icons.star,
                    color: tierColor, size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isCurrent)
                        Container(
                          margin: const EdgeInsets.only(bottom: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: tierColor,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(s('yourCurrentPlan'),
                              style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                        ),
                      Text(planName,
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: tierColor)),
                    ],
                  ),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (premium != null)
                    Text('HTG $premium',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: tierColor)),
                  Text(s('premiumPerMonth'),
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600)),
                ]),
              ],
            ),
          ),

          // Coverage amount
          if (assured != null)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(s('coverageLabel'),
                      style: TextStyle(
                          fontSize: 13, color: Colors.grey.shade600)),
                  Text('HTG ${_fmt(assured)}',
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A1A1A))),
                ],
              ),
            ),

          if (features.isNotEmpty) ...[
            Divider(height: 1, color: Colors.grey.shade100),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(s('planFeatures'),
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _green)),
            ),
            ...features.map(
              (f) => Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_circle, size: 15, color: tierColor),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text(f,
                            style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  /// Format large numbers: 100000 → "100,000"
  String _fmt(dynamic n) {
    final val = n is num ? n.toInt() : int.tryParse(n.toString()) ?? 0;
    final s = val.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
