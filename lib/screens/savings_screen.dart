import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../services/savings_service.dart';
import '../stripe_web_helper.dart'
    if (dart.library.html) '../stripe_web_helper_web.dart';

class SavingsScreen extends StatefulWidget {
  final Map<String, dynamic> member;
  final bool embedded;
  const SavingsScreen({super.key, required this.member, this.embedded = false});

  @override
  State<SavingsScreen> createState() => _SavingsScreenState();
}

class _SavingsScreenState extends State<SavingsScreen> {
  final _savingsService = SavingsService();

  double _balance = 0;
  List<Map<String, dynamic>> _deposits = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      const pk = String.fromEnvironment('STRIPE_KEY', defaultValue: '');
      if (pk.isNotEmpty) registerStripeCardViewFactory(pk);
    }
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final memberId = widget.member['memberId'] as String? ?? '';
      final data = await _savingsService.getSavingsAccount(memberId);
      if (!mounted) return;
      setState(() {
        _balance  = (data['balance'] as num?)?.toDouble() ?? 0;
        _deposits = List<Map<String, dynamic>>.from(data['deposits'] ?? []);
        _loading  = false;
      });
    } catch (e) {
      if (!mounted) return;
      debugPrint('[SavingsScreen] load error: $e');
      setState(() { _error = 'Something went wrong. Please try again.'; _loading = false; });
    }
  }

  Future<void> _showDepositSheet() async {
    final locale = context.read<LanguageProvider>().locale;
    final memberId = widget.member['memberId'] as String? ?? '';
    final deposited = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DepositSheet(
        memberId: memberId,
        savingsService: _savingsService,
        locale: locale,
      ),
    );
    if (deposited == true) _load();
  }

  Widget _buildBody() {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);

    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF1A5C2A)));
    }
    if (_error != null) {
      return _ErrorView(error: _error!, onRetry: _load, locale: locale);
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: const Color(0xFF1A5C2A),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          _BalanceCard(
            balance: _balance,
            locale: locale,
            onDeposit: _showDepositSheet,
          ),
          const SizedBox(height: 20),
          Text(
            s('depositHistoryLabel'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          if (_deposits.isEmpty)
            _EmptyDepositsView(locale: locale)
          else
            ..._deposits.map((d) => _DepositTile(data: d, locale: locale)),
        ],
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
        title: Text(AppStrings.get('kafaSavingsTitle', locale),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: const Color(0xFF1A5C2A),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _buildBody(),
    );
  }
}

// ── Balance card ─────────────────────────────────────────────────────────────

class _BalanceCard extends StatelessWidget {
  final double balance;
  final String locale;
  final VoidCallback onDeposit;
  const _BalanceCard({required this.balance, required this.locale, required this.onDeposit});

  @override
  Widget build(BuildContext context) {
    String s(String key) => AppStrings.get(key, locale);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A5C2A), Color(0xFF236B35)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1A5C2A).withValues(alpha: 0.25),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            s('savingsBalanceLabel'),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '\$${balance.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: onDeposit,
              icon: const Icon(Icons.add, size: 18),
              label: Text(s('depositButtonLabel')),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF1A5C2A),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Deposit history tile ──────────────────────────────────────────────────────

class _DepositTile extends StatelessWidget {
  final Map<String, dynamic> data;
  final String locale;
  const _DepositTile({required this.data, required this.locale});

  @override
  Widget build(BuildContext context) {
    final amount = (data['amount'] as num?)?.toDouble() ?? 0;
    final status = (data['status'] as String? ?? 'PENDING').toUpperCase();
    final method = data['paymentMethod'] as String? ?? '';
    final datetime = data['datetime'] as String? ?? '';

    Color statusColor;
    switch (status) {
      case 'SUCCEEDED':
        statusColor = const Color(0xFF1A5C2A);
        break;
      case 'FAILED':
        statusColor = Colors.red.shade600;
        break;
      default:
        statusColor = Colors.orange.shade700;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.savings_outlined, color: statusColor, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('\$${amount.toStringAsFixed(2)}',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 2),
                Text(
                  [method, _friendlyDate(datetime)].where((s) => s.isNotEmpty).join(' · '),
                  style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              status,
              style: TextStyle(color: statusColor, fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  String _friendlyDate(String iso) {
    try {
      final dt = DateTime.parse(iso);
      const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    } catch (_) {
      return iso.length >= 10 ? iso.substring(0, 10) : iso;
    }
  }
}

// ── Deposit bottom sheet (member Stripe card deposit) ─────────────────────────

class _DepositSheet extends StatefulWidget {
  final String memberId;
  final SavingsService savingsService;
  final String locale;
  const _DepositSheet({
    required this.memberId,
    required this.savingsService,
    required this.locale,
  });

  @override
  State<_DepositSheet> createState() => _DepositSheetState();
}

class _DepositSheetState extends State<_DepositSheet> {
  final _amountCtrl = TextEditingController();
  bool _isProcessing = false;
  String? _error;

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  int? get _amountCents {
    final dollars = double.tryParse(_amountCtrl.text.trim());
    if (dollars == null) return null;
    return (dollars * 100).round();
  }

  Future<void> _submit() async {
    String s(String key) => AppStrings.get(key, widget.locale);
    final cents = _amountCents;
    if (cents == null || cents < 100) {
      setState(() => _error = s('savingsMinDepositError'));
      return;
    }

    setState(() { _isProcessing = true; _error = null; });
    HapticFeedback.lightImpact();

    final result = await widget.savingsService.deposit(
      memberId: widget.memberId,
      amountCents: cents,
    );

    if (!mounted) return;

    if (result.success) {
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(true);
    } else {
      HapticFeedback.heavyImpact();
      setState(() {
        _isProcessing = false;
        _error = result.errorMessage ?? s('depositFailed');
      });
    }
  }

  Widget _buildCardFields(String Function(String) s) {
    if (!kIsWeb) {
      return Container(
        height: 54,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: CardField(
          decoration: const InputDecoration(
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          ),
        ),
      );
    }
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
            style: TextStyle(color: Colors.grey.shade600, fontSize: 11, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: MouseRegion(cursor: SystemMouseCursors.text, child: field),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    String s(String key) => AppStrings.get(key, widget.locale);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF9F9F9),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(children: [
              const Icon(Icons.savings_outlined, color: Color(0xFF1A5C2A), size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(s('depositSheetTitle'),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.pop(context),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
              ),
            ]),
            const SizedBox(height: 20),
            Text(s('depositAmountHint'),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            TextField(
              controller: _amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                prefixText: '\$ ',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(s('cardDetails'),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            _buildCardFields(s),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: Colors.red.shade600, size: 18),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, style: TextStyle(color: Colors.red.shade600))),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: _isProcessing
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.savings_outlined, size: 18),
                label: Text(s('depositButtonLabel')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A5C2A),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                onPressed: _isProcessing ? null : _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Error / empty states ────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  final String locale;
  const _ErrorView({required this.error, required this.onRetry, required this.locale});
  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline, color: Colors.red.shade400, size: 48),
          const SizedBox(height: 12),
          Text(error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          ElevatedButton(
              onPressed: onRetry,
              child: Text(AppStrings.get('retry', locale))),
        ]),
      );
}

class _EmptyDepositsView extends StatelessWidget {
  final String locale;
  const _EmptyDepositsView({required this.locale});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 32),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.savings_outlined, color: Colors.grey.shade400, size: 48),
            const SizedBox(height: 12),
            Text(
              AppStrings.get('noDepositsYet', locale),
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
            ),
          ]),
        ),
      );
}
