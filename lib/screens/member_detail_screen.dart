import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../models/member.dart';
import '../services/dev_env.dart';
import '../services/share_service.dart';
import '../stripe_web_helper.dart'
    if (dart.library.html) '../stripe_web_helper_web.dart';
import '../stripe_confirmer.dart'
    if (dart.library.html) '../stripe_confirmer_web.dart';

String _methodLabel(String? raw) {
  switch ((raw ?? '').toUpperCase()) {
    case 'STRIPE':        return 'Stripe';
    case 'MOBILE_MONEY':  return 'Mobile Money';
    case 'BANK_TRANSFER': return 'Bank Transfer';
    default:              return 'Cash';
  }
}

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
  bool _isSavingPassword = false;
  String? _passwordMessage;
  bool _isSendingWelcome = false;
  String? _welcomeError;

  // Payment history state
  List<Map<String, dynamic>> _paymentHistory = [];
  bool _loadingHistory = false;

  // Shares state (membership + preferred)
  List<Map<String, dynamic>> _shares = [];
  bool _loadingShares = false;

  // Payment state (policies cache for sheet)
  List<Map<String, dynamic>> _memberPolicies = [];

  late String _editStatus;
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadShares());

    // Silently re-fetch policies + payment history so updates made elsewhere
    // (e.g. a payment collected, a policy created) show up without a manual reload.
    _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _loadMemberPolicies();
      _loadPaymentHistory();
      _loadShares();
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

  Future<void> _loadShares() async {
    setState(() => _loadingShares = true);
    try {
      final api = context.read<AuthProvider>().apiService!;
      final shares = await api.getMemberShares(_member.memberId);
      shares.sort((a, b) {
        final da = a['datetime'] as String? ?? '';
        final db = b['datetime'] as String? ?? '';
        return db.compareTo(da);
      });
      if (mounted) setState(() { _shares = shares; _loadingShares = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingShares = false);
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

  Future<void> _showCollectShareSheet({bool collectMode = false}) async {
    await _loadMemberPolicies();
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CollectShareSheet(
        member: _member,
        initialPolicies: _memberPolicies,
        initialShares: _shares,
        collectMode: collectMode,
        onSuccess: (msg) async {
          setState(() => _successMessage = msg);
          _loadPaymentHistory();
          _loadShares();
          // A membership share may have just activated a pending member —
          // refresh. For Stripe payments, activation happens inside the
          // webhook, which can land well after the card confirmation
          // already resolved client-side (webhook delivery latency varies,
          // e.g. several seconds via the `stripe listen` CLI forwarder in
          // local dev), so poll for a while instead of trusting a single
          // immediate fetch (avoids showing a stale "Inaktif" badge right
          // after a successful Stripe payment).
          final api = context.read<AuthProvider>().apiService!;
          for (var attempt = 0; attempt < 20; attempt++) {
            try {
              final fresh = await api.getMember(_member.memberId);
              if (mounted) setState(() => _member = fresh);
              if (fresh.status == 'Active') break;
            } catch (_) {
              break;
            }
            if (attempt < 19) await Future.delayed(const Duration(seconds: 1));
          }
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
        debugPrint('[MemberDetail] save error: $e');
        _errorMessage = 'Something went wrong. Please try again.';
      });
    }
  }

  /// A member can only be active if they have a successful membership share
  /// on file — without one, status must remain pending regardless of what
  /// an admin tries to set it to.
  bool get _hasMembershipShare => _shares.any((s) =>
      (s['shareType'] as String? ?? '') == 'membership' &&
      (s['status'] as String? ?? '').toUpperCase() == 'SUCCEEDED');

  Future<void> _toggleStatus() async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    final newStatus = _member.status == 'Active' ? 'Inactive' : 'Active';

    if (newStatus == 'Active' && !_hasMembershipShare) {
      setState(() => _errorMessage = s('noMembershipShareWarning'));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(newStatus == 'Active' ? s('activateConfirmTitle') : s('deactivateConfirmTitle')),
        content: Text('${newStatus == 'Active' ? s('activate') : s('deactivate')} ${_member.fullName}?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(s('cancel'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: newStatus == 'Active' ? Colors.green : Colors.red,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(newStatus == 'Active' ? s('activate') : s('deactivate')),
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
        _successMessage = newStatus == 'Active' ? s('memberActivated') : s('memberDeactivated');
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
        _generateError = e.toString().replaceFirst('Exception: ', '');
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
        _downloadError = s('failedCertificatePrefix');
      });
    }
  }

  Future<void> _shareCertificateWhatsApp() async {
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
      final jpegUrl = links['jpeg'] ?? '';
      if (jpegUrl.isEmpty) {
        setState(() {
          _isDownloading = false;
          _downloadError = s('noCertificateLink');
        });
        return;
      }
      final shortCertUrl = await _shortenUrl(jpegUrl);
      setState(() => _isDownloading = false);

      var waPhone = phone.replaceAll(RegExp(r'[^0-9]'), '');
      if (waPhone.length == 10) waPhone = '1$waPhone';

      final message =
          'Hello ${_member.fullName} 👋\n\n'
          'Here is your KAFA membership certificate:\n'
          '$shortCertUrl\n\n'
          'KAFA - 874 Rue Ste Catherine, Leogane, Haiti';
      final encoded = Uri.encodeComponent(message);
      final waUrl = waPhone.isNotEmpty
          ? 'https://wa.me/$waPhone?text=$encoded'
          : 'https://wa.me/?text=$encoded';
      await launchUrl(Uri.parse(waUrl), mode: LaunchMode.externalApplication);
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _downloadError = s('failedCertificatePrefix');
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
                  _member.status == 'Active' ? Icons.person_off : Icons.person,
                  color: _member.status == 'Active'
                      ? Colors.red.shade300
                      : Colors.green.shade300,
                ),
                tooltip: _member.status == 'Active' ? s('deactivateMember') : s('activateMember'),
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
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.add_box_outlined),
                              label: Text(s('createPolicy')),
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
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.inventory_2_outlined),
                              label: Text(s('collectShare')),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF8B6914),
                                side: const BorderSide(color: Color(0xFF8B6914)),
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                textStyle: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                              onPressed: () =>
                                  _showCollectShareSheet(collectMode: true),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.savings_outlined),
                              label: Text(s('payShares')),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF8B6914),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                                textStyle: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                              onPressed: () =>
                                  _showCollectShareSheet(collectMode: false),
                            ),
                          ),
                        ],
                      ),

                    if (!_isEditing) const SizedBox(height: 16),

                    _isEditing ? _buildEditForm(s) : _buildReadOnlyInfo(s),

                    const SizedBox(height: 16),

                    if (!_isEditing) _buildSharesCard(),

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
                color: _member.status == 'Active'
                    ? Colors.green.withOpacity(0.2)
                    : Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _member.status == 'Active' ? s('active') : s('inactive'),
                style: TextStyle(
                  color:
                      _member.status == 'Active' ? Colors.greenAccent : Colors.redAccent,
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

  Widget _buildSharesCard() {
    final membershipShares = _shares.where((s) => s['shareType'] == 'membership').toList();
    final preferredShares  = _shares.where((s) => s['shareType'] == 'preferred').toList();

    double totalOf(List<Map<String, dynamic>> list) => list
        .where((s) => (s['status'] as String? ?? '').toUpperCase() != 'FAILED')
        .fold(0.0, (sum, s) => sum + ((s['amount'] as num?)?.toDouble() ?? 0));

    final totalMembership = totalOf(membershipShares);
    final totalPreferred  = totalOf(preferredShares);
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);

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
                const Icon(Icons.pie_chart_outline, color: Color(0xFF1A5C2A), size: 18),
                const SizedBox(width: 8),
                Text(
                  s('sharesTitle'),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (_loadingShares)
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),

            // Summary chips
            Row(
              children: [
                Expanded(
                  child: _shareSummaryChip(
                      s('shareMembership'), totalMembership, const Color(0xFF1A5C2A)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _shareSummaryChip(
                      s('sharePreferred'), totalPreferred, const Color(0xFF8B6914)),
                ),
              ],
            ),
            const SizedBox(height: 12),

          ],
        ),
      ),
    );
  }

  Widget _shareSummaryChip(String label, double total, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: color, fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text('\$${total.toStringAsFixed(2)}',
              style: TextStyle(
                  fontSize: 16, color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _buildPaymentHistoryCard() {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);

    // Normalise shares into the same shape as premium payment rows.
    final shareRows = _shares.map((sh) => {
      '_isShare':      true,
      'paymentDate':   (sh['datetime'] as String? ?? '').length >= 10
                           ? (sh['datetime'] as String).substring(0, 10)
                           : sh['datetime'] ?? '',
      'sortKey':       sh['datetime'] ?? '',
      'referenceNo':   (sh['externalRef'] as String? ?? '').isNotEmpty
          ? sh['externalRef'] as String
          : ((sh['shareId'] as String? ?? '').split('#').last),
      'amountPaid':    sh['amount'] ?? 0,
      'status':        sh['status'] ?? 'PENDING',
      'shareType':     sh['shareType'] ?? '',
      'apr':           sh['apr'] ?? 0,
      'paymentMethod': sh['paymentMethod'] ?? '',
    });

    final premiumRows = _paymentHistory.map((p) => {
      '_isShare':      false,
      'paymentDate':   p['paymentDate'] ?? '',
      'sortKey':       p['paymentDate'] ?? '',
      ...p,
    });

    final combined = [...shareRows, ...premiumRows]
      ..sort((a, b) => (b['sortKey'] as String).compareTo(a['sortKey'] as String));

    final isLoading = _loadingHistory || _loadingShares;

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
                Text(
                  s('paymentHistory'),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (isLoading)
                  const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (!isLoading && combined.isEmpty)
              Text(
                s('noPaymentsYet'),
                style: const TextStyle(color: Colors.grey, fontSize: 13),
              )
            else
              ...combined.map((p) {
                final isShare   = p['_isShare'] == true;
                final date      = p['paymentDate'] as String? ?? '';
                final ref       = p['referenceNo'] as String? ?? p['paymentId'] as String? ?? '';
                final amount    = p['amountPaid']  ?? p['amount_cents'] ?? 0;
                final status    = (p['status'] as String? ?? 'SUCCEEDED').toUpperCase();
                final amountVal = amount is num ? amount.toDouble() : double.tryParse(amount.toString()) ?? 0.0;
                final amountStr = 'US\$${amountVal.toStringAsFixed(2)}';
                final (color, icon) = status == 'FAILED'
                    ? (Colors.red, Icons.cancel_outlined)
                    : status == 'PENDING'
                        ? (Colors.orange, Icons.pending_outlined)
                        : (const Color(0xFF1A5C2A), Icons.check_circle_outline);
                final isStripe   = (p['paymentMethod'] as String? ?? p['method'] as String? ?? '') == 'STRIPE';
                final receiptUrl = p['receiptUrl'] as String? ?? '';

                // Share-specific
                final shareType  = (p['shareType'] as String? ?? '').toLowerCase();
                final apr        = (p['apr'] as num?)?.toDouble() ?? 0;
                final isPreferred = shareType == 'preferred';
                final label = isShare
                    ? (isPreferred ? s('sharePreferred') : s('shareMembership'))
                    : (p['paymentPeriod'] as String? ?? p['period'] as String? ?? date);

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
                                      label.isNotEmpty ? label : date,
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
                                    if (isPreferred && apr > 0) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF8B6914).withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          'APR ${apr.toStringAsFixed(0)}%',
                                          style: const TextStyle(
                                              fontSize: 9,
                                              fontWeight: FontWeight.w700,
                                              color: Color(0xFF8B6914),
                                              letterSpacing: 0.5),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                Text(
                                  isShare ? date : ref,
                                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                                ),
                                if (!isShare && isStripe && receiptUrl.isNotEmpty && kIsWeb)
                                  GestureDetector(
                                    onTap: () => launchUrl(Uri.parse(receiptUrl), mode: LaunchMode.externalApplication),
                                    child: Text(
                                      s('viewReceipt'),
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF1A5C2A),
                                          decoration: TextDecoration.underline),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                amountStr,
                                style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: color),
                              ),
                              if (status == 'SUCCEEDED' || status == 'PAID') ...[
                                const SizedBox(width: 8),
                                GestureDetector(
                                  onTap: () {
                                    var waPhone = _member.phone.replaceAll(RegExp(r'[^0-9]'), '');
                                    if (waPhone.length == 10) waPhone = '1$waPhone';
                                    final msg =
                                        'Hello ${_member.fullName}\n\n'
                                        '*Payment Receipt*\n'
                                        'Amount: $amountStr\n'
                                        'Type: ${label.isNotEmpty ? label : date}\n'
                                        'Date: $date\n'
                                        'Method: ${_methodLabel(p['paymentMethod'] as String? ?? p['method'] as String?)}\n'
                                        'Reference: $ref\n\n'
                                        'Thank you for your payment!\n\n'
                                        'KAFA - 874 Rue Ste Catherine, Leogane, Haiti';
                                    final encoded = Uri.encodeComponent(msg);
                                    final url = waPhone.isNotEmpty
                                        ? 'https://wa.me/$waPhone?text=$encoded'
                                        : 'https://wa.me/?text=$encoded';
                                    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                                  },
                                  child: const Icon(Icons.send, size: 16, color: Color(0xFF25D366)),
                                ),
                              ],
                            ],
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
              value: _editStatus == 'Active',
              onChanged: (v) {
                if (v && !_hasMembershipShare) {
                  setState(() => _errorMessage = s('noMembershipShareWarning'));
                  return;
                }
                setState(() => _editStatus = v ? 'Active' : 'Inactive');
              },
              title: Text(_editStatus == 'Active' ? s('active') : s('inactive')),
              subtitle: !_hasMembershipShare
                  ? Text(
                      s('noMembershipShareSubtitle'),
                      style: const TextStyle(fontSize: 11, color: Colors.orange),
                    )
                  : null,
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
            _SectionHeader(title: s('sectionMemberPassword')),
            const SizedBox(height: 4),
            Text(
              s('passwordSetupDesc'),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
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
                    : const Icon(Icons.mail_outline, size: 18),
                label: Text(s('sendPasswordSetupEmail')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1A5C2A),
                  side: const BorderSide(color: Color(0xFF1A5C2A)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _isSavingPassword ? null : _sendPasswordSetupEmail,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.share, size: 18),
                label: const Text('Share setup link'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1A5C2A),
                  side: const BorderSide(color: Color(0xFF1A5C2A)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _showSetupLinkSheet,
              ),
            ),

          ],
        ),
      ),
    );
  }

  Widget _buildPolicySection() {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: s('sectionPolicy')),
        if (_memberPolicies.isEmpty)
          Row(
            children: [
              Icon(Icons.error_outline,
                  size: 20, color: Colors.orange.shade700),
              const SizedBox(width: 12),
              Text(s('noPolicyAssigned'),
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
                ? s('planStandard')
                : productCode.contains('BASIC')
                    ? s('planBasic')
                    : (pol['productCode'] as String? ?? s('planUnknown'));
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

  Future<void> _sendPasswordSetupEmail() async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    if (_member.email.trim().isEmpty) {
      setState(() => _passwordMessage = s('noEmailOnFileAdmin'));
      return;
    }
    setState(() { _isSavingPassword = true; _passwordMessage = null; });
    try {
      final api = context.read<AuthProvider>().apiService!;
      final (message, setupLink) = await api.sendMemberPasswordSetupEmail(_member.memberId);
      setState(() {
        _isSavingPassword = false;
        _passwordMessage  = setupLink != null
            ? '✓ $message\n\n🔗 $setupLink'
            : '✓ $message';
      });
    } catch (e) {
      setState(() {
        _isSavingPassword = false;
        debugPrint('[MemberDetail] password setup error: $e');
        _passwordMessage  = 'Something went wrong. Please try again.';
      });
    }
  }

  // ── Welcoming ──────────────────────────────────────────────────────────────

  Future<String> _shortenUrl(String url) async {
    final api = context.read<AuthProvider>().apiService!;
    return api.shortenUrl(url);
  }

  String _buildWelcomingText({
    required String setupLink,
    required String certLink,
    required List<Map<String, dynamic>> membershipShares,
    required List<Map<String, dynamic>> preferredShares,
  }) {
    final buf = StringBuffer();
    buf.writeln('Hello ${_member.fullName}');
    buf.writeln();
    buf.writeln('Welcome to KAFA!');
    buf.writeln();

    buf.writeln('*Set your password:*');
    buf.writeln(setupLink);
    buf.writeln();

    if (certLink.isNotEmpty) {
      buf.writeln('*Your certificate:*');
      buf.writeln(certLink);
      buf.writeln();
    }

    buf.writeln('*Payment Receipts*');

    // Membership share — always included (even at $0)
    final membershipTotal = membershipShares.fold<double>(
        0, (sum, s) => sum + ((s['amount'] as num?) ?? 0).toDouble());
    buf.writeln();
    buf.writeln('*Membership Share*');
    buf.writeln('Amount: US\$${membershipTotal.toStringAsFixed(2)}');
    if (membershipShares.isNotEmpty) {
      final dt = membershipShares.first['datetime'] as String? ?? '';
      if (dt.length >= 10) buf.writeln('Date: ${dt.substring(0, 10)}');
      final extRef = membershipShares.first['externalRef'] as String? ?? '';
      final shareId = membershipShares.first['shareId'] as String? ?? '';
      final ref = extRef.isNotEmpty ? extRef : shareId.split('#').last;
      if (ref.isNotEmpty) buf.writeln('Ref: $ref');
    }

    // Preferred share — only if at least one SUCCEEDED
    if (preferredShares.isNotEmpty) {
      final preferredTotal = preferredShares.fold<double>(
          0, (sum, s) => sum + ((s['amount'] as num?) ?? 0).toDouble());
      final apr = (preferredShares.first['apr'] as num?)?.toDouble() ?? 0;
      buf.writeln();
      buf.write('*Preferred Share');
      if (apr > 0) buf.write(' (APR ${apr.toStringAsFixed(0)}%)');
      buf.writeln('*');
      buf.writeln('Amount: US\$${preferredTotal.toStringAsFixed(2)}');
      final dt = preferredShares.first['datetime'] as String? ?? '';
      if (dt.length >= 10) buf.writeln('Date: ${dt.substring(0, 10)}');
      final extRef2 = preferredShares.first['externalRef'] as String? ?? '';
      final shareId2 = preferredShares.first['shareId'] as String? ?? '';
      final ref2 = extRef2.isNotEmpty ? extRef2 : shareId2.split('#').last;
      if (ref2.isNotEmpty) buf.writeln('Ref: $ref2');
    }

    return buf.toString();
  }

  Future<void> _sendWelcomingMessage() async {
    setState(() { _isSendingWelcome = true; _welcomeError = null; });
    try {
      final api = context.read<AuthProvider>().apiService!;

      // 1. Setup link — always mint a fresh one (the cached setupToken on the
      // member record may already be expired) if the member has an email on file.
      String setupLink;
      if (_member.email.trim().isNotEmpty) {
        final (_, link) = await api.sendMemberPasswordSetupEmail(_member.memberId);
        setupLink = link ?? kMemberPortalUrl;
      } else {
        setupLink = kMemberPortalUrl;
      }

      // 2. Certificate link (JPEG for WhatsApp preview)
      String certLink = '';
      if (_member.phone.isNotEmpty) {
        try {
          final links = await api.getCertificateLinks(_member.phone);
          certLink = links['jpeg'] ?? links['pdf'] ?? '';
        } catch (_) {}
      }

      // 3. Shorten both links for compact WhatsApp messages.
      setupLink = await _shortenUrl(setupLink);
      if (certLink.isNotEmpty) certLink = await _shortenUrl(certLink);

      // 4. Build share receipt lists from already-loaded _shares
      final membershipShares = _shares
          .where((s) =>
              (s['shareType'] as String? ?? '').toLowerCase() == 'membership')
          .toList();
      final preferredShares = _shares
          .where((s) =>
              (s['shareType'] as String? ?? '').toLowerCase() == 'preferred' &&
              (s['status'] as String? ?? '').toUpperCase() == 'SUCCEEDED')
          .toList();

      // 5. Compose and open WhatsApp
      final msg = _buildWelcomingText(
        setupLink: setupLink,
        certLink: certLink,
        membershipShares: membershipShares,
        preferredShares: preferredShares,
      );

      var waPhone = _member.phone.replaceAll(RegExp(r'[^0-9]'), '');
      if (waPhone.length == 10) waPhone = '1$waPhone';
      final waUrl = waPhone.isNotEmpty
          ? 'https://wa.me/$waPhone?text=${Uri.encodeComponent(msg)}'
          : 'https://wa.me/?text=${Uri.encodeComponent(msg)}';

      await launchUrl(Uri.parse(waUrl), mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[Welcoming] $e');
      if (mounted) setState(() => _welcomeError = e.toString());
    } finally {
      if (mounted) setState(() => _isSendingWelcome = false);
    }
  }

  Future<void> _showSetupLinkSheet() async {
    // Always mint a fresh token — the cached setupToken on the member record
    // may already be expired.
    String setupLink;
    setState(() { _isSavingPassword = true; _passwordMessage = null; });
    try {
      final api = context.read<AuthProvider>().apiService!;
      final (_, link) = await api.sendMemberPasswordSetupEmail(_member.memberId);
      setState(() => _isSavingPassword = false);
      if (link == null || !mounted) return;
      setupLink = link;
    } catch (e) {
      setState(() {
        _isSavingPassword = false;
        debugPrint('[MemberDetail] setup link error: $e');
        _passwordMessage = 'Something went wrong. Please try again.';
      });
      return;
    }
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SetupLinkShareSheet(
        setupLink: setupLink,
        whatsAppUrl: _buildMemberWhatsAppUrl(setupLink),
      ),
    );
  }

  String _buildMemberWhatsAppUrl(String setupLink) {
    var phone = _member.phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (phone.length == 10) phone = '1$phone';

    final message =
        'Hello ${_member.fullName} 👋\n\n'
        '*Your Member Number*\n'
        '${_member.memberId}\n\n'
        'You can set up your KAFA member portal account using the link below:\n'
        '$setupLink\n\n'
        'If you have any questions, feel free to reach us:\n'
        '📧 kontak@kafayiti.com\n'
        '📞 (509) 3500-0326 / (509) 4439-8595\n'
        '🌐 kafayiti.com\n\n'
        'KAFA - 874 Rue Ste Catherine, Leogane, Haiti';

    final encoded = Uri.encodeComponent(message);
    return phone.isNotEmpty
        ? 'https://wa.me/$phone?text=$encoded'
        : 'https://wa.me/?text=$encoded';
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
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isDownloading ? null : _shareCertificateWhatsApp,
                  icon: const Icon(Icons.send, size: 16, color: Colors.white),
                  label: Text(
                    s('shareOnWhatsApp'),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 8,
              offset: const Offset(0, -2))
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_welcomeError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(_welcomeError!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                  textAlign: TextAlign.center),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _isSendingWelcome ? null : _sendWelcomingMessage,
                  icon: _isSendingWelcome
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Color(0xFF25D366)),
                        )
                      : const Icon(Icons.waving_hand,
                          size: 16, color: Color(0xFF25D366)),
                  label: const Text('Welcoming',
                      style: TextStyle(
                          color: Color(0xFF25D366),
                          fontWeight: FontWeight.w600)),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: Color(0xFF25D366)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _startEdit,
                  icon: const Icon(Icons.edit, size: 16),
                  label: Text(s('edit'),
                      style: const TextStyle(fontSize: 15)),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    backgroundColor: const Color(0xFFC8A96E),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),
        ],
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
//  Collect Share Bottom Sheet — admin collects membership/preferred shares
//  and premium policy payments (Premium tab absorbs the old standalone
//  "Collect Payment" sheet).
// ─────────────────────────────────────────────────────────────────────────────

