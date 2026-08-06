import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../services/dev_env.dart';
import '../widgets/billing_toggle.dart';
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
    'premiumAmount': 10,
    'premiumCurrency': 'USD',
    'premiumAmountGdes': 1350,
    'annualAmount': 120,
    'annualAmountGdes': 16250,
    'sumAssured':    270000,
    'features': [
      'Age acceptance 0-80 years',
      'No medical exam',
      'Fixed premium',
      'Flexible payment (monthly/quarterly/annual)',
      'Fast claims processing',
    ],
  },
  {
    'planCode':      'STANDARD',
    'mostPopular':   true,
    'premiumAmount': 20,
    'premiumCurrency': 'USD',
    'premiumAmountGdes': 2700,
    'annualAmount': 240,
    'annualAmountGdes': 32500,
    'sumAssured':    400000,
    'features': [
      'Age acceptance 0-80 years',
      'No medical exam',
      'Fixed premium',
      'Flexible payment (monthly/quarterly/annual)',
      'Fast claims processing',
      '24/7 phone support',
    ],
  },
  {
    'planCode':      'FUNERAL_SAVINGS',
    'isSavingsPlan': true,
    'features': [
      'Open to ALL ages',
      'Unlimited savings',
      'Continuous deposit flexibility',
      'Fixed premium',
      'Flexible payment (monthly/quarterly/annual)',
      'Fast claims processing',
      '24/7 phone support',
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
  static const _baseUrl = kApiBaseUrl;

  List<Map<String, dynamic>> _plans = [];
  bool _loading = true;
  bool _annual  = false; // false = monthly, true = annual billing

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

  void _showSwitchPlanSheet(BuildContext context, String locale,
      Map<String, dynamic> plan) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _SwitchPlanSheet(
        memberId:        widget.memberId,
        memberName:      widget.memberName,
        phone:           widget.phone,
        email:           widget.email,
        currentPlanCode: widget.currentPlanCode,
        targetPlan:      plan,
        locale:          locale,
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
                  const SizedBox(height: 16),
                  BillingToggle(
                    annual: _annual,
                    locale: locale,
                    onChanged: (v) => setState(() => _annual = v),
                  ),
                  const SizedBox(height: 16),
                  ..._plans.asMap().entries.map((entry) {
                    final idx   = entry.key;
                    final plan  = entry.value;
                    final code  = (plan['planCode'] as String? ?? '').toUpperCase();
                    final isCurrent = widget.currentPlanCode != null &&
                        widget.currentPlanCode!.toUpperCase().contains(code);
                    // Show "Switch to this plan" for any non-current plan when member has a policy.
                    final showUpgrade = _hasPolicies && !isCurrent;

                    return _PlanCard(
                      plan:         plan,
                      locale:       locale,
                      isCurrent:    isCurrent,
                      tierIndex:    idx,
                      showUpgrade:  showUpgrade,
                      showActions:  !_hasPolicies,
                      annual:       _annual,
                      memberId:     widget.memberId,
                      memberName:   widget.memberName,
                      phone:        widget.phone,
                      email:        widget.email,
                      onUpgrade:    showUpgrade
                          ? () => _showSwitchPlanSheet(context, locale, plan)
                          : null,
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
  final bool showActions; // Apply button (members w/o policy)
  final bool annual;
  final String memberId;
  final String memberName;
  final String? phone;
  final String? email;
  final VoidCallback? onUpgrade;

  const _PlanCard({
    required this.plan,
    required this.locale,
    required this.isCurrent,
    required this.tierIndex,
    required this.showUpgrade,
    required this.showActions,
    required this.annual,
    required this.memberId,
    required this.memberName,
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

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);

    final code         = plan['planCode'] as String? ?? '';
    final isSavingsPlan = plan['isSavingsPlan'] == true;
    final mostPopular  = plan['mostPopular'] == true;
    final premium      = annual ? plan['annualAmount']     : plan['premiumAmount'];
    final premiumGdes  = annual ? plan['annualAmountGdes'] : plan['premiumAmountGdes'];
    final assured      = plan['sumAssured'];
    final features      = (plan['features'] as List?)?.cast<String>() ?? [];

    final planNameKey = code.toUpperCase() == 'BASIC'           ? 'planBasic'
                      : code.toUpperCase() == 'STANDARD'        ? 'planStandard'
                      : code.toUpperCase() == 'FUNERAL_SAVINGS' ? 'planFuneralSavings'
                      : null;
    final planName = planNameKey != null ? s(planNameKey) : code;

    final tierColor   = tierIndex < _tierColors.length  ? _tierColors[tierIndex]   : _green;
    final accentColor = tierIndex < _tierAccents.length ? _tierAccents[tierIndex] : const Color(0xFFE8F5E9);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: mostPopular
            ? Border.all(color: _gold, width: 2)
            : isCurrent
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
          // ── "Most Popular" badge ─────────────────────────────────────────
          if (mostPopular)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: const BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
              ),
              alignment: Alignment.center,
              child: Text(s('mostPopular'),
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A1A1A),
                      letterSpacing: 0.5)),
            ),

          // ── Header ────────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: mostPopular
                  ? BorderRadius.zero
                  : const BorderRadius.vertical(top: Radius.circular(14)),
            ),
            child: Row(children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                    color: tierColor.withValues(alpha: 0.15),
                    shape: BoxShape.circle),
                child: Icon(
                  isSavingsPlan ? Icons.savings_outlined
                  : tierIndex == 0 ? Icons.shield_outlined
                  : Icons.shield,
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
              if (!isSavingsPlan)
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (premium != null)
                    Text('US\$$premium',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: tierColor)),
                  if (premiumGdes != null)
                    Text('${_fmt(premiumGdes)} Gdes',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade600)),
                  Text(s(annual ? 'premiumPerYear' : 'premiumPerMonth'),
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600)),
                ]),
            ]),
          ),

          // ── Coverage ──────────────────────────────────────────────────────
          if (assured != null && !isSavingsPlan)
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

