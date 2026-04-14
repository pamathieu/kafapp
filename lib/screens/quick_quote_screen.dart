import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import 'enrollment_form_screen.dart';

const _green = Color(0xFF1A5C2A);
const _bg    = Color(0xFFF2F4F7);

// ─────────────────────────────────────────────────────────────────────────────
//  Quick Quote Screen — cost simulation tool
// ─────────────────────────────────────────────────────────────────────────────

class QuickQuoteScreen extends StatefulWidget {
  final String memberId;
  final String memberName;
  final String? phone;
  final String? email;

  const QuickQuoteScreen({
    super.key,
    required this.memberId,
    required this.memberName,
    this.phone,
    this.email,
  });

  @override
  State<QuickQuoteScreen> createState() => _QuickQuoteScreenState();
}

class _QuickQuoteScreenState extends State<QuickQuoteScreen> {
  int _selectedPlan = 0; // 0=Basic, 1=Plus, 2=Premium
  int _members = 1;

  static const _plans = [
    {'code': 'BASIC',   'premium': 250,  'sumAssured': 25000},
    {'code': 'PLUS',    'premium': 450,  'sumAssured': 50000},
    {'code': 'PREMIUM', 'premium': 750,  'sumAssured': 100000},
  ];

  static const _tierColors = [
    Color(0xFF1565C0),
    _green,
    Color(0xFF8B6914),
  ];

  static const _tierAccents = [
    Color(0xFFE3F2FD),
    Color(0xFFE8F5E9),
    Color(0xFFFFF8E1),
  ];

  static const _tierIcons = [
    Icons.shield_outlined,
    Icons.shield,
    Icons.star,
  ];

  int get _totalMonthly =>
      (_plans[_selectedPlan]['premium']! as int) * _members;

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Text(s('quickQuoteTitle'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _green,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s('quickQuoteSubtitle'),
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
          const SizedBox(height: 24),

          // ── Plan selector ────────────────────────────────────────────────
          Text(s('quickQuoteSelectPlan'),
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A1A))),
          const SizedBox(height: 12),
          ...List.generate(_plans.length, (i) {
            final plan      = _plans[i];
            final color     = _tierColors[i];
            final accent    = _tierAccents[i];
            final icon      = _tierIcons[i];
            final isSelected = _selectedPlan == i;
            final nameKey = i == 0 ? 'planBasic' : i == 1 ? 'planPlus' : 'planPremium';

            return GestureDetector(
              onTap: () => setState(() => _selectedPlan = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isSelected ? color : Colors.grey.shade200,
                    width: isSelected ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 6,
                        offset: const Offset(0, 2)),
                  ],
                ),
                child: Row(children: [
                  Container(
                    width: 40, height: 40,
                    decoration: BoxDecoration(
                        color: isSelected ? color : accent,
                        shape: BoxShape.circle),
                    child: Icon(icon,
                        color: isSelected ? Colors.white : color, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(s(nameKey),
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? color : const Color(0xFF1A1A1A))),
                        Text(s('quickQuoteCoverage')
                                .replaceAll('{amount}', _fmt(plan['sumAssured'] as int)),
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade500)),
                      ],
                    ),
                  ),
                  Text('HTG ${plan['premium']}/mo',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: isSelected ? color : Colors.grey.shade600)),
                  const SizedBox(width: 8),
                  Icon(
                    isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: isSelected ? color : Colors.grey.shade400,
                    size: 20,
                  ),
                ]),
              ),
            );
          }),

          const SizedBox(height: 24),

          // ── Number of members ────────────────────────────────────────────
          Text(s('quickQuoteMembers'),
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A1A))),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 6,
                    offset: const Offset(0, 2)),
              ],
            ),
            child: Row(children: [
              Text(s('quickQuoteMembersDesc'),
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
              const Spacer(),
              _CounterButton(
                icon: Icons.remove,
                onTap: _members > 1 ? () => setState(() => _members--) : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text('$_members',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              _CounterButton(
                icon: Icons.add,
                onTap: _members < 10 ? () => setState(() => _members++) : null,
              ),
            ]),
          ),

          const SizedBox(height: 28),

          // ── Result card ──────────────────────────────────────────────────
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _tierColors[_selectedPlan],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s('quickQuoteEstimate'),
                  style: const TextStyle(
                      fontSize: 13,
                      color: Colors.white70)),
              const SizedBox(height: 6),
              Text('HTG $_totalMonthly',
                  style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              Text(s('quickQuotePerMonth'),
                  style: const TextStyle(fontSize: 13, color: Colors.white70)),
              const SizedBox(height: 12),
              Row(children: [
                const Icon(Icons.info_outline, size: 14, color: Colors.white70),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    s('quickQuoteNote')
                        .replaceAll('{members}', '$_members'),
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
              ]),
            ]),
          ),

          const SizedBox(height: 24),

          // ── Apply button ─────────────────────────────────────────────────
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => EnrollmentFormScreen(
                    memberId:     widget.memberId,
                    memberName:   widget.memberName,
                    phone:        widget.phone,
                    email:        widget.email,
                    selectedPlan: _plans[_selectedPlan]['code'] as String,
                  ),
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                textStyle: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold),
              ),
              child: Text(s('quickQuoteApply')),
            ),
          ),
        ]),
      ),
    );
  }

  String _fmt(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

class _CounterButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;

  const _CounterButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 34, height: 34,
        decoration: BoxDecoration(
          color: enabled ? _green : Colors.grey.shade200,
          shape: BoxShape.circle,
        ),
        child: Icon(icon,
            size: 18,
            color: enabled ? Colors.white : Colors.grey.shade400),
      ),
    );
  }
}
