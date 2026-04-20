import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'payment_screen.dart';

// ── Models ────────────────────────────────────────────────────────────────────

enum PolicyStatus { active, pending, lapsed, cancelled }

class Beneficiary {
  final String name;
  final String relationship;
  final int percentage;

  const Beneficiary({
    required this.name,
    required this.relationship,
    required this.percentage,
  });
}

class PaymentHistory {
  final String paymentId;
  final String date;
  final int amountCents;
  final String status; // 'SUCCEEDED' | 'FAILED' | 'PENDING'
  final String period;

  const PaymentHistory({
    required this.paymentId,
    required this.date,
    required this.amountCents,
    required this.status,
    required this.period,
  });

  String get formattedAmount => '\$${(amountCents / 100).toStringAsFixed(2)}';
}

class PolicyDetail {
  final String policyId;
  final String memberId;
  final String memberName;
  final String planName;
  final int monthlyPremiumCents;
  final int coverageAmountCents;
  final String startDate;
  final String nextDueDate;
  final String nextPeriodStart;
  final String nextPeriodEnd;
  final PolicyStatus status;
  final List<Beneficiary> beneficiaries;
  final List<PaymentHistory> paymentHistory;

  const PolicyDetail({
    required this.policyId,
    required this.memberId,
    required this.memberName,
    required this.planName,
    required this.monthlyPremiumCents,
    required this.coverageAmountCents,
    required this.startDate,
    required this.nextDueDate,
    required this.nextPeriodStart,
    required this.nextPeriodEnd,
    required this.status,
    required this.beneficiaries,
    required this.paymentHistory,
  });

  String get formattedPremium =>
      '\$${(monthlyPremiumCents / 100).toStringAsFixed(2)}';

  String get formattedCoverage {
    final amount = coverageAmountCents / 100;
    if (amount >= 1000) {
      return '\$${(amount / 1000).toStringAsFixed(0)}K';
    }
    return '\$${amount.toStringAsFixed(0)}';
  }
}

// ── Color palette (shared with payment screens) ───────────────────────────────
class _K {
  static const background    = Color(0xFF0D0F14);
  static const surface       = Color(0xFF161A23);
  static const card          = Color(0xFF1C2130);
  static const gold          = Color(0xFFD4A847);
  static const goldLight     = Color(0xFFECC96A);
  static const goldDim       = Color(0xFF8A6E2F);
  static const textPrimary   = Color(0xFFF0EDE6);
  static const textSecondary = Color(0xFF8A8F9E);
  static const textMuted     = Color(0xFF4A4F60);
  static const success       = Color(0xFF3DAA6E);
  static const warning       = Color(0xFFD4853A);
  static const error         = Color(0xFFCC4444);
  static const divider       = Color(0xFF252A38);
}

// ── Screen ────────────────────────────────────────────────────────────────────
class PolicyDetailScreen extends StatefulWidget {
  final PolicyDetail policy;

  const PolicyDetailScreen({super.key, required this.policy});

  @override
  State<PolicyDetailScreen> createState() => _PolicyDetailScreenState();
}

