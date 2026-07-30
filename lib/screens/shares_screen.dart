import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../services/share_service.dart';
import '../stripe_web_helper.dart'
    if (dart.library.html) '../stripe_web_helper_web.dart';

class _KafaColors {
  static const background = Color(0xFFF2F4F7);
  static const surface = Color(0xFFFFFFFF);
  static const green = Color(0xFF1A5C2A);
  static const gold = Color(0xFFC8A96E);
  static const textPrimary = Color(0xFF1A1A1A);
  static const textSecondary = Color(0xFF6B7280);
  static const textMuted = Color(0xFF9CA3AF);
  static const error = Color(0xFFDC2626);
  static const divider = Color(0xFFE5E7EB);
}

class SharesScreen extends StatefulWidget {
  final String memberId;
  final String memberName;
  final bool isPending;

  const SharesScreen({
    super.key,
    required this.memberId,
    required this.memberName,
    required this.isPending,
  });

  @override
  State<SharesScreen> createState() => _SharesScreenState();
}

class _SharesScreenState extends State<SharesScreen>
    with TickerProviderStateMixin {
  final _shareService = ShareService();
  final _amountCtrl = TextEditingController();

  late AnimationController _checkController;
  late AnimationController _ringController;
  late AnimationController _contentController;

  late Animation<double> _checkScale;
  late Animation<double> _checkOpacity;
  late Animation<double> _ringScale;
  late Animation<double> _ringOpacity;
  late Animation<double> _contentSlide;
  late Animation<double> _contentOpacity;

  String _shareType = 'membership'; // 'membership' | 'preferred'
  bool _isProcessing = false;
  String? _error;
  bool _success = false;
  double? _resultApr;

  // Derived from live share records — starts conservatively from widget.isPending,
  // updated once the share list loads. This fixes the Stripe webhook timing gap:
  // after a membership share payment the webhook may not have fired yet, but the
  // PENDING record already exists and is enough to unlock preferred shares.
  bool _isPending = true;
  bool _sharesChecked = false;

  @override
  void initState() {
    super.initState();
    _isPending = widget.isPending;
    if (widget.isPending) _shareType = 'membership';
    if (kIsWeb) {
      const pk = String.fromEnvironment('STRIPE_KEY', defaultValue: '');
      if (pk.isNotEmpty) registerStripeCardViewFactory(pk);
    }
    _checkShareEligibility();

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
  }

  Future<void> _checkShareEligibility() async {
    if (!widget.isPending) {
      setState(() => _sharesChecked = true);
      return;
    }
    try {
      final shares = await _shareService.getShares(widget.memberId);
      // Only unlock Preferred once the member has SUCCEEDED membership shares
      // totalling $50 or more. A partial payment (e.g. $10) must still keep
      // the Preferred tab greyed out.
      final membershipTotal = shares
          .where((s) =>
              (s['shareType'] as String? ??
                      s['share_type'] as String? ?? '')
                  .toLowerCase() == 'membership' &&
              (s['status'] as String? ?? '').toUpperCase() == 'SUCCEEDED')
          .fold<double>(
              0.0,
              (sum, s) =>
                  sum + ((s['amount'] as num?)?.toDouble() ?? 0.0));
      if (mounted) {
        setState(() {
          _isPending = membershipTotal < 50.0;
          _sharesChecked = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _sharesChecked = true);
    }
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _checkController.dispose();
    _ringController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  int? get _amountCents {
    final dollars = double.tryParse(_amountCtrl.text.trim());
    if (dollars == null) return null;
    return (dollars * 100).round();
  }

  String? _validateAmount() {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    final cents = _amountCents;
    if (cents == null) return s('enterAnAmount');
    if (_shareType == 'membership') {
      if (cents < 100) {
        return s('membershipMinError');
      }
    } else {
      if (cents < 50000) {
        return s('preferredMinError');
      }
    }
    return null;
  }

  double get _previewApr =>
      _shareType == 'membership' ? 0.0 : previewPreferredApr(_amountCents ?? 0);

  Future<void> _handlePurchase() async {
    final validationError = _validateAmount();
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }

    setState(() {
      _isProcessing = true;
      _error = null;
    });
    HapticFeedback.lightImpact();

    final result = await _shareService.purchaseShare(
      memberId: widget.memberId,
      shareType: _shareType,
      amountCents: _amountCents!,
    );

    if (!mounted) return;

    if (result.success) {
      HapticFeedback.mediumImpact();
      setState(() {
        _isProcessing = false;
        _success = true;
        _resultApr = result.apr;
      });
      Future.delayed(const Duration(milliseconds: 200), () {
        _checkController.forward();
        _ringController.forward();
      });
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) _contentController.forward();
      });
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _isProcessing = false;
        _error = result.errorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    if (_success) return _buildSuccess();

    return Scaffold(
      backgroundColor: _KafaColors.background,
      appBar: AppBar(
        backgroundColor: _KafaColors.green,
        foregroundColor: Colors.white,
        title: Text(s('buySharesTitle')),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildShareTypeSelector(s),
              const SizedBox(height: 20),
              _buildAmountField(s),
              if (_shareType == 'preferred') ...[
                const SizedBox(height: 16),
                _buildAprPreview(s),
              ],
              const SizedBox(height: 24),
              _buildSectionLabel(s('cardDetails')),
              const SizedBox(height: 12),
              _buildCardFields(),
              if (_error != null) ...[
                const SizedBox(height: 10),
                _buildErrorBanner(_error!),
              ],
              const SizedBox(height: 32),
              _buildPurchaseButton(s),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildShareTypeSelector(String Function(String) s) {
    return Row(
      children: [
        Expanded(
          child: _TypeChip(
            label: s('shareMembership'),
            selected: _shareType == 'membership',
            onTap: () => setState(() => _shareType = 'membership'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _TypeChip(
            label: s('sharePreferred'),
            selected: _shareType == 'preferred',
            enabled: !_isPending,
            onTap: _isPending
                ? null
                : () => setState(() => _shareType = 'preferred'),
          ),
        ),
      ],
    );
  }

  Widget _buildAmountField(String Function(String) s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionLabel(_shareType == 'membership'
            ? s('amountMembershipHint')
            : s('amountPreferredHint')),
        const SizedBox(height: 8),
        TextField(
          controller: _amountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            prefixText: '\$ ',
            filled: true,
            fillColor: _KafaColors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: _KafaColors.divider),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAprPreview(String Function(String) s) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _KafaColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _KafaColors.divider),
      ),
      child: Row(
        children: [
          const Icon(Icons.percent, color: _KafaColors.green, size: 18),
          const SizedBox(width: 10),
          Text('${s('aprPrefix')}${_previewApr.toStringAsFixed(2)}%',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String text) => Text(
        text,
        style: const TextStyle(
          color: _KafaColors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      );

  Widget _buildCardFields() {
    if (!kIsWeb) {
      return Container(
        height: 54,
        decoration: BoxDecoration(
          color: _KafaColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _KafaColors.divider),
        ),
        child: CardField(
          decoration: const InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      );
    }
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
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
        Text(label,
            style: const TextStyle(
                color: _KafaColors.textMuted, fontSize: 11, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: _KafaColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _KafaColors.divider),
          ),
          child: MouseRegion(cursor: SystemMouseCursors.text, child: field),
        ),
      ],
    );
  }

  Widget _buildErrorBanner(String message) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _KafaColors.error.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: _KafaColors.error, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: const TextStyle(color: _KafaColors.error))),
          ],
        ),
      );

  Widget _buildPurchaseButton(String Function(String) s) {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton(
        onPressed: _isProcessing ? null : _handlePurchase,
        style: ElevatedButton.styleFrom(
          backgroundColor: _KafaColors.gold,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: _isProcessing
            ? const SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : Text(_shareType == 'membership' ? s('buyMembershipBtn') : s('buyPreferredBtn')),
      ),
    );
  }

  Widget _buildSuccess() {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    return Scaffold(
      backgroundColor: _KafaColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 60),
              _buildSuccessIcon(),
              const SizedBox(height: 36),
              _buildSuccessContent(s),
              const Spacer(),
              _buildSuccessActions(s),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSuccessIcon() {
    return SizedBox(
      width: 100,
      height: 100,
      child: Stack(
        alignment: Alignment.center,
        children: [
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
                    border: Border.all(color: _KafaColors.green, width: 2),
                  ),
                ),
              ),
            ),
          ),
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
                    color: _KafaColors.green.withValues(alpha: 0.1),
                    border: Border.all(color: _KafaColors.green, width: 2),
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    color: _KafaColors.green,
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

  Widget _buildSuccessContent(String Function(String) s) {
    return AnimatedBuilder(
      animation: _contentController,
      builder: (_, child) => Transform.translate(
        offset: Offset(0, _contentSlide.value),
        child: Opacity(opacity: _contentOpacity.value, child: child),
      ),
      child: Column(
        children: [
          Text(
            s('sharePurchased'),
            style: const TextStyle(
              color: _KafaColors.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
            ),
          ),
          if (_resultApr != null && _resultApr! > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${s('aprPrefix')}${_resultApr!.toStringAsFixed(2)}%',
              style: const TextStyle(
                color: _KafaColors.green,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuccessActions(String Function(String) s) {
    return AnimatedBuilder(
      animation: _contentController,
      builder: (_, child) =>
          Opacity(opacity: _contentOpacity.value, child: child!),
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(true),
        child: Container(
          width: double.infinity,
          height: 54,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1A5C2A), Color(0xFF236B35)],
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: _KafaColors.green.withValues(alpha: 0.25),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Center(
            child: Text(
              s('done'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  const _TypeChip({
    required this.label,
    required this.selected,
    this.enabled = true,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? _KafaColors.green : _KafaColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: selected ? _KafaColors.green : _KafaColors.divider),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : _KafaColors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