class _CollectShareSheet extends StatefulWidget {
  final Member member;
  final List<Map<String, dynamic>> initialPolicies;
  final List<Map<String, dynamic>> initialShares;
  final void Function(String) onSuccess;
  // true  → "Collect Share/Payment": records a payment the member already
  //         made through another channel (cash, MonCash, bank transfer).
  // false → "Pay Shares": admin actively charges a card right now via
  //         Stripe (in addition to the same manual-recording options).
  final bool collectMode;

  const _CollectShareSheet({
    required this.member,
    required this.initialPolicies,
    required this.initialShares,
    required this.onSuccess,
    this.collectMode = false,
  });

  @override
  State<_CollectShareSheet> createState() => _CollectShareSheetState();
}

class _CollectShareSheetState extends State<_CollectShareSheet> {
  static const _apiBase = kApiBaseUrl;

  // Empty in prod builds. Dev builds pass --dart-define=PAYMENT_ENDPOINT_SUFFIX=-dev
  // so payments route to the sandbox Stripe Lambdas instead of the live ones.
  static const String _paymentEndpointSuffix =
      String.fromEnvironment('PAYMENT_ENDPOINT_SUFFIX', defaultValue: '');

  String _tab = 'membership'; // 'membership' | 'preferred' | 'premium'
  String _paymentMethod = 'CASH';
  bool _isSaving = false;
  String? _message;

