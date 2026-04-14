import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import '../services/payment_service.dart';
import 'payment_confirmation_screen.dart';

/// Data passed into the payment screen from the member's policy view.
class PaymentArgs {
  final String memberId;
  final String policyId;
  final String memberName;
  final int amountCents;
  final String periodStart;
  final String periodEnd;
  final String currency;

  const PaymentArgs({
    required this.memberId,
    required this.policyId,
    required this.memberName,
    required this.amountCents,
    required this.periodStart,
    required this.periodEnd,
    this.currency = 'usd',
  });

  String get formattedAmount {
    final dollars = amountCents / 100;
    return '\$${dollars.toStringAsFixed(2)}';
  }
}

// ── Color palette ─────────────────────────────────────────────────────────────
class _KafaColors {
  static const background   = Color(0xFF0D0F14);
  static const surface      = Color(0xFF161A23);
  static const card         = Color(0xFF1C2130);
  static const gold         = Color(0xFFD4A847);
  static const goldLight    = Color(0xFFECC96A);
  static const goldDim      = Color(0xFF8A6E2F);
  static const textPrimary  = Color(0xFFF0EDE6);
  static const textSecondary = Color(0xFF8A8F9E);
  static const textMuted    = Color(0xFF4A4F60);
  static const success      = Color(0xFF3DAA6E);
  static const error        = Color(0xFFCC4444);
  static const divider      = Color(0xFF252A38);
}

class PaymentScreen extends StatefulWidget {
  final PaymentArgs args;