class _PolicyDetailScreenState extends State<PolicyDetailScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late AnimationController _headerAnim;
  late Animation<double> _headerFade;
  late Animation<Offset> _headerSlide;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _headerAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
    _headerFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _headerAnim, curve: Curves.easeOut),
    );
    _headerSlide = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _headerAnim, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _tabController.dispose();
    _headerAnim.dispose();
    super.dispose();
  }

  void _navigateToPayment() {
    HapticFeedback.mediumImpact();
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, animation, __) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: PaymentScreen(
            args: PaymentArgs(
              memberId:    widget.policy.memberId,
              policyId:    widget.policy.policyId,
              memberName:  widget.policy.memberName,
              amountCents: widget.policy.monthlyPremiumCents,
              periodStart: widget.policy.nextPeriodStart,
              periodEnd:   widget.policy.nextPeriodEnd,
            ),
          ),
        ),
        transitionDuration: const Duration(milliseconds: 380),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final policy = widget.policy;
    return Scaffold(
      backgroundColor: _K.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: FadeTransition(
                opacity: _headerFade,
                child: SlideTransition(
                  position: _headerSlide,
                  child: Column(
                    children: [
                      _buildHeroCard(policy),
                      _buildTabBar(),
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            _buildOverviewTab(policy),
                            _buildBeneficiariesTab(policy),
                            _buildHistoryTab(policy),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _buildPayFooter(policy),
          ],
        ),
      ),
    );
  }

  // ── Top bar ───────────────────────────────────────────────────────────────
  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Row(
        children: [
          _iconButton(Icons.arrow_back_ios_new_rounded,
              () => Navigator.pop(context)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Policy Details',
                    style: TextStyle(
                        color: _K.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w600)),
                Text(widget.policy.policyId,
                    style: const TextStyle(
                        color: _K.textSecondary, fontSize: 12)),
              ],
            ),
          ),
          _iconButton(Icons.share_outlined, () {
            // TODO: share policy summary
          }),
        ],
      ),
    );
  }

  Widget _iconButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: _K.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _K.divider),
        ),
        child: Icon(icon, color: _K.textSecondary, size: 16),
      ),
    );
  }

  // ── Hero card ─────────────────────────────────────────────────────────────
  Widget _buildHeroCard(PolicyDetail policy) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E2438), Color(0xFF131621)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _K.goldDim.withOpacity(0.35)),
        boxShadow: [
          BoxShadow(
            color: _K.gold.withOpacity(0.07),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        children: [
          // Plan name + status badge
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      policy.planName,
                      style: const TextStyle(
                        color: _K.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Member · ${policy.memberName}',
                      style: const TextStyle(
                          color: _K.textSecondary, fontSize: 13),
                    ),
                  ],
                ),
              ),
              _statusBadge(policy.status),
            ],
          ),
          const SizedBox(height: 22),
          // Coverage + Premium stats
          Row(
            children: [
              Expanded(
                child: _statBlock(
                  label: 'Coverage',
                  value: policy.formattedCoverage,
                  icon: Icons.shield_outlined,
                ),
              ),
              Container(width: 1, height: 44, color: _K.divider),
              Expanded(
                child: _statBlock(
                  label: 'Monthly',
                  value: policy.formattedPremium,
                  icon: Icons.payments_outlined,
                ),
              ),
              Container(width: 1, height: 44, color: _K.divider),
              Expanded(
                child: _statBlock(
                  label: 'Since',
                  value: _shortDate(policy.startDate),
                  icon: Icons.calendar_month_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // Next due banner
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _K.gold.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _K.goldDim.withOpacity(0.4)),
            ),
            child: Row(
              children: [
                const Icon(Icons.access_time_rounded,
                    color: _K.gold, size: 15),
                const SizedBox(width: 8),
                Text(
                  'Next payment due ${_longDate(policy.nextDueDate)}',
                  style: const TextStyle(
                      color: _K.gold,
                      fontSize: 13,
                      fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statBlock(
      {required String label,
      required String value,
      required IconData icon}) {
    return Column(
      children: [
        Icon(icon, color: _K.goldDim, size: 18),
        const SizedBox(height: 6),
        Text(value,
            style: const TextStyle(
                color: _K.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.5)),
        const SizedBox(height: 2),
        Text(label,
            style:
                const TextStyle(color: _K.textSecondary, fontSize: 11)),
      ],
    );
  }

  Widget _statusBadge(PolicyStatus status) {
    final (label, color) = switch (status) {
      PolicyStatus.active    => ('Active', _K.success),
      PolicyStatus.pending   => ('Pending', _K.warning),
      PolicyStatus.lapsed    => ('Lapsed', _K.error),
      PolicyStatus.cancelled => ('Cancelled', _K.textMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                  shape: BoxShape.circle, color: color)),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ── Tab bar ───────────────────────────────────────────────────────────────
  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: _K.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _K.divider),
      ),
      child: TabBar(
        controller: _tabController,
        dividerColor: Colors.transparent,
        indicator: BoxDecoration(
          color: _K.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _K.goldDim.withOpacity(0.4)),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        labelColor: _K.gold,
        unselectedLabelColor: _K.textMuted,
        labelStyle: const TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
        tabs: const [
          Tab(text: 'Overview'),
          Tab(text: 'Beneficiaries'),
          Tab(text: 'History'),
        ],
      ),
    );
  }

  // ── Overview tab ──────────────────────────────────────────────────────────
  Widget _buildOverviewTab(PolicyDetail policy) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      children: [
        _sectionLabel('Policy Information'),
        const SizedBox(height: 12),
        _infoCard([
          _infoRow('Policy ID', policy.policyId),
          _infoRow('Plan', policy.planName),
          _infoRow('Status', _statusText(policy.status)),
          _infoRow('Start Date', _longDate(policy.startDate)),
          _infoRow('Coverage Amount', policy.formattedCoverage),
        ]),
        const SizedBox(height: 24),
        _sectionLabel('Premium Schedule'),
        const SizedBox(height: 12),
        _infoCard([
          _infoRow('Monthly Premium', policy.formattedPremium),
          _infoRow('Next Due Date', _longDate(policy.nextDueDate)),
          _infoRow('Coverage Period',
              '${_longDate(policy.nextPeriodStart)} – ${_longDate(policy.nextPeriodEnd)}'),
          _infoRow('Payment Method', 'Card on file'),
        ]),
        const SizedBox(height: 24),
        _sectionLabel('Coverage Summary'),
        const SizedBox(height: 12),
        _coverageTile(
          icon: Icons.family_restroom_rounded,
          title: 'Life Benefit',
          subtitle:
              'Paid to beneficiaries upon member\'s passing',
          amount: policy.formattedCoverage,
        ),
      ],
    );
  }

  // ── Beneficiaries tab ─────────────────────────────────────────────────────
  Widget _buildBeneficiariesTab(PolicyDetail policy) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      children: [
        _sectionLabel('Designated Beneficiaries'),
        const SizedBox(height: 12),
        ...policy.beneficiaries.map((b) => _beneficiaryCard(b)),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _K.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _K.divider),
          ),
          child: Row(
            children: const [
              Icon(Icons.info_outline_rounded,
                  color: _K.textMuted, size: 16),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'To update beneficiaries, contact your KAFA cooperative administrator.',
                  style: TextStyle(color: _K.textSecondary, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _beneficiaryCard(Beneficiary b) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _K.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _K.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: _K.goldDim.withOpacity(0.2),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _K.goldDim.withOpacity(0.4)),
            ),
            child: Center(
              child: Text(
                b.name.isNotEmpty ? b.name[0].toUpperCase() : '?',
                style: const TextStyle(
                    color: _K.gold,
                    fontSize: 18,
                    fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.name,
                    style: const TextStyle(
                        color: _K.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(b.relationship,
                    style: const TextStyle(
                        color: _K.textSecondary, fontSize: 13)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _K.goldDim.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${b.percentage}%',
              style: const TextStyle(
                  color: _K.gold,
                  fontSize: 13,
                  fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  // ── History tab ───────────────────────────────────────────────────────────
  Widget _buildHistoryTab(PolicyDetail policy) {
    if (policy.paymentHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.receipt_long_outlined,
                color: _K.textMuted, size: 40),
            SizedBox(height: 12),
            Text('No payments yet',
                style: TextStyle(color: _K.textMuted, fontSize: 15)),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
      children: [
        _sectionLabel('Payment History'),
        const SizedBox(height: 12),
        ...policy.paymentHistory.map((p) => _historyRow(p)),
      ],
    );
  }

  Widget _historyRow(PaymentHistory p) {
    final (color, icon) = switch (p.status) {
      'SUCCEEDED' => (_K.success, Icons.check_circle_outline_rounded),
      'FAILED'    => (_K.error, Icons.cancel_outlined),
      _           => (_K.warning, Icons.pending_outlined),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _K.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _K.divider),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.period,
                    style: const TextStyle(
                        color: _K.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text('${p.date} · ${p.paymentId}',
                    style: const TextStyle(
                        color: _K.textMuted, fontSize: 11)),
              ],
            ),
          ),
          Text(p.formattedAmount,
              style: const TextStyle(
                  color: _K.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ── Pay footer ────────────────────────────────────────────────────────────
  Widget _buildPayFooter(PolicyDetail policy) {
    final isActive = policy.status == PolicyStatus.active ||
        policy.status == PolicyStatus.pending;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
      decoration: BoxDecoration(
        color: _K.background,
        border: const Border(
            top: BorderSide(color: _K.divider, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isActive) ...[
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: _K.error.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: _K.error.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: _K.error, size: 16),
                  SizedBox(width: 8),
                  Text(
                    'This policy is not active. Contact your administrator.',
                    style: TextStyle(color: _K.error, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Due now',
                      style: TextStyle(
                          color: _K.textMuted, fontSize: 12)),
                  Text(
                    policy.formattedPremium,
                    style: const TextStyle(
                      color: _K.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              Expanded(
                child: GestureDetector(
                  onTap: isActive ? _navigateToPayment : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    height: 52,
                    decoration: BoxDecoration(
                      gradient: isActive
                          ? const LinearGradient(
                              colors: [_K.gold, _K.goldLight],
                            )
                          : null,
                      color: isActive ? null : _K.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: isActive
                          ? null
                          : Border.all(color: _K.divider),
                      boxShadow: isActive
                          ? [
                              BoxShadow(
                                color: _K.gold.withOpacity(0.28),
                                blurRadius: 14,
                                offset: const Offset(0, 5),
                              ),
                            ]
                          : [],
                    ),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.credit_card_rounded,
                            color: isActive
                                ? _K.background
                                : _K.textMuted,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Pay Premium',
                            style: TextStyle(
                              color: isActive
                                  ? _K.background
                                  : _K.textMuted,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Shared widgets ────────────────────────────────────────────────────────
  Widget _sectionLabel(String text) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: _K.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      );

  Widget _infoCard(List<Widget> rows) => Container(
        decoration: BoxDecoration(
          color: _K.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _K.divider),
        ),
        child: Column(
          children: rows
              .expand((w) sync* {
                yield w;
                if (w != rows.last) {
                  yield const Divider(
                      color: _K.divider, height: 1, thickness: 1);
                }
              })
              .toList(),
        ),
      );

  Widget _infoRow(String label, String value) => Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      color: _K.textSecondary, fontSize: 13)),
            ),
            Text(value,
                style: const TextStyle(
                    color: _K.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      );

  Widget _coverageTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required String amount,
  }) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _K.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _K.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: _K.goldDim.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: _K.gold, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: _K.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: const TextStyle(
                          color: _K.textSecondary, fontSize: 12)),
                ],
              ),
            ),
            Text(amount,
                style: const TextStyle(
                    color: _K.gold,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ],
        ),
      );

  // ── Formatters ────────────────────────────────────────────────────────────
  String _shortDate(String iso) {
    try {
      final p = iso.split('-');
      const m = [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${m[int.parse(p[1])]} ${p[0]}';
    } catch (_) {
      return iso;
    }
  }

  String _longDate(String iso) {
    try {
      final p = iso.split('-');
      const m = [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${m[int.parse(p[1])]} ${int.parse(p[2])}, ${p[0]}';
    } catch (_) {
      return iso;
    }
  }

  String _statusText(PolicyStatus s) => switch (s) {
        PolicyStatus.active    => 'Active',
        PolicyStatus.pending   => 'Pending',
        PolicyStatus.lapsed    => 'Lapsed',
        PolicyStatus.cancelled => 'Cancelled',
      };
}