  // Local copy of shares — updated optimistically after each payment so
  // the history section refreshes without closing the sheet.
  late List<Map<String, dynamic>> _localShares;

  // Premium-tab state (policy + period to pay against).
  List<Map<String, dynamic>> _policies = [];
  Map<String, dynamic>? _selectedPolicy;
  String? _scheduleMonth;
  String _premiumFrequency = 'monthly'; // 'monthly' | 'annual'

  final _amountCtrl = TextEditingController();
  final _refCtrl    = TextEditingController();
  final _phoneCtrl  = TextEditingController();
  final _bankCtrl   = TextEditingController();

  bool get _hasMembershipShare => _localShares.any((s) =>
      (s['shareType'] as String? ?? '') == 'membership' &&
      (s['status'] as String? ?? '').toUpperCase() == 'SUCCEEDED');

  bool get _isPending => !_hasMembershipShare;

  bool get _hasNoPolicies => _policies.isEmpty;

  String _title(bool isPremium) {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    if (widget.collectMode) {
      return isPremium ? s('collectPayment') : s('collectShare');
    }
    return isPremium ? s('payPremium') : s('payShareSingular');
  }

  int? get _amountCents {
    final dollars = double.tryParse(_amountCtrl.text.trim());
    if (dollars == null) return null;
    return (dollars * 100).round();
  }

