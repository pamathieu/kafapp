import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../models/member.dart';
import '../stripe_web_helper.dart'
    if (dart.library.html) '../stripe_web_helper_web.dart';
import '../stripe_confirmer.dart'
    if (dart.library.html) '../stripe_confirmer_web.dart';

class MemberDetailScreen extends StatefulWidget {
  final Member member;
  final List<Member> allMembers;
  const MemberDetailScreen({super.key, required this.member, required this.allMembers});

  @override
  State<MemberDetailScreen> createState() => _MemberDetailScreenState();
}

class _MemberDetailScreenState extends State<MemberDetailScreen> {
  late Member _member;
  bool _isEditing = false;
  bool _isSaving = false;
  bool _isDownloading = false;
  bool _isGenerating = false;
  String? _successMessage;
  String? _errorMessage;
  String? _downloadError;
  String? _generateError;

  // Edit controllers
  late TextEditingController _memberIdCtrl;
  late TextEditingController _nameCtrl;
  late TextEditingController _dobCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _phoneCtrl;
  late TextEditingController _emailCtrl;
  late TextEditingController _idNumberCtrl;
  late TextEditingController _idTypeCtrl;
  late TextEditingController _notesCtrl;
  late TextEditingController _newPasswordCtrl;
  bool _isSavingPassword = false;
  String? _passwordMessage;

  // Payment history state
  List<Map<String, dynamic>> _paymentHistory = [];
  bool _loadingHistory = false;

  // Payment state (policies cache for sheet)
  List<Map<String, dynamic>> _memberPolicies = [];

  late bool _editStatus;
  late String _editSex;