// ─────────────────────────────────────────────────────────────────────────────
//  Plan switch request bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _SwitchPlanSheet extends StatefulWidget {
  final String memberId;
  final String memberName;
  final String? phone;
  final String? email;
  final String? currentPlanCode;
  final Map<String, dynamic> targetPlan;
  final String locale;

  const _SwitchPlanSheet({
    required this.memberId,
    required this.memberName,
    required this.targetPlan,
    required this.locale,
    this.phone,
    this.email,
    this.currentPlanCode,
  });

  @override
  State<_SwitchPlanSheet> createState() => _SwitchPlanSheetState();
}

class _SwitchPlanSheetState extends State<_SwitchPlanSheet> {
  static const _baseUrl = kApiBaseUrl;

  final _notesCtrl = TextEditingController();
  bool _submitting = false;
  bool _submitted  = false;

  @override
  void dispose() {
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      final code = (widget.targetPlan['planCode'] as String? ?? '').toUpperCase();
      final body = json.encode({
        'memberId':    widget.memberId,
        'name':        widget.memberName,
        'phone':       widget.phone  ?? '',
        'email':       widget.email  ?? '',
        'plan':        code,
        'currentPlan': widget.currentPlanCode ?? '',
        'notes':       _notesCtrl.text.trim(),
        'requestType': 'SWITCH',
      });
      final resp = await http.post(
        Uri.parse('$_baseUrl/member/enrollment'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      if (!mounted) return;
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        setState(() { _submitted = true; _submitting = false; });
      } else {
        Map<String, dynamic> data = {};
        try { data = json.decode(resp.body) as Map<String, dynamic>; } catch (_) {}
        throw Exception(data['error'] ?? 'HTTP ${resp.statusCode}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      final locale = widget.locale;
      String s(String k) => AppStrings.get(k, locale);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${s('errorPrefix')}$e'),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = widget.locale;
    String s(String k) => AppStrings.get(k, locale);

    final code  = (widget.targetPlan['planCode'] as String? ?? '').toUpperCase();
    final planNameKey = code == 'BASIC'           ? 'planBasic'
                      : code == 'STANDARD'        ? 'planStandard'
                      : code == 'FUNERAL_SAVINGS' ? 'planFuneralSavings'
                      : null;
    final planName = planNameKey != null ? s(planNameKey) : code;
    final premium  = widget.targetPlan['premiumAmount'];

    if (_submitted) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.check_circle_outline, color: _green, size: 64),
          const SizedBox(height: 16),
          Text(s('enrollmentSent'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 24),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s('ok')),
          ),
        ]),
      );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(
          24, 24, 24, MediaQuery.of(context).viewInsets.bottom + 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(s('upgradePlanTitle').replaceAll('{plan}', planName),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          s('upgradePlanConfirm')
              .replaceAll('{plan}', planName)
              .replaceAll('{price}', '${premium ?? ''}'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 16),
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
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _submitting ? null : () => Navigator.of(context).pop(),
              style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: Text(s('upgradePlanCancel')),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton(
              onPressed: _submitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                  backgroundColor: _green,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(s('upgradePlanSubmit')),
            ),
          ),
        ]),
      ]),
    );
  }
}