  @override
  void initState() {
    super.initState();
    _localShares = List.from(widget.initialShares);
    _policies = widget.initialPolicies;
    if (_isPending) _tab = 'membership';
    _initPremiumDefaults();
    if (kIsWeb) {
      const pk = String.fromEnvironment('STRIPE_KEY', defaultValue: '');
      if (pk.isNotEmpty && !pk.contains('REPLACE_ME')) {
        registerStripeCardViewFactory(pk);
      }
    }
  }

  void _initPremiumDefaults() {
    if (_policies.isNotEmpty) {
      _selectedPolicy = _policies.first['policy'] as Map<String, dynamic>?;
    }
    final now = DateTime.now();
    const months = [
      '', 'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    _scheduleMonth = '${months[now.month]} ${now.year}';
    _premiumFrequency = 'monthly';
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _refCtrl.dispose();
    _phoneCtrl.dispose();
    _bankCtrl.dispose();
    super.dispose();
  }

  void _selectTab(String tab) {
    setState(() {
      _tab = tab;
      _message = null;
      if (tab == 'premium') {
        _premiumFrequency = 'monthly';
        _amountCtrl.text = _selectedPolicy?['premiumAmount']?.toString() ?? '';
      } else {
        _amountCtrl.clear();
      }
    });
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

  String? _validateAmount() {
    if (_tab == 'premium') {
      if (_selectedPolicy == null) return 'Please select a policy.';
      final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0;
      if (amount <= 0) return 'Please enter a valid amount.';
      return null;
    }
    final cents = _amountCents;
    if (cents == null) return 'Enter an amount.';
    if (_tab == 'membership') {
      if (cents < 5000) {
        return 'Membership shares require a \$50 minimum.';
      }
    } else {
      if (cents < 50000) return 'Preferred shares require a \$500 minimum.';
    }
    return null;
  }

  Future<void> _submit() async {
    final validationError = _validateAmount();
    if (validationError != null) {
      setState(() => _message = validationError);
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

    // Require explicit confirmation before charging in Pay mode.
    if (!widget.collectMode) {
      final amount = _amountCtrl.text.trim();
      final typeLabel = _tab == 'premium'
          ? 'premium'
          : _tab == 'preferred'
              ? 'preferred share'
              : 'membership share';
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Confirm Payment'),
          content: Text(
            'Charge \$$amount for $typeLabel?\n\nMethod: ${_methodLabel(_paymentMethod)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() { _isSaving = true; _message = null; });

    try {
      if (_tab == 'premium') {
        final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0;
        if (_paymentMethod == 'STRIPE') {
          await _submitPremiumStripe(amount);
        } else {
          await _submitPremiumManual(amount, ref, phone, bank);
        }
      } else {
        if (_paymentMethod == 'STRIPE') {
          await _submitShareStripe();
        } else {
          await _submitShareManual();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          debugPrint('[MemberDetail] action error: $e');
          _message  = 'Something went wrong. Please try again.';
        });
      }
    }
  }

  // ── Premium (policy) payment ─────────────────────────────────────────────

  Future<void> _submitPremiumStripe(double amount) async {
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

  Future<void> _submitPremiumManual(
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

  // ── Shares (membership / preferred) ──────────────────────────────────────

  Future<void> _submitShareStripe() async {
    final amountCents = _amountCents!;
    final res = await http.post(
      Uri.parse('$kApiBaseUrl${devPath('/member/shares/create-intent')}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'member_id':    widget.member.memberId,
        'company_id':   widget.member.companyId,
        'share_type':   _tab,
        'amount_cents': amountCents,
      }),
    );

    if (res.statusCode != 200) {
      String msg = 'Payment failed (${res.statusCode}).';
      try {
        final err = jsonDecode(res.body) as Map<String, dynamic>;
        msg = err['error'] as String? ?? msg;
      } catch (_) {}
      throw Exception(msg);
    }

    final data         = jsonDecode(res.body) as Map<String, dynamic>;
    final clientSecret = data['client_secret'] as String;
    final shareId      = data['share_id']      as String? ?? '';

    await confirmStripePayment(clientSecret);

    if (mounted) {
      final amountDollars = _amountCents! / 100.0;
      setState(() {
        _isSaving = false;
        _message  = '✓ Payment recorded.';
        _localShares = [
          ..._localShares,
          {
            'shareType':     _tab,
            'amount':        amountDollars,
            'datetime':      DateTime.now().toUtc().toIso8601String(),
            'status':        'SUCCEEDED',
            'paymentMethod': 'STRIPE',
            'apr':           (data['apr'] as num?)?.toDouble() ?? 0.0,
            'shareId':       shareId,
            'externalRef':   shareId,
          },
        ];
        _amountCtrl.clear();
      });
      widget.onSuccess('✓ Share payment recorded.');
    }
  }

  Future<void> _submitShareManual() async {
    final api         = context.read<AuthProvider>().apiService!;
    final amountCents = _amountCents!;
    final ref         = _refCtrl.text.trim();
    final apr = await api.recordSharePayment(
      memberId:      widget.member.memberId,
      shareType:     _tab,
      amountCents:   amountCents,
      paymentMethod: _paymentMethod,
      externalRef:   ref,
    );

    if (mounted) {
      setState(() {
        _isSaving = false;
        _message  = '✓ Recorded.';
        _localShares = [
          ..._localShares,
          {
            'shareType':     _tab,
            'amount':        amountCents / 100.0,
            'datetime':      DateTime.now().toUtc().toIso8601String(),
            'status':        'SUCCEEDED',
            'paymentMethod': _paymentMethod,
            'apr':           apr,
            'shareId':       ref,
            'externalRef':   ref,
          },
        ];
        _amountCtrl.clear();
        _refCtrl.clear();
      });
      widget.onSuccess('✓ Share recorded.');
    }
  }

  // ── Transaction history ───────────────────────────────────────────────────

  List<Map<String, dynamic>> get _shareHistory {
    final type = _tab;
    return _localShares
        .where((s) => (s['shareType'] as String? ?? '') == type)
        .toList()
        .reversed
        .toList();
  }

  List<Map<String, dynamic>> get _premiumHistory {
    if (_selectedPolicy == null) return [];
    final policyNo = _selectedPolicy!['policyNo'] as String? ?? '';
    final entry = _policies.cast<Map<String, dynamic>?>().firstWhere(
      (p) => ((p?['policy'] as Map?)?['policyNo'] as String? ?? '') == policyNo,
      orElse: () => null,
    );
    if (entry == null) return [];
    return List<Map<String, dynamic>>.from(
        (entry['paymentHistory'] as List?)?.reversed.toList() ?? []);
  }

  Widget _buildHistorySection(String locale) {
    final isPremium = _tab == 'premium';
    final history   = isPremium ? _premiumHistory : _shareHistory;
    if (history.isEmpty) return const SizedBox.shrink();

    String s(String key) => AppStrings.get(key, locale);

    String statusLabel(String status) {
      switch (status.toUpperCase()) {
        case 'SUCCEEDED': return s('statusSucceeded');
        case 'PAID':      return s('statusPaid');
        case 'FAILED':    return s('statusFailed');
        default:          return s('statusPending');
      }
    }

    Color statusColor(String status) {
      switch (status.toUpperCase()) {
        case 'SUCCEEDED': case 'PAID': return Colors.green.shade700;
        case 'FAILED':    return Colors.red;
        default:          return Colors.orange.shade700;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 28),
        Text(s('paymentHistory'),
            style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4)),
        const SizedBox(height: 8),
        ...history.map((tx) {
          final dateRaw = isPremium
              ? (tx['paymentDate'] as String? ?? '')
              : (tx['datetime'] as String? ?? '');
          final amount  = tx[isPremium ? 'amountPaid' : 'amount'];
          final status  = isPremium ? 'PAID' : (tx['status'] as String? ?? '');
          final period  = isPremium ? (tx['paymentPeriod'] as String? ?? '') : '';
          final apr     = !isPremium ? (tx['apr'] as num?)?.toDouble() ?? 0 : 0.0;

          final date = DateTime.tryParse(dateRaw);
          final dateLabel = date != null
              ? AppStrings.formatDate(dateRaw.split('T').first, locale)
              : '—';

          return Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(dateLabel,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      if (period.isNotEmpty)
                        Text(AppStrings.formatDate(period, locale),
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500)),
                      if (!isPremium && apr > 0)
                        Text('APR: ${apr.toStringAsFixed(2)}%',
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500)),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('\$${(amount ?? 0).toStringAsFixed(2)}',
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700)),
                        if (status.toUpperCase() == 'SUCCEEDED' ||
                            status.toUpperCase() == 'PAID') ...[
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () {
                              final amountStr =
                                  '\$${(amount ?? 0).toStringAsFixed(2)}';
                              final shareLabel = isPremium
                                  ? (period.isNotEmpty ? period : dateLabel)
                                  : (_tab == 'preferred'
                                      ? 'Preferred Share'
                                      : 'Membership Share');
                              var waPhone = widget.member.phone
                                  .replaceAll(RegExp(r'[^0-9]'), '');
                              if (waPhone.length == 10) waPhone = '1$waPhone';
                              final msg =
                                  'Hello ${widget.member.fullName}\n\n'
                                  '*Payment Receipt*\n'
                                  'Amount: $amountStr\n'
                                  'Type: $shareLabel\n'
                                  'Date: $dateLabel\n'
                                  'Method: ${_methodLabel(tx['paymentMethod'] as String?)}\n'
                                  'Reference: ${tx['externalRef'] as String? ?? tx['shareId'] as String? ?? ''}\n\n'
                                  'Thank you for your payment!\n\n'
                                  'KAFA - 874 Rue Ste Catherine, Leogane, Haiti';
                              final encoded = Uri.encodeComponent(msg);
                              final url = waPhone.isNotEmpty
                                  ? 'https://wa.me/$waPhone?text=$encoded'
                                  : 'https://wa.me/?text=$encoded';
                              launchUrl(Uri.parse(url),
                                  mode: LaunchMode.externalApplication);
                            },
                            child: const Icon(Icons.send,
                                size: 16, color: Color(0xFF25D366)),
                          ),
                        ],
                      ],
                    ),
                    Text(statusLabel(status),
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: statusColor(status))),
                  ],
                ),
              ],
            ),
          );
        }),
      ],
    );
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
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final apr = _tab == 'preferred'
        ? previewPreferredApr(_amountCents ?? 0)
        : 0.0;
    final isPremium = _tab == 'premium';

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
              Icon(isPremium ? Icons.payments_outlined : Icons.savings_outlined,
                  color: isPremium ? const Color(0xFF1A5C2A) : const Color(0xFF8B6914),
                  size: 22),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_title(isPremium),
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                Text(widget.member.fullName,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500)),
              ])),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.pop(context),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
              ),
            ]),
            const SizedBox(height: 20),

            // Tabs: Membership | Preferred | Premium
            Row(children: [
              Expanded(
                child: _ShareTypeChip(
                  label: s('shareMembership'),
                  selected: _tab == 'membership',
                  onTap: () => _selectTab('membership'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ShareTypeChip(
                  label: s('sharePreferred'),
                  selected: _tab == 'preferred',
                  enabled: !_isPending,
                  onTap: _isPending ? null : () => _selectTab('preferred'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _ShareTypeChip(
                  label: s('premiumTab'),
                  selected: _tab == 'premium',
                  enabled: !_hasNoPolicies,
                  onTap: _hasNoPolicies ? null : () => _selectTab('premium'),
                ),
              ),
            ]),
            if (_isPending) ...[
              const SizedBox(height: 6),
              Text(
                s('mustPayMembershipShareFirst'),
                style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
              ),
            ],
            if (_hasNoPolicies) ...[
              const SizedBox(height: 6),
              Text(
                s('noPolicyCreateFirst'),
                style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
              ),
            ],
            const SizedBox(height: 14),

            if (isPremium) ...[
              // Policy
              if (_policies.isEmpty)
                Text(s('noPoliciesFoundForMember'),
                    style: TextStyle(color: Colors.grey.shade500))
              else
                DropdownButtonFormField<Map<String, dynamic>>(
                  value: _selectedPolicy,
                  decoration: InputDecoration(
                    labelText: s('policyLabel'),
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
                    _premiumFrequency = 'monthly';
                    _amountCtrl.text = pol?['premiumAmount']?.toString() ?? '';
                  }),
                ),
              if (!widget.collectMode) ...[
                const SizedBox(height: 12),

                // Period
                DropdownButtonFormField<String>(
                  value: _scheduleMonth,
                  decoration: InputDecoration(
                    labelText: s('paymentPeriodLabel'),
                    prefixIcon: const Icon(Icons.calendar_month_outlined),
                    isDense: true,
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  items: () {
                    const monthsByLocale = {
                      'en': ['January', 'February', 'March', 'April', 'May', 'June',
                          'July', 'August', 'September', 'October', 'November', 'December'],
                      'es': ['Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
                          'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre'],
                      'pt': ['Janeiro', 'Fevereiro', 'Março', 'Abril', 'Maio', 'Junho',
                          'Julho', 'Agosto', 'Setembro', 'Outubro', 'Novembro', 'Dezembro'],
                      'fr': ['Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
                          'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'],
                    };
                    final months = monthsByLocale[locale] ?? monthsByLocale['fr']!;
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

                Builder(builder: (context) {
                  final monthly = double.tryParse(
                          _selectedPolicy?['premiumAmount']?.toString() ?? '') ??
                      0;
                  final annual = monthly * 12;
                  return DropdownButtonFormField<String>(
                    key: ValueKey(_premiumFrequency),
                    initialValue: _premiumFrequency,
                    decoration: InputDecoration(
                      labelText: s('paymentFrequencyLabel'),
                      prefixIcon: const Icon(Icons.attach_money),
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'monthly',
                        child: Text(
                            'Monthly (US\$${monthly.toStringAsFixed(2)})'),
                      ),
                      DropdownMenuItem(
                        value: 'annual',
                        child: Text(
                            'Annual (US\$${annual.toStringAsFixed(2)})'),
                      ),
                    ],
                    onChanged: (v) => setState(() {
                      _premiumFrequency = v ?? 'monthly';
                      _amountCtrl.text = _premiumFrequency == 'annual'
                          ? annual.toStringAsFixed(2)
                          : monthly.toStringAsFixed(2);
                    }),
                  );
                }),
              ],
            ] else if (!widget.collectMode) ...[
              // Amount (membership / preferred)
              TextField(
                controller: _amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: _tab == 'membership'
                      ? s('amountMin50Label')
                      : s('amountMin500Label'),
                  prefixIcon: const Icon(Icons.attach_money),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
              if (_tab == 'preferred') ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(children: [
                    const Icon(Icons.percent, size: 16, color: Color(0xFF1A5C2A)),
                    const SizedBox(width: 8),
                    Text('APR: ${apr.toStringAsFixed(2)}%',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                ),
              ],
            ],

            if (!widget.collectMode) ...[
              const SizedBox(height: 12),

              // Payment method
              DropdownButtonFormField<String>(
                value: _paymentMethod,
                decoration: InputDecoration(
                  labelText: s('paymentMethodLabel'),
                  prefixIcon: const Icon(Icons.payment),
                  isDense: true,
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                items: [
                  DropdownMenuItem(value: 'CASH',         child: Text('💵  ${s('cashOption')}')),
                  const DropdownMenuItem(value: 'MOBILE_MONEY', child: Text('📱  MonCash')),
                  DropdownMenuItem(value: 'BANK_TRANSFER', child: Text('🏦  ${s('bankTransferOption')}')),
                  DropdownMenuItem(value: 'STRIPE', child: Text('💳  ${s('onlineStripeOption')}')),
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
                  labelText: s('monCashPhoneLabel'),
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
                  labelText: s('monCashTransactionIdLabel'),
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
                  labelText: s('bankNameLabel'),
                  prefixIcon: const Icon(Icons.account_balance),
                  hintText: s('bankNameHint'),
                  isDense: true,
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _refCtrl,
                decoration: InputDecoration(
                  labelText: s('transferReferenceLabel'),
                  prefixIcon: const Icon(Icons.tag),
                  hintText: 'BNK-XXXXXXXXXX',
                  isDense: true,
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ] else if (_paymentMethod == 'STRIPE') ...[
              _stripeField(s('cardNumber'), stripeCardHtmlView()),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: _stripeField(s('expiry'), stripeExpiryHtmlView())),
                const SizedBox(width: 10),
                Expanded(child: _stripeField(s('cvc'), stripeCvcHtmlView())),
              ]),
            ] else ...[
              TextField(
                controller: _refCtrl,
                decoration: InputDecoration(
                  labelText: s('receiptNumberOptionalLabel'),
                  prefixIcon: const Icon(Icons.receipt),
                  hintText: s('autoGenerateHint'),
                  isDense: true,
                  filled: true, fillColor: Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],

            ], // end if (!widget.collectMode)

            // Transaction history
            _buildHistorySection(locale),

            // Feedback
            if (!widget.collectMode && _message != null) ...[
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

            if (widget.collectMode) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  child: Text(s('done')),
                ),
              ),
            ] else ...[
            // Submit button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: _isSaving
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Icon(
                        _paymentMethod == 'STRIPE'
                            ? Icons.payment
                            : (isPremium ? Icons.payment : Icons.savings_outlined),
                        size: 18),
                label: Text(_title(isPremium)),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      isPremium ? const Color(0xFF1A5C2A) : const Color(0xFF8B6914),
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
          ],
        ),
      ),
    );
  }
}

class _ShareTypeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  const _ShareTypeChip({
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
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF1A5C2A) : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: selected ? const Color(0xFF1A5C2A) : Colors.grey.shade400),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? Colors.white : Colors.black87,
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
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
          debugPrint('[MemberDetail] action error: $e');
          _message  = 'Something went wrong. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.read<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
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
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s('createPolicy'),
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                Text(widget.member.fullName,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500)),
              ])),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.pop(context),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                visualDensity: VisualDensity.compact,
              ),
            ]),
            const SizedBox(height: 20),

            Text(s('selectPlan'),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
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
                                'HTG ${plan['coverage']} ${s('coverageLabel').toLowerCase()}',
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
                label: Text(s('createPolicy')),
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

// ── Setup Link Share Sheet ────────────────────────────────────────────────────

class _SetupLinkShareSheet extends StatefulWidget {
  final String setupLink;
  final String whatsAppUrl;
  const _SetupLinkShareSheet({required this.setupLink, required this.whatsAppUrl});
  @override
  State<_SetupLinkShareSheet> createState() => _SetupLinkShareSheetState();
}

class _SetupLinkShareSheetState extends State<_SetupLinkShareSheet> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    const green = Color(0xFF1A5C2A);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              const Expanded(
                child: Text('Share setup link',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
            _SetupShareOption(
              icon: Icons.chat,
              iconColor: const Color(0xFF25D366),
              label: 'Send to WhatsApp',
              onTap: () async {
                Navigator.pop(context);
                final uri = Uri.parse(widget.whatsAppUrl);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
            const Divider(height: 24),
            _SetupShareOption(
              icon: _copied ? Icons.check_circle : Icons.link,
              iconColor: _copied ? green : Colors.grey.shade700,
              label: _copied ? 'Link copied!' : 'Copy link',
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: widget.setupLink));
                setState(() => _copied = true);
                await Future.delayed(const Duration(seconds: 2));
                if (mounted) setState(() => _copied = false);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupShareOption extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final VoidCallback onTap;
  const _SetupShareOption({
    required this.icon, required this.iconColor,
    required this.label, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 16),
          Text(label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}