  // Locality state
  List<Map<String, dynamic>> _localities = [];
  Map<String, dynamic>? _selectedLocality;
  bool _loadingLocalities = false;
  bool _isLoadingSequence = false;

  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _member = widget.member;
    _initControllers();
    _loadLocalities();
    _loadMemberPolicies();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPaymentHistory());

    // Silently re-fetch policies + payment history so updates made elsewhere
    // (e.g. a payment collected, a policy created) show up without a manual reload.
    _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _loadMemberPolicies();
      _loadPaymentHistory();
    });
  }

  void _initControllers() {
    _memberIdCtrl = TextEditingController(text: _member.memberId);
    _nameCtrl     = TextEditingController(text: _member.fullName);
    _dobCtrl      = TextEditingController(text: _member.dateOfBirth);
    _addressCtrl  = TextEditingController(text: _member.address);
    _phoneCtrl    = TextEditingController(text: _member.phone);
    _emailCtrl    = TextEditingController(text: _member.email);
    _idNumberCtrl = TextEditingController(text: _member.identificationNumber);
    _idTypeCtrl   = TextEditingController(text: _member.identificationType);
    _notesCtrl        = TextEditingController(text: _member.notes);
    _newPasswordCtrl  = TextEditingController();
    _editStatus       = _member.status;
    _editSex          = _member.sex;
    _selectedLocality = _member.locality;
  }

  Future<void> _loadLocalities() async {
    setState(() => _loadingLocalities = true);
    try {
      final api = context.read<AuthProvider>().apiService!;
      final localities = await api.listLocalities();
      setState(() {
        _localities = localities;
        _loadingLocalities = false;
      });
    } catch (_) {
      setState(() => _loadingLocalities = false);
    }
  }

  Future<void> _loadPaymentHistory() async {
    setState(() => _loadingHistory = true);
    try {
      final api = context.read<AuthProvider>().apiService!;

      // Fetch manual payments (cash / MonCash / bank) from the policy API
      final policies = await api.getMemberPolicies(_member.memberId);
      final history = <Map<String, dynamic>>[];
      for (final p in policies) {
        final payments = p['paymentHistory'] as List<dynamic>? ?? [];
        for (final pay in payments) {
          history.add(Map<String, dynamic>.from(pay as Map));
        }
      }

      // Fetch Stripe card payments from the admin payments API and merge them
      try {
        final stripePayments = await api.getAdminPayments(_member.memberId);
        for (final sp in stripePayments) {
          final amountCents = (sp['amountCents'] as num?)?.toDouble() ?? 0;
          history.add({
            'paymentDate':   sp['createdAt'] ?? '',
            'referenceNo':   sp['paymentId'] ?? '',
            'amountPaid':    amountCents / 100,
            'paymentPeriod': sp['period'] ?? '',
            'status':        sp['status'] ?? 'PENDING',
            'method':        'STRIPE',
            'receiptUrl':    sp['receiptUrl'] ?? '',
            'policyId':      sp['policyId'] ?? '',
          });
        }
      } catch (_) {
        // Stripe payments unavailable — still show manual payments
      }

      history.sort((a, b) {
        final da = a['paymentDate'] as String? ?? '';
        final db = b['paymentDate'] as String? ?? '';
        return db.compareTo(da);
      });
      if (mounted) setState(() { _paymentHistory = history; _loadingHistory = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _memberIdCtrl.dispose();
    _nameCtrl.dispose();
    _dobCtrl.dispose();
    _addressCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _idNumberCtrl.dispose();
    _idTypeCtrl.dispose();
    _notesCtrl.dispose();
    _newPasswordCtrl.dispose();
    super.dispose();
  }

  void _startEdit() {
    setState(() {
      _isEditing = true;
      _successMessage = null;
      _errorMessage = null;
    });
    _loadMemberPolicies();
  }

  Future<void> _showCollectPaymentSheet() async {
    await _loadMemberPolicies();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CollectPaymentSheet(
        member: _member,
        initialPolicies: _memberPolicies,
        onSuccess: (msg) {
          setState(() => _successMessage = msg);
          _loadPaymentHistory();
        },
      ),
    );
  }

  Future<void> _showCreatePolicySheet() async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CreatePolicySheet(
        member: _member,
        onSuccess: (msg) {
          setState(() => _successMessage = msg);
          _loadMemberPolicies();
        },
      ),
    );
  }

  Future<void> _loadMemberPolicies() async {
    try {
      final api = context.read<AuthProvider>().apiService!;
      final policies = await api.getMemberPolicies(_member.memberId);
      if (!mounted) return;
      setState(() => _memberPolicies = policies);
    } catch (_) {}
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _memberIdCtrl.text = _member.memberId;
      _nameCtrl.text     = _member.fullName;
      _dobCtrl.text      = _member.dateOfBirth;
      _addressCtrl.text  = _member.address;
      _phoneCtrl.text    = _member.phone;
      _emailCtrl.text    = _member.email;
      _idNumberCtrl.text = _member.identificationNumber;
      _idTypeCtrl.text   = _member.identificationType;
      _notesCtrl.text    = _member.notes;
      _editStatus        = _member.status;
      _editSex           = _member.sex;
      _selectedLocality  = _member.locality;
    });
  }

  /// When a locality is selected, update the member ID preview.
  /// - Existing MK members: preserve their sequence, just swap the commune prefix.
  /// - MBR members: fetch server sequence to show what the new ID will be.
  void _onLocalitySelected(Map<String, dynamic>? locality) async {
    setState(() {
      _selectedLocality = locality;
      if (locality == null) return;
      final code = (locality['code'] as String).padLeft(3, '0');
      final existingSeq = _extractSequence(_member.memberId);
      if (existingSeq != null) {
        // Already MK format — just update the commune prefix, keep sequence
        _memberIdCtrl.text = _buildMemberId(code, existingSeq);
      } else {
        // MBR format — show loading while we fetch the next sequence
        _isLoadingSequence = true;
        _memberIdCtrl.text = 'Generating...';
      }
    });

    final locality_ = locality;
    if (locality_ == null) return;
    final existingSeq = _extractSequence(_member.memberId);
    if (existingSeq != null) return; // already handled above synchronously

    try {
      final api  = context.read<AuthProvider>().apiService!;
      final seq  = await api.getCompanySequence();
      final code = (locality_['code'] as String).padLeft(3, '0');
      setState(() {
        _memberIdCtrl.text = _buildMemberId(code, seq + 1);
        _isLoadingSequence = false;
      });
    } catch (_) {
      setState(() { _isLoadingSequence = false; });
    }
  }

  String _buildMemberId(String code, int seq) {
    // Format: MK + 3-digit code + 8-digit zero-padded sequence
    // e.g. MK08100000001
    return 'MK${code.padLeft(3, '0')}${seq.toString().padLeft(8, '0')}';
  }

  int? _extractSequence(String memberId) {
    // MK08100000001 → 1
    if (memberId.length >= 13 && memberId.startsWith('MK')) {
      final seqStr = memberId.substring(5); // after MK + 3-digit code
      return int.tryParse(seqStr);
    }
    return null;
  }

  Future<void> _saveUpdate() async {
    final oldMemberId = _member.memberId;
    setState(() {
      _isSaving = true;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      final updatedMember = _member.copyWith(
        memberId:             _memberIdCtrl.text.trim(),
        fullName:             _nameCtrl.text.trim(),
        dateOfBirth:          _dobCtrl.text.trim(),
        address:              _addressCtrl.text.trim(),
        phone:                _phoneCtrl.text.trim(),
        email:                _emailCtrl.text.trim(),
        identificationNumber: _idNumberCtrl.text.trim(),
        identificationType:   _idTypeCtrl.text.trim(),
        notes:                _notesCtrl.text.trim(),
        sex:                  _editSex,
        status:               _editStatus,
        locality:             _selectedLocality,
      );

      final api = context.read<AuthProvider>().apiService!;
      final result = await api.updateMember(updatedMember, oldMemberId: oldMemberId);

      setState(() {
        _member = result;
        _isEditing = false;
        _isSaving = false;
        _successMessage = AppStrings.get('memberUpdated', context.read<LanguageProvider>().locale);
        _memberIdCtrl.text = result.memberId;
      });
    } catch (e) {
      setState(() {
        _isSaving = false;
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _toggleStatus() async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    final newStatus = !_member.status;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(newStatus ? s('activateConfirmTitle') : s('deactivateConfirmTitle')),
        content: Text('${newStatus ? s('activate') : s('deactivate')} ${_member.fullName}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s('cancel'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: newStatus ? Colors.green : Colors.red,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(newStatus ? s('activate') : s('deactivate')),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _isSaving = true);
    try {
      final updated = _member.copyWith(status: newStatus);
      final api = context.read<AuthProvider>().apiService!;
      final result = await api.updateMember(updated);
      setState(() {
        _member = result;
        _isSaving = false;
        _successMessage = newStatus ? s('memberActivated') : s('memberDeactivated');
      });
    } catch (e) {
      setState(() {
        _isSaving = false;
        _errorMessage = '${s('failedUpdateStatusPrefix')}$e';
      });
    }
  }

  Future<void> _generateCertificate() async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    setState(() {
      _isGenerating = true;
      _generateError = null;
    });
    try {
      final api = context.read<AuthProvider>().apiService!;
      final result = await api.generateCertificate(_member.memberId);
      setState(() {
        _isGenerating = false;
        _member.certificate = (result['certificate'] ?? result) as Map<String, dynamic>?;
        _successMessage = s('certificateGenerated');
      });
    } catch (e) {
      setState(() {
        _isGenerating = false;
        _generateError = '${s('failedGenerateCertificate')}$e';
      });
    }
  }

  Future<void> _downloadCertificate(String type) async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    final phone = _member.phone;
    if (phone.isEmpty) {
      setState(() => _downloadError = s('noPhoneNumber'));
      return;
    }
    setState(() {
      _isDownloading = true;
      _downloadError = null;
    });
    try {
      final api = context.read<AuthProvider>().apiService!;
      final links = await api.getCertificateLinks(phone);
      final url = type == 'pdf' ? links['pdf'] : links['jpeg'];
      if (url == null || url.isEmpty) {
        setState(() {
          _isDownloading = false;
          _downloadError = s('noCertificateLink');
        });
        return;
      }
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      setState(() => _isDownloading = false);
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _downloadError = '${s('failedCertificatePrefix')}$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);

    return WillPopScope(
      onWillPop: () async {
        Navigator.of(context).pop(_member);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isEditing ? s('editMember') : s('memberDetails')),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(_member),
          ),
          actions: [
            if (!_isEditing)
              IconButton(
                icon: Icon(
                  _member.status ? Icons.person_off : Icons.person,
                  color: _member.status
                      ? Colors.red.shade300
                      : Colors.green.shade300,
                ),
                tooltip: _member.status ? s('deactivateMember') : s('activateMember'),
                onPressed: _isSaving ? null : _toggleStatus,
              ),
            Builder(builder: (ctx) {
              final locale = ctx.watch<LanguageProvider>().locale;
              return PopupMenuButton<String>(
                offset: const Offset(0, 48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                onSelected: (code) =>
                    ctx.read<LanguageProvider>().setLocale(code),
                itemBuilder: (_) => LanguageProvider.supportedLanguages
                    .map((lang) => PopupMenuItem<String>(
                          value: lang['code'],
                          child: Row(children: [
                            Text(lang['label']!,
                                style: TextStyle(
                                    fontWeight: lang['code'] == locale
                                        ? FontWeight.bold
                                        : FontWeight.normal)),
                            if (lang['code'] == locale) ...[
                              const Spacer(),
                              const Icon(Icons.check,
                                  size: 16, color: Color(0xFF1A5C2A)),
                            ],
                          ]),
                        ))
                    .toList(),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.language, color: Colors.white70, size: 18),
                    const SizedBox(width: 4),
                    Text(
                      LanguageProvider.supportedLanguages
                          .firstWhere((l) => l['code'] == locale,
                              orElse: () =>
                                  LanguageProvider.supportedLanguages.first)['label']!
                          .split(' ')
                          .first,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const Icon(Icons.arrow_drop_down,
                        color: Colors.white70, size: 18),
                  ]),
                ),
              );
            }),
          ],
        ),
        body: _isSaving
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(color: Color(0xFFC8A96E)),
                    const SizedBox(height: 16),
                    Text(s('savingChanges')),
                  ],
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_successMessage != null)
                      _Banner(
                          message: _successMessage!,
                          isError: false,
                          onDismiss: () => setState(() => _successMessage = null)),
                    if (_errorMessage != null)
                      _Banner(
                          message: _errorMessage!,
                          isError: true,
                          onDismiss: () => setState(() => _errorMessage = null)),

                    _buildHeaderCard(s),
                    const SizedBox(height: 16),

                    if (!_isEditing)
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.attach_money),
                              label: const Text('Collect Payment'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF1A5C2A),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                textStyle: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                              onPressed: _showCollectPaymentSheet,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.add_box_outlined),
                              label: const Text('Create Policy'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF1A5C2A),
                                side: const BorderSide(color: Color(0xFF1A5C2A)),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                textStyle: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                              onPressed: _showCreatePolicySheet,
                            ),
                          ),
                        ],
                      ),

                    if (!_isEditing) const SizedBox(height: 16),

                    _isEditing ? _buildEditForm(s) : _buildReadOnlyInfo(s),

                    const SizedBox(height: 16),

                    if (!_isEditing) _buildPaymentHistoryCard(),

                    const SizedBox(height: 16),

                    _member.certificate != null
                        ? _buildCertificateCard(s)
                        : _buildGenerateCertificateCard(s),

                    const SizedBox(height: 80),
                  ],
                ),
              ),
        bottomNavigationBar: _buildBottomBar(s),
      ),
    );
  }

  Widget _buildHeaderCard(String Function(String) s) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            colors: [Color(0xFF1A5C2A), Color(0xFF154D23)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            CircleAvatar(
              radius: 32,
              backgroundColor: const Color(0xFFC8A96E).withOpacity(0.2),
              child: Text(
                _member.fullName.isNotEmpty
                    ? _member.fullName[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                    color: Color(0xFFC8A96E),
                    fontSize: 26,
                    fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_member.fullName,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(_member.memberId,
                      style: const TextStyle(
                          color: Color(0xFFC8A96E), fontSize: 13)),
                  if (_member.communeName.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Icon(Icons.location_on,
                            size: 12, color: Colors.white54),
                        const SizedBox(width: 4),
                        Text(_member.communeName,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _member.status
                    ? Colors.green.withOpacity(0.2)
                    : Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _member.status ? s('active') : s('inactive'),
                style: TextStyle(
                  color:
                      _member.status ? Colors.greenAccent : Colors.redAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentHistoryCard() {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.receipt_long, color: Color(0xFF1A5C2A), size: 18),
                const SizedBox(width: 8),
                const Text(
                  'Payment History',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (_loadingHistory)
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (!_loadingHistory && _paymentHistory.isEmpty)
              const Text(
                'No payments recorded yet.',
                style: TextStyle(color: Colors.grey, fontSize: 13),
              )
            else
              ..._paymentHistory.map((p) {
                final date   = p['paymentDate'] as String? ?? '';
                final ref    = p['referenceNo'] as String? ?? p['paymentId'] as String? ?? '';
                final amount = p['amountPaid']  ?? p['amount_cents'] ?? 0;
                final period = p['paymentPeriod'] as String? ?? p['period'] as String? ?? '';
                final status = (p['status'] as String? ?? 'SUCCEEDED').toUpperCase();
                final amountStr = amount is num
                    ? 'HTG ${amount.toStringAsFixed(2)}'
                    : 'HTG $amount';
                final (color, icon) = status == 'FAILED'
                    ? (Colors.red, Icons.cancel_outlined)
                    : status == 'PENDING'
                        ? (Colors.orange, Icons.pending_outlined)
                        : (const Color(0xFF1A5C2A), Icons.check_circle_outline);
                final isStripe  = (p['method'] as String? ?? '') == 'STRIPE';
                final receiptUrl = p['receiptUrl'] as String? ?? '';
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Icon(icon, color: color, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      period.isNotEmpty ? period : date,
                                      style: const TextStyle(
                                          fontSize: 13, fontWeight: FontWeight.w500),
                                    ),
                                    if (isStripe) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF635BFF).withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Text(
                                          'STRIPE',
                                          style: TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF635BFF),
                                              letterSpacing: 0.5),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                if (ref.isNotEmpty)
                                  Text(
                                    ref,
                                    style: const TextStyle(
                                        fontSize: 11, color: Colors.grey),
                                  ),
                                if (isStripe && receiptUrl.isNotEmpty && kIsWeb)
                                  GestureDetector(
                                    onTap: () => launchUrl(Uri.parse(receiptUrl), mode: LaunchMode.externalApplication),
                                    child: const Text(
                                      'View receipt',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF1A5C2A),
                                          decoration: TextDecoration.underline),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Text(
                            amountStr,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: color),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                  ],
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildReadOnlyInfo(String Function(String) s) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(title: s('sectionMemberInfo')),
            _InfoRow(icon: Icons.badge, label: s('memberId'), value: _member.memberId),
            _InfoRow(icon: Icons.location_on, label: s('commune'), value: _member.communeName),
            const Divider(height: 24),
            _SectionHeader(title: s('sectionPersonalInfo')),
            _InfoRow(icon: Icons.person, label: s('fullName'), value: _member.fullName),
            _InfoRow(icon: Icons.cake, label: s('dateOfBirth'), value: _member.dateOfBirth),
            _InfoRow(icon: Icons.home, label: s('address'), value: _member.address),
            const Divider(height: 24),
            _SectionHeader(title: s('sectionContact')),
            _InfoRow(icon: Icons.phone, label: s('phone'), value: _member.phone),
            _InfoRow(icon: Icons.email, label: s('email'), value: _member.email),
            const Divider(height: 24),
            _SectionHeader(title: s('sectionIdentification')),
            _InfoRow(icon: Icons.credit_card, label: s('idNumber'), value: _member.identificationNumber),
            _InfoRow(icon: Icons.article, label: s('idType'), value: _member.identificationType),
            if (_member.sex.isNotEmpty)
              _InfoRow(icon: Icons.wc, label: s('sex'), value: _member.sex),
            const Divider(height: 24),
            _buildPolicySection(),
            if (_member.notes.isNotEmpty) ...[
              const Divider(height: 24),
              _SectionHeader(title: s('sectionNotes')),
              _InfoRow(icon: Icons.notes, label: s('notes'), value: _member.notes),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEditForm(String Function(String) s) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(title: s('sectionMemberInfo')),

            // Commune dropdown (searchable)
            _buildCommuneDropdown(s),
            const SizedBox(height: 12),

            // Member ID (read-only — server generates from commune + sequence)
            _EditField(
              controller: _memberIdCtrl,
              label: s('memberId'),
              icon: Icons.badge,
              hint: s('selectCommuneToGenerate'),
              readOnly: true,
            ),
            const SizedBox(height: 4),
            Text(
              _isLoadingSequence
                  ? s('fetchingSequence')
                  : s('autoGenerated'),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),

            const Divider(height: 24),
            _SectionHeader(title: s('sectionPersonalInfo')),
            _EditField(controller: _nameCtrl, label: s('fullName'), icon: Icons.person),
            const SizedBox(height: 12),
            _EditField(controller: _dobCtrl, label: s('dateOfBirth'), icon: Icons.cake,
                hint: 'YYYY-MM-DD'),
            const SizedBox(height: 12),
            _EditField(controller: _addressCtrl, label: s('address'), icon: Icons.home,
                maxLines: 2),

            const Divider(height: 24),
            _SectionHeader(title: s('sectionContact')),
            _EditField(controller: _phoneCtrl, label: s('phone'), icon: Icons.phone,
                keyboardType: TextInputType.phone),
            const SizedBox(height: 12),
            _EditField(controller: _emailCtrl, label: s('email'), icon: Icons.email,
                keyboardType: TextInputType.emailAddress),

            const Divider(height: 24),
            _SectionHeader(title: s('sectionIdentification')),
            _EditField(controller: _idNumberCtrl, label: s('idNumber'), icon: Icons.credit_card),
            const SizedBox(height: 12),
            _EditField(controller: _idTypeCtrl, label: s('idType'), icon: Icons.article),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.wc, size: 20, color: Color(0xFF1A5C2A)),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButton<String>(
                    key: ValueKey(_editSex),
                    value: _editSex.isEmpty ? null : _editSex,
                    isExpanded: true,
                    hint: Text(s('sex')),
                    items: [
                      DropdownMenuItem(value: 'Male',   child: Text(s('male'))),
                      DropdownMenuItem(value: 'Female', child: Text(s('female'))),
                    ],
                    onChanged: (v) => setState(() => _editSex = v ?? ''),
                  ),
                ),
              ],
            ),

            const Divider(height: 24),
            _SectionHeader(title: s('sectionStatus')),
            SwitchListTile(
              value: _editStatus,
              onChanged: (v) => setState(() => _editStatus = v),
              title: Text(_editStatus ? s('active') : s('inactive')),
              activeColor: const Color(0xFF1A5C2A),
              contentPadding: EdgeInsets.zero,
            ),

            const Divider(height: 24),
            _buildPolicySection(),

            const Divider(height: 24),
            _SectionHeader(title: s('sectionNotes')),
            _EditField(controller: _notesCtrl, label: s('notes'), icon: Icons.notes,
                maxLines: 3),

            const Divider(height: 24),
            const _SectionHeader(title: 'MEMBER PASSWORD'),
            const SizedBox(height: 4),
            Text(
              'Set or update this member\'s password for the Member Portal.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            ),
            const SizedBox(height: 10),
            _EditField(
              controller: _newPasswordCtrl,
              label: 'New Password',
              icon: Icons.lock_outline,
              obscureText: true,
            ),
            const SizedBox(height: 10),
            if (_passwordMessage != null)
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: _passwordMessage!.startsWith('✓')
                      ? Colors.green.shade50
                      : Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _passwordMessage!.startsWith('✓')
                        ? Colors.green.shade200
                        : Colors.red.shade200,
                  ),
                ),
                child: Text(_passwordMessage!,
                    style: TextStyle(
                        fontSize: 13,
                        color: _passwordMessage!.startsWith('✓')
                            ? Colors.green.shade700
                            : Colors.red)),
              ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: _isSavingPassword
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.key, size: 18),
                label: const Text('Set Password'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1A5C2A),
                  side: const BorderSide(color: Color(0xFF1A5C2A)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _isSavingPassword ? null : _setPassword,
              ),
            ),

          ],
        ),
      ),
    );
  }

  Widget _buildPolicySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'POLICY'),
        if (_memberPolicies.isEmpty)
          Row(
            children: [
              Icon(Icons.error_outline,
                  size: 20, color: Colors.orange.shade700),
              const SizedBox(width: 12),
              Text('No policy assigned',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange.shade800)),
            ],
          )
        else
          ..._memberPolicies.map((entry) {
            final pol = entry['policy'] as Map<String, dynamic>? ?? {};
            final productCode = (pol['productCode'] as String? ?? '').toUpperCase();
            final planName = productCode.contains('STANDARD')
                ? 'Standard Plan'
                : productCode.contains('BASIC')
                    ? 'Basic Plan'
                    : (pol['productCode'] as String? ?? 'Unknown Plan');
            final policyNo = pol['policyNo'] as String? ?? '—';
            final status = (pol['policyStatus'] as String? ?? '').toUpperCase();
            final isActive = status == 'ACTIVE';

            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.verified_user,
                      size: 20,
                      color: isActive
                          ? const Color(0xFF1A5C2A)
                          : Colors.grey.shade400),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(planName,
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: isActive
                                    ? const Color(0xFF1A5C2A).withValues(alpha: 0.1)
                                    : Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(status.isEmpty ? '—' : status,
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: isActive
                                          ? const Color(0xFF1A5C2A)
                                          : Colors.grey.shade600)),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(policyNo,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade500)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Future<void> _setPassword() async {
    final password = _newPasswordCtrl.text.trim();
    if (password.isEmpty) {
      setState(() => _passwordMessage = 'Please enter a password.');
      return;
    }
    if (password.length < 6) {
      setState(() => _passwordMessage = 'Password must be at least 6 characters.');
      return;
    }
    setState(() { _isSavingPassword = true; _passwordMessage = null; });
    try {
      final api = context.read<AuthProvider>().apiService!;
      await api.setMemberCredentials(_member.memberId, password);
      setState(() {
        _isSavingPassword = false;
        _passwordMessage  = '✓ Password set successfully.';
        _newPasswordCtrl.clear();
      });
    } catch (e) {
      setState(() {
        _isSavingPassword = false;
        _passwordMessage  = 'Error: ${e.toString().replaceAll("Exception: ", "")}';
      });
    }
  }

  Widget _buildCommuneDropdown(String Function(String) s) {
    if (_loadingLocalities) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFFC8A96E))),
            const SizedBox(width: 8),
            Text(s('loadingCommunes'), style: const TextStyle(fontSize: 13)),
          ],
        ),
      );
    }

    return Autocomplete<Map<String, dynamic>>(
      initialValue: TextEditingValue(
          text: _selectedLocality?['commune'] ?? ''),
      optionsBuilder: (textEditingValue) {
        if (textEditingValue.text.isEmpty) return _localities;
        return _localities.where((l) => (l['commune'] as String)
            .toLowerCase()
            .contains(textEditingValue.text.toLowerCase()));
      },
      displayStringForOption: (option) => option['commune'] as String,
      onSelected: _onLocalitySelected,
      fieldViewBuilder:
          (context, controller, focusNode, onFieldSubmitted) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: s('commune'),
            prefixIcon: const Icon(Icons.location_on),
            suffixIcon: const Icon(Icons.arrow_drop_down),
            isDense: true,
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 400),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.location_on,
                        size: 16, color: Color(0xFF1A5C2A)),
                    title: Text(option['commune'] as String),
                    subtitle: Text('${s('codeLabel')}: ${option['code']}',
                        style: const TextStyle(fontSize: 11)),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCertificateCard(String Function(String) s) {
    final cert = _member.certificate!;
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFC8A96E), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.verified, color: Color(0xFFC8A96E)),
                const SizedBox(width: 8),
                Text(s('certificate'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow(
                icon: Icons.confirmation_number,
                label: s('certificateId'),
                value: cert['certificate_id'] ?? ''),
            _InfoRow(
                icon: Icons.calendar_today,
                label: s('issuedDate'),
                value: cert['issued_date'] ?? ''),

            if (_downloadError != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.red, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_downloadError!,
                          style: const TextStyle(
                              color: Colors.red, fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 16),

            if (_isDownloading)
              Center(
                child: Column(
                  children: [
                    const CircularProgressIndicator(color: Color(0xFFC8A96E)),
                    const SizedBox(height: 8),
                    Text(s('retrievingCertificate'),
                        style: const TextStyle(
                            fontSize: 12, color: Colors.grey)),
                  ],
                ),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _downloadCertificate('pdf'),
                      icon: const Icon(Icons.picture_as_pdf,
                          color: Color(0xFFC8A96E)),
                      label: Text(s('downloadPdf'),
                          style: const TextStyle(
                              color: Color(0xFFC8A96E))),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFC8A96E)),
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _downloadCertificate('jpeg'),
                      icon: const Icon(Icons.image,
                          color: Color(0xFF1A5C2A)),
                      label: Text(s('downloadJpeg'),
                          style: const TextStyle(
                              color: Color(0xFF1A5C2A))),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF1A5C2A)),
                        padding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  onPressed: _isGenerating ? null : _generateCertificate,
                  icon: _isGenerating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF1A5C2A)),
                        )
                      : const Icon(Icons.refresh,
                          size: 16, color: Color(0xFF1A5C2A)),
                  label: Text(
                    _isGenerating
                        ? s('generatingCertificate')
                        : s('generateCertificate'),
                    style: const TextStyle(
                        color: Color(0xFF1A5C2A), fontSize: 13),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGenerateCertificateCard(String Function(String) s) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade300, width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.workspace_premium, color: Colors.grey.shade400),
                const SizedBox(width: 8),
                Text(s('certificate'),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 12),
            Text(s('noCertificateYet'),
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            if (_generateError != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_generateError!,
                          style: const TextStyle(
                              color: Colors.red, fontSize: 12)),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isGenerating ? null : _generateCertificate,
                icon: _isGenerating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.add_card),
                label: Text(_isGenerating
                    ? s('generatingCertificate')
                    : s('generateCertificate')),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  backgroundColor: const Color(0xFF1A5C2A),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(String Function(String) s) {
    if (_isEditing) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 8,
                offset: const Offset(0, -2))
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _cancelEdit,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  side: const BorderSide(color: Colors.grey),
                ),
                child: Text(s('cancel'),
                    style: const TextStyle(color: Colors.grey)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: _isSaving ? null : _saveUpdate,
                icon: const Icon(Icons.save),
                label: Text(s('update'), style: const TextStyle(fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  backgroundColor: const Color(0xFF1A5C2A),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 8,
              offset: const Offset(0, -2))
        ],
      ),
      child: ElevatedButton.icon(
        onPressed: _startEdit,
        icon: const Icon(Icons.edit),
        label: Text(s('edit'), style: const TextStyle(fontSize: 16)),
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(double.infinity, 50),
        ),
      ),
    );
  }
}