  const PaymentScreen({super.key, required this.args});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen>
    with SingleTickerProviderStateMixin {
  final _paymentService = PaymentService();
  bool _isProcessing = false;
  String? _cardError;
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _handlePayment() async {
    setState(() {
      _isProcessing = true;
      _cardError = null;
    });
    HapticFeedback.lightImpact();

    final result = await _paymentService.processPayment(
      memberId: widget.args.memberId,
      policyId: widget.args.policyId,
      amountCents: widget.args.amountCents,
      periodStart: widget.args.periodStart,
      periodEnd: widget.args.periodEnd,
      currency: widget.args.currency,
    );

    if (!mounted) return;

    if (result.success) {
      HapticFeedback.mediumImpact();
      await Navigator.pushReplacement(
        context,
        PageRouteBuilder(
          pageBuilder: (_, animation, __) => FadeTransition(
            opacity: animation,
            child: PaymentConfirmationScreen(
              args: widget.args,
              paymentId: result.paymentId!,
            ),
          ),
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _isProcessing = false;
        _cardError = result.errorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _KafaColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 28),
                    _buildAmountCard(),
                    const SizedBox(height: 28),
                    _buildSectionLabel('Card Details'),
                    const SizedBox(height: 12),
                    _buildCardField(),
                    if (_cardError != null) ...[
                      const SizedBox(height: 10),
                      _buildErrorBanner(_cardError!),
                    ],
                    const SizedBox(height: 28),
                    _buildSectionLabel('Coverage Period'),
                    const SizedBox(height: 12),
                    _buildPeriodRow(),
                    const SizedBox(height: 36),
                    _buildPayButton(),
                    const SizedBox(height: 20),
                    _buildSecurityNote(),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: _KafaColors.divider, width: 1),
        ),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: _KafaColors.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _KafaColors.divider),
              ),
              child: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: _KafaColors.textSecondary,
                size: 16,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Pay Premium',
                style: TextStyle(
                  color: _KafaColors.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
              Text(
                widget.args.memberName,
                style: const TextStyle(
                  color: _KafaColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
          const Spacer(),
          // KAFA gold emblem
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              gradient: const RadialGradient(
                colors: [_KafaColors.goldLight, _KafaColors.goldDim],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Center(
              child: Text(
                'K',
                style: TextStyle(
                  color: _KafaColors.background,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Amount card ───────────────────────────────────────────────────────────
  Widget _buildAmountCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1E2235), Color(0xFF161A23)],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _KafaColors.goldDim.withOpacity(0.4)),
        boxShadow: [
          BoxShadow(
            color: _KafaColors.gold.withOpacity(0.06),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _KafaColors.goldDim.withOpacity(0.25),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: _KafaColors.goldDim.withOpacity(0.5)),
                ),
                child: const Text(
                  'Monthly Premium',
                  style: TextStyle(
                    color: _KafaColors.gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            widget.args.formattedAmount,
            style: const TextStyle(
              color: _KafaColors.textPrimary,
              fontSize: 42,
              fontWeight: FontWeight.w300,
              letterSpacing: -1.5,
              height: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Policy · ${widget.args.policyId}',
            style: const TextStyle(
              color: _KafaColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  // ── Card field ────────────────────────────────────────────────────────────
  Widget _buildCardField() {
    return Container(
      decoration: BoxDecoration(
        color: _KafaColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _cardError != null
              ? _KafaColors.error.withOpacity(0.6)
              : _KafaColors.divider,
        ),
      ),
      child: CardField(
        onCardChanged: (details) {
          if (_cardError != null && details != null) {
            setState(() => _cardError = null);
          }
        },
        decoration: const InputDecoration(
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        style: const TextStyle(
          color: _KafaColors.textPrimary,
          fontSize: 15,
        ),
      ),
    );
  }

  // ── Period row ────────────────────────────────────────────────────────────
  Widget _buildPeriodRow() {
    return Row(
      children: [
        Expanded(
          child: _buildInfoTile(
            label: 'From',
            value: _formatDate(widget.args.periodStart),
            icon: Icons.calendar_today_rounded,
          ),
        ),
        const SizedBox(width: 12),
        const Icon(Icons.arrow_forward_rounded,
            color: _KafaColors.textMuted, size: 16),
        const SizedBox(width: 12),
        Expanded(
          child: _buildInfoTile(
            label: 'To',
            value: _formatDate(widget.args.periodEnd),
            icon: Icons.event_rounded,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoTile({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _KafaColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _KafaColors.divider),
      ),
      child: Row(
        children: [
          Icon(icon, color: _KafaColors.goldDim, size: 15),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      color: _KafaColors.textMuted, fontSize: 11)),
              const SizedBox(height: 2),
              Text(value,
                  style: const TextStyle(
                      color: _KafaColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
            ],
          ),
        ],
      ),
    );
  }

  // ── Pay button ────────────────────────────────────────────────────────────
  Widget _buildPayButton() {
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (_, child) {
        return GestureDetector(
          onTap: _isProcessing ? null : _handlePayment,
          child: Container(
            width: double.infinity,
            height: 56,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: _isProcessing
                    ? [_KafaColors.goldDim, _KafaColors.goldDim]
                    : [_KafaColors.gold, _KafaColors.goldLight],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: _isProcessing
                  ? []
                  : [
                      BoxShadow(
                        color: _KafaColors.gold
                            .withOpacity(0.3 * _pulseAnim.value),
                        blurRadius: 20,
                        offset: const Offset(0, 6),
                      ),
                    ],
            ),
            child: Center(
              child: _isProcessing
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        valueColor: AlwaysStoppedAnimation(_KafaColors.background),
                      ),
                    )
                  : Text(
                      'Pay ${widget.args.formattedAmount}',
                      style: const TextStyle(
                        color: _KafaColors.background,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.3,
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }

  // ── Error banner ──────────────────────────────────────────────────────────
  Widget _buildErrorBanner(String message) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _KafaColors.error.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _KafaColors.error.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              color: _KafaColors.error, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                  color: _KafaColors.error, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // ── Security note ─────────────────────────────────────────────────────────
  Widget _buildSecurityNote() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        Icon(Icons.lock_outline_rounded,
            color: _KafaColors.textMuted, size: 13),
        SizedBox(width: 6),
        Text(
          'Secured by Stripe · PCI DSS Level 1',
          style: TextStyle(color: _KafaColors.textMuted, fontSize: 12),
        ),
      ],
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  Widget _buildSectionLabel(String label) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: _KafaColors.textMuted,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }

  String _formatDate(String iso) {
    // "2026-04-01" → "Apr 1, 2026"
    try {
      final parts = iso.split('-');
      final months = [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      final month = months[int.parse(parts[1])];
      final day = int.parse(parts[2]);
      return '$month $day, ${parts[0]}';
    } catch (_) {
      return iso;
    }
  }
}
