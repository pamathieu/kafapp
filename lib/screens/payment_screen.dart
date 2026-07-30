import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../services/payment_service.dart';
import '../stripe_web_helper.dart'
    if (dart.library.html) '../stripe_web_helper_web.dart';
import 'payment_confirmation_screen.dart';

/// If [dueDate] is today or in the past, return the 1st of next month for
/// display only — the backend still receives the original date so that
/// nextDueDate advancement stays correct.
String _displayDueDate(String dueDate) {
  if (dueDate.isEmpty) return dueDate;
  final due = DateTime.tryParse(dueDate);
  if (due == null) return dueDate;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  if (due.isAfter(today)) return dueDate;
  final next = DateTime(now.year, now.month + 1, 1);
  return '${next.year}-${next.month.toString().padLeft(2, '0')}-01';
}

/// Annual premium lookup, by plan code, from the KAFA plan catalog.
/// Mirrors the pricing shown on the Plans & Coverage screen.
const _annualPremiumsCents = {
  'BASIC':    12000, // US$120/yr
  'STANDARD': 24000, // US$240/yr
};

/// Maps a policy's productCode (e.g. "LIFE-BASIC") to its plan catalog code.
String? _planCodeFromProductCode(String productCode) {
  final upper = productCode.toUpperCase();
  if (upper.contains('BASIC'))    return 'BASIC';
  if (upper.contains('STANDARD')) return 'STANDARD';
  return null;
}

/// Data passed into the payment screen from the member's policy view.
class PaymentArgs {
  final String memberId;
  final String policyId;
  final String memberName;
  final int amountCents;
  final String periodStart;
  final String periodEnd;
  final String currency;
  final String? productCode;

  const PaymentArgs({
    required this.memberId,
    required this.policyId,
    required this.memberName,
    required this.amountCents,
    required this.periodStart,
    required this.periodEnd,
    this.currency = 'usd',
    this.productCode,
  });

  /// The annual amount for this policy's plan, if known.
  int? get annualAmountCents {
    final code = productCode;
    if (code == null) return null;
    final planCode = _planCodeFromProductCode(code);
    if (planCode == null) return null;
    return _annualPremiumsCents[planCode];
  }

  String formattedAmount(int cents) {
    final amount = cents / 100;
    final symbol = currency.toLowerCase() == 'usd' ? 'US\$' : 'HTG ';
    return '$symbol${amount.toStringAsFixed(2)}';
  }
}