// ── Reusable widgets ──────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xFFC8A96E),
          fontWeight: FontWeight.bold,
          fontSize: 12,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoRow({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Colors.grey.shade400),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 11,
                        letterSpacing: 0.5)),
                const SizedBox(height: 2),
                Text(
                  value.isNotEmpty ? value : '—',
                  style: TextStyle(
                    fontSize: 14,
                    color: value.isNotEmpty
                        ? Colors.black87
                        : Colors.grey.shade400,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EditField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? hint;
  final int maxLines;
  final TextInputType? keyboardType;
  final bool readOnly;
  final bool obscureText;

  const _EditField({
    required this.controller,
    required this.label,
    required this.icon,
    this.hint,
    this.maxLines = 1,
    this.keyboardType,
    this.readOnly = false,
    this.obscureText = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      readOnly: readOnly,
      obscureText: obscureText,
      style: readOnly ? TextStyle(color: Colors.grey.shade600) : null,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        isDense: true,
        filled: readOnly,
        fillColor: readOnly ? Colors.grey.shade100 : null,
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final String message;
  final bool isError;
  final VoidCallback onDismiss;

  const _Banner(
      {required this.message,
      required this.isError,
      required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isError ? Colors.red.shade50 : Colors.green.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: isError ? Colors.red.shade200 : Colors.green.shade200),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            color: isError ? Colors.red : Colors.green,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
              child: Text(message,
                  style: TextStyle(
                      color: isError
                          ? Colors.red.shade700
                          : Colors.green.shade700,
                      fontSize: 13))),
          IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 16),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints()),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Collect Payment Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _CollectPaymentSheet extends StatefulWidget {
  final Member member;
  final List<Map<String, dynamic>> initialPolicies;
  final void Function(String) onSuccess;

  const _CollectPaymentSheet({
    required this.member,
    required this.initialPolicies,
    required this.onSuccess,
  });

  @override
  State<_CollectPaymentSheet> createState() => _CollectPaymentSheetState();
}

class _CollectPaymentSheetState extends State<_CollectPaymentSheet> {
  static const _apiBase =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  // Empty in prod builds. Dev builds pass --dart-define=PAYMENT_ENDPOINT_SUFFIX=-dev
  // so payments route to the sandbox Stripe Lambdas instead of the live ones.
  static const String _paymentEndpointSuffix =
      String.fromEnvironment('PAYMENT_ENDPOINT_SUFFIX', defaultValue: '');

  List<Map<String, dynamic>> _policies = [];
  Map<String, dynamic>? _selectedPolicy;
  String _paymentMethod = 'CASH';
  String? _scheduleMonth;
  bool _isSaving = false;
  String? _message;

  final _amountCtrl = TextEditingController();
  final _refCtrl    = TextEditingController();
  final _phoneCtrl  = TextEditingController();
  final _bankCtrl   = TextEditingController();

  @override
  void initState() {
    super.initState();
    _policies = widget.initialPolicies;
    _initDefaults();
    if (kIsWeb) {
      const pk = String.fromEnvironment('STRIPE_KEY', defaultValue: '');
      if (pk.isNotEmpty && !pk.contains('REPLACE_ME')) {
        registerStripeCardViewFactory(pk);
      }
    }
  }

  void _initDefaults() {
    if (_policies.isNotEmpty) {
      _selectedPolicy =
          _policies.first['policy'] as Map<String, dynamic>?;
      _amountCtrl.text =
          _selectedPolicy?['premiumAmount']?.toString() ?? '';
    }
    final now = DateTime.now();
    const months = [
      '', 'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    _scheduleMonth = '${months[now.month]} ${now.year}';
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _refCtrl.dispose();
    _phoneCtrl.dispose();
    _bankCtrl.dispose();
    super.dispose();
  }

  Map<String, String> _periodDates(String? label) {
    const months = {
      'January': 1, 'February': 2, 'March': 3, 'April': 4,
      'May': 5, 'June': 6, 'July': 7, 'August': 8,
      'September': 9, 'October': 10, 'November': 11, 'December': 12,
    };
    final parts = (label ?? '').split(' ');
    final month = months[parts[0]] ?? DateTime.now().month;
    final year  = int.tryParse(parts.length > 1 ? parts[1] : '') ??
        DateTime.now().year;
    final lastDay = DateTime(year, month + 1, 0).day;
    final mm = month.toString().padLeft(2, '0');
    return {
      'start': '$year-$mm-01',
      'end':   '$year-$mm-${lastDay.toString().padLeft(2, '0')}',
    };
  }

  Future<void> _submit() async {
    if (_selectedPolicy == null) {
      setState(() => _message = 'Please select a policy.');
      return;
    }
    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      setState(() => _message = 'Please enter a valid amount.');
      return;
    }
    final ref   = _refCtrl.text.trim();
    final phone = _phoneCtrl.text.trim();
    final bank  = _bankCtrl.text.trim();

    if (_paymentMethod == 'MOBILE_MONEY' && (phone.isEmpty || ref.isEmpty)) {
      setState(() => _message = 'Enter MonCash phone and transaction ID.');
      return;
    }
    if (_paymentMethod == 'BANK_TRANSFER' && ref.isEmpty) {
      setState(() => _message = 'Enter the bank transfer reference number.');
      return;
    }

    setState(() { _isSaving = true; _message = null; });

    try {
      if (_paymentMethod == 'STRIPE') {
        await _submitStripe(amount);
      } else {
        await _submitManual(amount, ref, phone, bank);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _message  = 'Error: ${e.toString().replaceAll("Exception: ", "")}';
        });
      }
    }
  }

  Future<void> _submitStripe(double amount) async {
    final policyNo    = _selectedPolicy!['policyNo'] as String? ?? '';
    final amountCents = (amount * 100).round();
    final period      = _periodDates(_scheduleMonth);

    final intentRes = await http.post(
      Uri.parse('$_apiBase/payments/create-intent$_paymentEndpointSuffix'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'member_id':    widget.member.memberId,
        'policy_id':    policyNo,
        'amount_cents': amountCents,
        'currency':     'usd',
        'period_start': period['start'],
        'period_end':   period['end'],
      }),
    );

    if (intentRes.statusCode != 200) {
      String msg = 'Payment failed (${intentRes.statusCode}).';
      try {
        final err = jsonDecode(intentRes.body) as Map<String, dynamic>;
        msg = err['error'] as String? ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }

    final data         = jsonDecode(intentRes.body) as Map<String, dynamic>;
    final clientSecret = data['client_secret'] as String;
    final paymentId    = data['payment_id']    as String;

    await confirmStripePayment(clientSecret);

    if (mounted) {
      setState(() { _isSaving = false; _message = '✓ Card charged. ID: $paymentId'; });
      widget.onSuccess('✓ Card payment recorded. ID: $paymentId');
    }
  }

  Future<void> _submitManual(
      double amount, String ref, String phone, String bank) async {
    final api      = context.read<AuthProvider>().apiService!;
    final policyNo = _selectedPolicy!['policyNo'] as String? ?? '';
    final Map<String, String> details = {};
    if (_paymentMethod == 'MOBILE_MONEY') {
      details['moncashPhone']  = phone;
      details['transactionId'] = ref;
    } else if (_paymentMethod == 'BANK_TRANSFER') {
      details['bankName']    = bank;
      details['transferRef'] = ref;
    } else {
      details['receiptNo'] = ref;
    }

    final refNo = await api.makePayment(
      policyNo:        policyNo,
      memberId:        widget.member.memberId,
      amount:          amount,
      paymentMethod:   _paymentMethod,
      paymentPeriod:   _scheduleMonth ?? '',
      externalRef:     ref,
      externalDetails: details,
    );

    if (mounted) {
      setState(() { _isSaving = false; _message = '✓ Recorded. Ref: $refNo'; });
      widget.onSuccess('✓ Payment recorded. Ref: $refNo');
    }
  }

  Widget _stripeField(String label, Widget field) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 4),
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade400),
          ),
          child: MouseRegion(cursor: SystemMouseCursors.text, child: field),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
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
            // Handle
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

            // Header
            Row(children: [
              const Icon(Icons.payments_outlined,
                  color: Color(0xFF1A5C2A), size: 22),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Collect Payment',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                Text(widget.member.fullName,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500)),
              ]),
            ]),
            const SizedBox(height: 20),

            // Policy
            if (_policies.isEmpty)
              Text('No policies found for this member.',
                  style: TextStyle(color: Colors.grey.shade500))
            else
              DropdownButtonFormField<Map<String, dynamic>>(
                value: _selectedPolicy,
                decoration: InputDecoration(
                  labelText: 'Policy',
                  prefixIcon: const Icon(Icons.policy_outlined),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                items: _policies.map((p) {
                  final pol = p['policy'] as Map<String, dynamic>? ?? {};
                  return DropdownMenuItem<Map<String, dynamic>>(
                    value: pol,
                    child: Text(
                        '${pol['policyNo'] ?? '—'}  (US\$${pol['premiumAmount'] ?? '—'}/mo)'),
                  );
                }).toList(),
                onChanged: (pol) => setState(() {
                  _selectedPolicy = pol;
                  _amountCtrl.text = pol?['premiumAmount']?.toString() ?? '';
                }),
              ),

            const SizedBox(height: 12),

            // Period
            DropdownButtonFormField<String>(
              value: _scheduleMonth,
              decoration: InputDecoration(
                labelText: 'Payment Period',
                prefixIcon: const Icon(Icons.calendar_month_outlined),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              items: () {
                const months = [
                  'January', 'February', 'March', 'April', 'May', 'June',
                  'July', 'August', 'September', 'October', 'November', 'December',
                ];
                final now = DateTime.now();
                final items = <DropdownMenuItem<String>>[];
                for (int i = -6; i <= 3; i++) {
                  final dt    = DateTime(now.year, now.month + i);
                  final label = '${months[dt.month - 1]} ${dt.year}';
                  items.add(DropdownMenuItem(value: label, child: Text(label)));
                }
                return items;
              }(),
              onChanged: (v) => setState(() => _scheduleMonth = v),
            ),

            const SizedBox(height: 12),

            // Amount
            TextField(
              controller: _amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount (HTG)',
                prefixIcon: const Icon(Icons.attach_money),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
            ),

            const SizedBox(height: 12),

            // Payment method
            DropdownButtonFormField<String>(
              value: _paymentMethod,
              decoration: InputDecoration(
                labelText: 'Payment Method',
                prefixIcon: const Icon(Icons.payment),
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              items: const [
                DropdownMenuItem(value: 'CASH',         child: Text('💵  Cash')),
                DropdownMenuItem(value: 'MOBILE_MONEY', child: Text('📱  MonCash')),
                DropdownMenuItem(value: 'BANK_TRANSFER',child: Text('🏦  Bank Transfer')),
                DropdownMenuItem(value: 'STRIPE',       child: Text('💳  Online (Stripe)')),
              ],
              onChanged: (v) => setState(() {
                _paymentMethod = v ?? 'CASH';
                _refCtrl.clear(); _phoneCtrl.clear(); _bankCtrl.clear();
              }),
            ),

            const SizedBox(height: 12),

            // Method-specific fields
            if (_paymentMethod == 'MOBILE_MONEY') ...[
              TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'MonCash Phone',
                  prefixIcon: const Icon(Icons.phone_android),
                  hintText: '509-XXXX-XXXX',
                  isDense: true,
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _refCtrl,
                decoration: InputDecoration(
                  labelText: 'MonCash Transaction ID',
                  prefixIcon: const Icon(Icons.tag),
                  hintText: 'MC-XXXXXXXX',
                  isDense: true,
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ] else if (_paymentMethod == 'BANK_TRANSFER') ...[
              TextField(
                controller: _bankCtrl,
                decoration: InputDecoration(
                  labelText: 'Bank Name',
                  prefixIcon: const Icon(Icons.account_balance),
                  hintText: 'e.g. BNC, Sogebank',
                  isDense: true,
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _refCtrl,
                decoration: InputDecoration(
                  labelText: 'Transfer Reference',
                  prefixIcon: const Icon(Icons.tag),
                  hintText: 'BNK-XXXXXXXXXX',
                  isDense: true,
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ] else if (_paymentMethod == 'STRIPE') ...[
              _stripeField('Card Number', stripeCardHtmlView()),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _stripeField('Expiry', stripeExpiryHtmlView())),
                const SizedBox(width: 10),
                Expanded(child: _stripeField('CVC', stripeCvcHtmlView())),
              ]),
            ] else ...[
              TextField(
                controller: _refCtrl,
                decoration: InputDecoration(
                  labelText: 'Receipt Number (optional)',
                  prefixIcon: const Icon(Icons.receipt),
                  hintText: 'Leave blank to auto-generate',
                  isDense: true,
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],

            // Feedback
            if (_message != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _message!.startsWith('✓')
                      ? Colors.green.shade50 : Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _message!.startsWith('✓')
                        ? Colors.green.shade200 : Colors.red.shade200,
                  ),
                ),
                child: Text(_message!,
                    style: TextStyle(
                        fontSize: 13,
                        color: _message!.startsWith('✓')
                            ? Colors.green.shade700 : Colors.red)),
              ),
            ],

            const SizedBox(height: 20),

            // Submit button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: _isSaving
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.payment, size: 18),
                label: const Text('Collect Payment'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A5C2A),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  textStyle: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                onPressed: _isSaving ? null : _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Create Policy Bottom Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _CreatePolicySheet extends StatefulWidget {
  final Member member;
  final void Function(String) onSuccess;

  const _CreatePolicySheet({
    required this.member,
    required this.onSuccess,
  });

  @override
  State<_CreatePolicySheet> createState() => _CreatePolicySheetState();
}

class _CreatePolicySheetState extends State<_CreatePolicySheet> {
  static const _plans = [
    {'code': 'BASIC',    'name': 'Basic Plan',    'premium': 10, 'coverage': 270000},
    {'code': 'STANDARD', 'name': 'Standard Plan', 'premium': 20, 'coverage': 400000},
  ];

  String _selectedPlan = 'BASIC';
  bool _isSaving = false;
  String? _message;

  Future<void> _submit() async {
    setState(() { _isSaving = true; _message = null; });
    try {
      final api = context.read<AuthProvider>().apiService!;
      final result = await api.createMemberPolicy(
        memberId: widget.member.memberId,
        planCode: _selectedPlan,
      );
      final policyNo = result['policyNo'] as String? ?? '';
      if (mounted) {
        setState(() { _isSaving = false; _message = '✓ Policy created: $policyNo'; });
        widget.onSuccess('✓ Policy $policyNo created successfully.');
        await Future.delayed(const Duration(milliseconds: 900));
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _message  = 'Error: ${e.toString().replaceAll("Exception: ", "")}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
              const Icon(Icons.add_box_outlined,
                  color: Color(0xFF1A5C2A), size: 22),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Create Policy',
                    style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                Text(widget.member.fullName,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500)),
              ]),
            ]),
            const SizedBox(height: 20),

            const Text('Select Plan',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            ..._plans.map((plan) {
              final code = plan['code'] as String;
              final selected = _selectedPlan == code;
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GestureDetector(
                  onTap: () => setState(() => _selectedPlan = code),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected
                            ? const Color(0xFF1A5C2A)
                            : Colors.grey.shade300,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Row(children: [
                      Icon(
                        selected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: selected
                            ? const Color(0xFF1A5C2A)
                            : Colors.grey.shade400,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(plan['name'] as String,
                                style: const TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                            Text(
                                'HTG ${plan['coverage']} coverage',
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey.shade500)),
                          ],
                        ),
                      ),
                      Text('US\$${plan['premium']}/mo',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF1A5C2A))),
                    ]),
                  ),
                ),
              );
            }),

            if (_message != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _message!.startsWith('✓')
                      ? Colors.green.shade50 : Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _message!.startsWith('✓')
                        ? Colors.green.shade200 : Colors.red.shade200,
                  ),
                ),
                child: Text(_message!,
                    style: TextStyle(
                        fontSize: 13,
                        color: _message!.startsWith('✓')
                            ? Colors.green.shade700 : Colors.red)),
              ),
            ],

            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: _isSaving
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check, size: 18),
                label: const Text('Create Policy'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A5C2A),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  textStyle: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                onPressed: _isSaving ? null : _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}