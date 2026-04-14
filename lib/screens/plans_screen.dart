import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import 'enrollment_form_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Plans & Coverage screen
// ─────────────────────────────────────────────────────────────────────────────

const _green = Color(0xFF1A5C2A);
const _gold  = Color(0xFFC8A96E);
const _bg    = Color(0xFFF2F4F7);

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
  final String? currentPlanCode;
  final String memberId;
  final String memberName;
  final String? phone;
  final String? email;

  const PlansScreen({
    super.key,
    required this.memberId,
    this.currentPlanCode,
    this.memberName = '',
    this.phone,
    this.email,
  });

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

class _PlansScreenState extends State<PlansScreen> {
  static const _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  List<Map<String, dynamic>> _plans = [];
  bool _loading = true;

  bool get _hasPolicies => widget.currentPlanCode != null && widget.currentPlanCode!.isNotEmpty;

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
        final data  = json.decode(response.body) as Map<String, dynamic>;
        final plans = data['plans'] as List?;
        setState(() {
          _plans   = plans != null
              ? List<Map<String, dynamic>>.from(plans)
              : List<Map<String, dynamic>>.from(_fallbackPlans);
          _loading = false;
        });
      } else {
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

  void _showUpgradeDialog(BuildContext context, String locale,
      String planName, int premium) {
    String s(String k) => AppStrings.get(k, locale);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          s('upgradePlanTitle').replaceAll('{plan}', planName),
          style: const TextStyle(fontWeight: FontWeight.bold, color: _green),
        ),
        content: Text(
          s('upgradePlanConfirm')
              .replaceAll('{plan}', planName)
              .replaceAll('{price}', '$premium'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s('upgradePlanCancel')),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: _green, foregroundColor: Colors.white),
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(s('upgradePlanSuccess')),
                backgroundColor: _green,
              ));
            },
            child: Text(s('upgradePlanSubmit')),
          ),
        ],
      ),
    );
  }

  void _showDocumentUnavailable(BuildContext context, String locale) {
    String s(String k) => AppStrings.get(k, locale);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Text(s('documentUnavailable')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
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
                    final idx   = entry.key;
                    final plan  = entry.value;
                    final code  = (plan['planCode'] as String? ?? '').toUpperCase();
                    final isCurrent = widget.currentPlanCode != null &&
                        widget.currentPlanCode!.toUpperCase().contains(code);
                    // Upgrade only for Plus (idx=1) and Premium (idx=2), w/ policies, not current
                    final showUpgrade = _hasPolicies && !isCurrent && idx > 0;

                    return _PlanCard(
                      plan:         plan,
                      locale:       locale,
                      isCurrent:    isCurrent,
                      tierIndex:    idx,
                      showUpgrade:  showUpgrade,
                      showActions:  !_hasPolicies,
                      memberId:     widget.memberId,
                      memberName:   widget.memberName,
                      phone:        widget.phone,
                      email:        widget.email,
                      onUpgrade:    showUpgrade
                          ? () {
                              final nameKey = idx == 1 ? 'planPlus' : 'planPremium';
                              final planName = AppStrings.get(nameKey, locale);
                              final premium  = (plan['premiumAmount'] as num?)?.toInt() ?? 0;
                              _showUpgradeDialog(context, locale, planName, premium);
                            }
                          : null,
                      onViewMore:   () => _showDocumentUnavailable(context, locale),
                    );
                  }),
                  const SizedBox(height: 16),
                  if (_hasPolicies)
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: _green.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(12),
                        border:
                            Border.all(color: _green.withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.info_outline,
                              color: _green, size: 18),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(s('planContactAdmin'),
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey.shade700)),
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
  final int tierIndex;
  final bool showUpgrade;
  final bool showActions; // View More + Apply (members w/o policy)
  final String memberId;
  final String memberName;
  final String? phone;
  final String? email;
  final VoidCallback? onUpgrade;
  final VoidCallback onViewMore;

  const _PlanCard({
    required this.plan,
    required this.locale,
    required this.isCurrent,
    required this.tierIndex,
    required this.showUpgrade,
    required this.showActions,
    required this.memberId,
    required this.memberName,
    required this.onViewMore,
    this.phone,
    this.email,
    this.onUpgrade,
  });

  static const _tierColors = [
    Color(0xFF1565C0), // Basic  — blue
    _green,            // Plus   — green
    Color(0xFF8B6914), // Premium — gold/dark
  ];

  static const _tierAccents = [
    Color(0xFFE3F2FD),
    Color(0xFFE8F5E9),
    Color(0xFFFFF8E1),
  ];

  // "View More" button color matches plan tier
  static const _viewMoreColors = [
    Color(0xFF1565C0),
    _green,
    _gold,
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

    final tierColor   = tierIndex < _tierColors.length  ? _tierColors[tierIndex]   : _green;
    final accentColor = tierIndex < _tierAccents.length ? _tierAccents[tierIndex] : const Color(0xFFE8F5E9);
    final viewMoreColor = tierIndex < _viewMoreColors.length ? _viewMoreColors[tierIndex] : _green;

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
          // ── Header ────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(children: [
              Container(
                width: 44, height: 44,
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
            ]),
          ),

          // ── Coverage ──────────────────────────────────────────────────────
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

          // ── Features ──────────────────────────────────────────────────────
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
          ],

          // ── Action buttons ────────────────────────────────────────────────
          if (showUpgrade || showActions) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (showActions) ...[
                    // View More
                    OutlinedButton(
                      onPressed: onViewMore,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: viewMoreColor,
                        side: BorderSide(color: viewMoreColor),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        textStyle: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      child: Text(s('viewMore')),
                    ),
                    const SizedBox(width: 8),
                    // Apply
                    ElevatedButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => EnrollmentFormScreen(
                            memberId:     memberId,
                            memberName:   memberName,
                            phone:        phone,
                            email:        email,
                            selectedPlan: code.toUpperCase(),
                          ),
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _green,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        textStyle: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      child: Text(s('applyPlan')),
                    ),
                  ],
                  if (showUpgrade)
                    ElevatedButton(
                      onPressed: onUpgrade,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: tierColor,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        textStyle: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                      child: Text(s('upgradePlan')),
                    ),
                ],
              ),
            ),
          ] else
            const SizedBox(height: 12),
        ],
      ),
    );
  }

  String _fmt(dynamic n) {
    final val = n is num ? n.toInt() : int.tryParse(n.toString()) ?? 0;
    final str = val.toString();
    final buf = StringBuffer();
    for (var i = 0; i < str.length; i++) {
      if (i > 0 && (str.length - i) % 3 == 0) buf.write(',');
      buf.write(str[i]);
    }
    return buf.toString();
  }
}
