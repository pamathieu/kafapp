import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'payment_screen.dart';

// Reuse palette from payment_screen.dart (copy here for self-containment)
class _C {
  static const background    = Color(0xFF0D0F14);
  static const surface       = Color(0xFF161A23);
  static const gold          = Color(0xFFD4A847);
  static const goldLight     = Color(0xFFECC96A);
  static const goldDim       = Color(0xFF8A6E2F);
  static const textPrimary   = Color(0xFFF0EDE6);
  static const textSecondary = Color(0xFF8A8F9E);
  static const textMuted     = Color(0xFF4A4F60);
  static const success       = Color(0xFF3DAA6E);
  static const divider       = Color(0xFF252A38);
}

class PaymentConfirmationScreen extends StatefulWidget {
  final PaymentArgs args;
  final String paymentId;

  const PaymentConfirmationScreen({
    super.key,
    required this.args,
    required this.paymentId,
  });

  @override
  State<PaymentConfirmationScreen> createState() =>
      _PaymentConfirmationScreenState();
}

class _PaymentConfirmationScreenState extends State<PaymentConfirmationScreen>
    with TickerProviderStateMixin {
  late AnimationController _checkController;
  late AnimationController _ringController;
  late AnimationController _contentController;

  late Animation<double> _checkScale;
  late Animation<double> _checkOpacity;
  late Animation<double> _ringScale;
  late Animation<double> _ringOpacity;
  late Animation<double> _contentSlide;
  late Animation<double> _contentOpacity;

  @override
  void initState() {
    super.initState();

    _checkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _contentController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );

    _checkScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _checkController, curve: Curves.elasticOut),
    );
    _checkOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
          parent: _checkController,
          curve: const Interval(0.0, 0.4, curve: Curves.easeIn)),
    );
    _ringScale = Tween<double>(begin: 0.5, end: 1.4).animate(
      CurvedAnimation(parent: _ringController, curve: Curves.easeOut),
    );
    _ringOpacity = Tween<double>(begin: 0.6, end: 0.0).animate(
      CurvedAnimation(parent: _ringController, curve: Curves.easeOut),
    );
    _contentSlide = Tween<double>(begin: 30, end: 0).animate(
      CurvedAnimation(parent: _contentController, curve: Curves.easeOutCubic),
    );
    _contentOpacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _contentController, curve: Curves.easeIn),
    );

    // Staggered animation sequence
    Future.delayed(const Duration(milliseconds: 200), () {
      _checkController.forward();
      _ringController.forward();
    });
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _contentController.forward();
    });
  }

  @override
  void dispose() {
    _checkController.dispose();
    _ringController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _C.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 60),
              _buildSuccessIcon(),
              const SizedBox(height: 36),
              _buildConfirmationContent(),
              const Spacer(),
              _buildActions(),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  // ── Animated checkmark ────────────────────────────────────────────────────
  Widget _buildSuccessIcon() {
    return SizedBox(
      width: 100,
      height: 100,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Ripple ring
          AnimatedBuilder(
            animation: _ringController,
            builder: (_, __) => Transform.scale(
              scale: _ringScale.value,
              child: Opacity(
                opacity: _ringOpacity.value,
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _C.success,
                      width: 2,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Check circle
          AnimatedBuilder(
            animation: _checkController,
            builder: (_, __) => Transform.scale(
              scale: _checkScale.value,
              child: Opacity(
                opacity: _checkOpacity.value,
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _C.success.withOpacity(0.15),
                    border: Border.all(color: _C.success, width: 2),
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: _C.success,
                    size: 36,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Content ───────────────────────────────────────────────────────────────
  Widget _buildConfirmationContent() {
    return AnimatedBuilder(
      animation: _contentController,
      builder: (_, child) => Transform.translate(
        offset: Offset(0, _contentSlide.value),
        child: Opacity(opacity: _contentOpacity.value, child: child),
      ),
      child: Column(
        children: [
          const Text(
            'Payment Confirmed',
            style: TextStyle(
              color: _C.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w300,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.args.formattedAmount,
            style: const TextStyle(
              color: _C.gold,
              fontSize: 44,
              fontWeight: FontWeight.w700,
              letterSpacing: -2,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 24),
          _buildDetailCard(),
        ],
      ),
    );
  }

  Widget _buildDetailCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _C.divider),
      ),
      child: Column(
        children: [
          _buildDetailRow('Payment ID', widget.paymentId),
          _buildDivider(),
          _buildDetailRow('Policy', widget.args.policyId),
          _buildDivider(),
          _buildDetailRow('Member', widget.args.memberName),
          _buildDivider(),
          _buildDetailRow(
            'Coverage',
            '${_fmt(widget.args.periodStart)} – ${_fmt(widget.args.periodEnd)}',
          ),
          _buildDivider(),
          _buildDetailRow('Status', 'Confirmed', isStatus: true),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value,
      {bool isStatus = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  color: _C.textSecondary, fontSize: 13)),
          isStatus
              ? Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: _C.success.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: _C.success.withOpacity(0.4)),
                  ),
                  child: Text(
                    value,
                    style: const TextStyle(
                        color: _C.success,
                        fontSize: 12,
                        fontWeight: FontWeight.w600),
                  ),
                )
              : Text(
                  value,
                  style: const TextStyle(
                    color: _C.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
        ],
      ),
    );
  }

  Widget _buildDivider() =>
      const Divider(color: _C.divider, height: 1, thickness: 1);

  // ── Actions ───────────────────────────────────────────────────────────────
  Widget _buildActions() {
    return AnimatedBuilder(
      animation: _contentController,
      builder: (_, child) => Opacity(
        opacity: _contentOpacity.value,
        child: child,
      ),
      child: Column(
        children: [
          // Primary: back to dashboard
          GestureDetector(
            onTap: () => Navigator.of(context).popUntil((r) => r.isFirst),
            child: Container(
              width: double.infinity,
              height: 54,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [_C.gold, _C.goldLight],
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: _C.gold.withOpacity(0.25),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: const Center(
                child: Text(
                  'Back to Dashboard',
                  style: TextStyle(
                    color: _C.background,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          // Secondary: view receipt (opens Stripe receipt URL if available)
          GestureDetector(
            onTap: () {
              // TODO: launch(receiptUrl) via url_launcher
            },
            child: Container(
              width: double.infinity,
              height: 50,
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _C.divider),
              ),
              child: const Center(
                child: Text(
                  'View Receipt',
                  style: TextStyle(
                    color: _C.textSecondary,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(String iso) {
    try {
      final p = iso.split('-');
      const m = [
        '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${m[int.parse(p[1])]} ${int.parse(p[2])}';
    } catch (_) {
      return iso;
    }
  }
}