// ── Color palette ─────────────────────────────────────────────────────────────
class _KafaColors {
  static const background    = Color(0xFFF2F4F7);
  static const surface       = Color(0xFFFFFFFF);
  static const green         = Color(0xFF1A5C2A);
  static const greenLight    = Color(0xFF236B35);
  static const textPrimary   = Color(0xFF1A1A1A);
  static const textSecondary = Color(0xFF6B7280);
  static const textMuted     = Color(0xFF9CA3AF);
  static const error         = Color(0xFFDC2626);
  static const divider       = Color(0xFFE5E7EB);
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
  bool _annual = false; // false = monthly (default), true = annual billing
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  /// The amount actually being charged, based on the selected billing frequency.
  int get _chargeAmountCents =>
      _annual ? (widget.args.annualAmountCents ?? widget.args.amountCents * 12)
              : widget.args.amountCents;

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
    if (kIsWeb) {
      const pk = String.fromEnvironment('STRIPE_KEY', defaultValue: '');
      if (pk.isNotEmpty) registerStripeCardViewFactory(pk);
    }
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
      amountCents: _chargeAmountCents,
      periodStart: widget.args.periodStart,
      periodEnd: widget.args.periodEnd,
      currency: widget.args.currency,
    );

    if (!mounted) return;

    if (result.success) {
      HapticFeedback.mediumImpact();
      await Navigator.pushReplacement(
        context,
        PageRouteBuilder<void>(
          pageBuilder: (_, animation, __) => FadeTransition(
            opacity: animation,
            child: PaymentConfirmationScreen(
              args: widget.args,
              paymentId: result.paymentId!,
              chargedAmountCents: _chargeAmountCents,
            ),
          ),
          transitionDuration: const Duration(milliseconds: 500),
        ),
        result: true,
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
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    return Scaffold(
      backgroundColor: _KafaColors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(s),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 28),
                    _buildAmountCard(s),
                    if (widget.args.annualAmountCents != null) ...[
                      const SizedBox(height: 20),
                      _buildFrequencySelector(s),
                    ],
                    const SizedBox(height: 28),
                    _buildSectionLabel(s('cardDetails')),
                    const SizedBox(height: 12),
                    _buildCardFields(s),
                    if (_cardError != null) ...[
                      const SizedBox(height: 10),
                      _buildErrorBanner(_cardError!),
                    ],
                    if (widget.args.periodEnd.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      _buildSectionLabel(s('dueDate')),
                      const SizedBox(height: 12),
                      _buildInfoTile(
                        label: s('nextPaymentDue'),
                        value: AppStrings.formatDate(
                            _displayDueDate(widget.args.periodEnd), locale),
                        icon: Icons.calendar_today_rounded,
                      ),
                    ],
                    const SizedBox(height: 36),
                    _buildPayButton(s),
                    const SizedBox(height: 20),
                    _buildSecurityNote(s),
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
  Widget _buildHeader(String Function(String) s) {
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
                s('payPremium'),
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
              color: _KafaColors.green,
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
  Widget _buildAmountCard(String Function(String) s) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A5C2A), Color(0xFF236B35)],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _KafaColors.green.withValues(alpha: 0.2),
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
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _annual ? s('annualPremium') : s('monthlyPremium'),
                  style: const TextStyle(
                    color: Colors.white,
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
            widget.args.formattedAmount(_chargeAmountCents),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 42,
              fontWeight: FontWeight.w300,
              letterSpacing: -1.5,
              height: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${s('policyLabel')} · ${widget.args.policyId}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  // ── Billing frequency selector ──────────────────────────────────────────
  Widget _buildFrequencySelector(String Function(String) s) {
    Widget segment(String label, bool isAnnual) {
      final selected = _annual == isAnnual;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _annual = isAnnual),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? _KafaColors.green : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: selected ? Colors.white : _KafaColors.textSecondary)),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _KafaColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _KafaColors.divider),
      ),
      child: Row(children: [
        segment(s('monthly'), false),
        segment(s('annual'), true),
      ]),
    );
  }

  // ── Card fields ───────────────────────────────────────────────────────────
  Widget _buildCardFields(String Function(String) s) {
    if (!kIsWeb) {
      // Native: single combined CardField
      return Container(
        height: 54,
        decoration: BoxDecoration(
          color: _KafaColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _cardError != null
                ? _KafaColors.error.withValues(alpha: 0.6)
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
          style: const TextStyle(color: _KafaColors.textPrimary, fontSize: 15),
        ),
      );
    }
    // Web: three separate Stripe elements
    return Column(
      children: [
        _buildStripeField(s('cardNumber'), stripeCardHtmlView()),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildStripeField(s('expiry'), stripeExpiryHtmlView())),
            const SizedBox(width: 12),
            Expanded(child: _buildStripeField(s('cvc'), stripeCvcHtmlView())),
          ],
        ),
      ],
    );
  }

  Widget _buildStripeField(String label, Widget field) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: _KafaColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: _KafaColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _KafaColors.divider),
          ),
          child: MouseRegion(
            cursor: SystemMouseCursors.text,
            child: field,
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
          Icon(icon, color: _KafaColors.green, size: 15),
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
  Widget _buildPayButton(String Function(String) s) {
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
                    ? [_KafaColors.greenLight, _KafaColors.greenLight]
                    : [_KafaColors.green, _KafaColors.greenLight],
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(14),
              boxShadow: _isProcessing
                  ? []
                  : [
                      BoxShadow(
                        color: _KafaColors.green
                            .withValues(alpha: 0.3 * _pulseAnim.value),
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
                      '${s('payAmountPrefix')}${widget.args.formattedAmount(_chargeAmountCents)}',
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
        color: _KafaColors.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _KafaColors.error.withValues(alpha: 0.4)),
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
  Widget _buildSecurityNote(String Function(String) s) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.lock_outline_rounded,
            color: _KafaColors.textMuted, size: 13),
        const SizedBox(width: 6),
        Text(
          s('securedByStripe'),
          style: const TextStyle(color: _KafaColors.textMuted, fontSize: 12),
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

}
