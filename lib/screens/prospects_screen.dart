import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/member.dart';
import '../providers/auth_provider.dart';
import '../services/dev_env.dart';
import '../misc/app_strings.dart';

// Status helpers
Color _statusColor(String? status) {
  switch (status?.toLowerCase()) {
    case 'accepted': return const Color(0xFF1A5C2A);
    case 'rejected': return Colors.red.shade600;
    case 'pending':  return const Color(0xFF1565C0);
    default:         return Colors.orange.shade700; // new / empty
  }
}

Color _statusBg(String? status) {
  switch (status?.toLowerCase()) {
    case 'accepted': return const Color(0xFFE8F5E9);
    case 'rejected': return Colors.red.shade50;
    case 'pending':  return const Color(0xFFE3F2FD);
    default:         return Colors.orange.shade50;  // new / empty
  }
}

String _statusLabel(String? status) {
  switch (status?.toLowerCase()) {
    case 'accepted': return 'Accepted';
    case 'rejected': return 'Rejected';
    case 'pending':  return 'Pending';
    default:         return 'New'; // empty string or null = fresh submission
  }
}

const _green = Color(0xFF1A5C2A);
const _gold  = Color(0xFFC8A96E);
const _bg    = Color(0xFFF2F4F7);

class ProspectsScreen extends StatefulWidget {
  final bool embedded;
  final String locale;
  final String? deepLinkId;
  const ProspectsScreen({super.key, this.embedded = false, this.locale = 'fr', this.deepLinkId});

  @override
  State<ProspectsScreen> createState() => _ProspectsScreenState();
}

class _ProspectsScreenState extends State<ProspectsScreen> {
  List<Map<String, dynamic>> _all = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;
  String? _error;
  Timer? _timer;
  bool _deepLinkHandled = false;
  final _searchCtrl = TextEditingController();
  String _statusFilter = 'All';

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_filter);
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = context.read<AuthProvider>().apiService!;
      final prospects = await api.getProspects();
      setState(() {
        _all = prospects;
        _loading = false;
      });
      _filter();
      _handleDeepLink();
    } catch (e) {
      debugPrint('[ProspectsScreen] load error: $e');
      setState(() { _error = 'Something went wrong. Please try again.'; _loading = false; });
    }
  }

  void _handleDeepLink() {
    final id = widget.deepLinkId;
    if (id == null || _deepLinkHandled) return;
    final match = _all.cast<Map<String, dynamic>?>().firstWhere(
      (p) => p?['id'] == id,
      orElse: () => null,
    );
    if (match != null && mounted) {
      _deepLinkHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _openDetail(match));
    }
  }

  void _filter() {
    final q = _searchCtrl.text.trim().toLowerCase();
    setState(() {
      _filtered = _all.where((p) {
        final name  = '${p['firstName']} ${p['lastName']}'.toLowerCase();
        final phone = (p['phone'] ?? '').toLowerCase();
        final num   = (p['memberNumber'] ?? '').toLowerCase();
        final matchesQ = q.isEmpty ||
            name.contains(q) || phone.contains(q) || num.contains(q);
        final status = (p['status'] as String? ?? 'pending').toLowerCase();
        final matchesS = _statusFilter == 'All' ||
            (_statusFilter == 'New' && (status.isEmpty || status == 'new')) ||
            (_statusFilter != 'New' && status == _statusFilter.toLowerCase());
        return matchesQ && matchesS;
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final locale = widget.locale;
    String s(String k) => AppStrings.get(k, locale);
    final body = Column(
      children: [
        _SearchBar(controller: _searchCtrl, hint: s('adminSearchProspects')),
        _StatusFilterBar(
          selected: _statusFilter,
          labels: {
            'All':      s('all'),
            'New':      s('adminStatusNew'),
            'Pending':  s('adminStatusPending'),
            'Accepted': s('adminStatusAccepted'),
            'Rejected': s('adminStatusRejected'),
          },
          counts: {
            'All':      _all.length,
            'New':      _all.where((p) {
                final st = (p['status'] as String? ?? '').toLowerCase();
                return st.isEmpty || st == 'new';
              }).length,
            'Pending':  _all.where((p) =>
                (p['status'] as String? ?? '').toLowerCase() == 'pending').length,
            'Accepted': _all.where((p) =>
                (p['status'] as String? ?? '').toLowerCase() == 'accepted').length,
            'Rejected': _all.where((p) =>
                (p['status'] as String? ?? '').toLowerCase() == 'rejected').length,
          },
          onSelect: (st) { setState(() => _statusFilter = st); _filter(); },
        ),
        Expanded(child: _buildBody()),
      ],
    );

    if (widget.embedded) {
      return Container(color: _bg, child: body);
    }
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _green,
        title: Text(AppStrings.get('adminProspects', locale),
            style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: body,
    );
  }

  Widget _buildBody() {
    final locale = widget.locale;
    String s(String k) => AppStrings.get(k, locale);
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _green));
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 40),
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _load, child: Text(s('retry'))),
        ]),
      );
    }
    if (_filtered.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.person_search, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            _searchCtrl.text.isEmpty ? s('adminNoProspects') : s('noMembersFound'),
            style: TextStyle(color: Colors.grey.shade500, fontSize: 15),
          ),
        ]),
      );
    }
    return RefreshIndicator(
      color: _green,
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _filtered.length,
        itemBuilder: (_, i) => _ProspectCard(
          prospect: _filtered[i],
          onTap: () => _openDetail(_filtered[i]),
        ),
      ),
    );
  }

  void _openDetail(Map<String, dynamic> p) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _ProspectDetailScreen(prospect: p, locale: widget.locale)),
    );
    _load(); // refresh after any status change
  }
}

// ── Search bar ────────────────────────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  const _SearchBar({required this.controller, required this.hint});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(fontSize: 14, color: Colors.grey.shade400),
          prefixIcon: const Icon(Icons.search, color: _green, size: 20),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => controller.clear(),
                )
              : null,
          filled: true,
          fillColor: _bg,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

// ── Status filter bar ─────────────────────────────────────────────────────────

class _StatusFilterBar extends StatelessWidget {
  final String selected;
  final Map<String, String> labels;  // key → translated display text
  final Map<String, int> counts;
  final void Function(String) onSelect;
  const _StatusFilterBar(
      {required this.selected, required this.labels,
       required this.counts, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    const keys = ['All', 'New', 'Pending', 'Accepted', 'Rejected'];
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: keys.map((key) {
          final displayLabel = labels[key] ?? key;
          final active = selected == key;
          final count  = counts[key] ?? 0;
          Color activeColor;
          switch (key) {
            case 'Accepted': activeColor = _green; break;
            case 'Rejected': activeColor = Colors.red.shade600; break;
            case 'Pending':  activeColor = const Color(0xFF1565C0); break;
            case 'New':      activeColor = Colors.orange.shade700; break;
            default:         activeColor = Colors.grey.shade700;
          }
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => onSelect(key),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: active ? activeColor : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$displayLabel ($count)',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: active ? FontWeight.w700 : FontWeight.normal,
                    color: active ? Colors.white : Colors.grey.shade600,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Prospect card ─────────────────────────────────────────────────────────────

class _ProspectCard extends StatelessWidget {
  final Map<String, dynamic> prospect;
  final VoidCallback onTap;
  const _ProspectCard({required this.prospect, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final firstName = prospect['firstName'] as String? ?? '';
    final lastName  = prospect['lastName']  as String? ?? '';
    final fullName  = '$firstName $lastName'.trim();
    final phone     = prospect['phone'] as String? ?? '—';
    final num       = prospect['memberNumber'] as String? ?? '';
    final createdAt = prospect['createdAt'] as String? ?? '';
    final date      = createdAt.length >= 10 ? createdAt.substring(0, 10) : createdAt;
    final initials  = _initials(firstName, lastName);
    final status    = prospect['status'] as String?;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            CircleAvatar(
              radius: 22,
              backgroundColor: _gold.withValues(alpha: 0.15),
              child: Text(
                initials,
                style: const TextStyle(
                  color: _gold, fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  fullName.isEmpty ? '(No name)' : fullName,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(phone, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                if (num.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(num, style: const TextStyle(fontSize: 11, color: _green)),
                ],
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusBg(status),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  _statusLabel(status),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: _statusColor(status),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              if (date.isNotEmpty)
                Text(date, style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
              const SizedBox(height: 2),
              const Icon(Icons.chevron_right, color: _green, size: 18),
            ]),
          ]),
        ),
      ),
    );
  }

  String _initials(String first, String last) {
    final f = first.isNotEmpty ? first[0].toUpperCase() : '';
    final l = last.isNotEmpty  ? last[0].toUpperCase()  : '';
    return '$f$l'.isEmpty ? '?' : '$f$l';
  }
}

// ── Prospect detail ───────────────────────────────────────────────────────────

class _ProspectDetailScreen extends StatefulWidget {
  final Map<String, dynamic> prospect;
  final String locale;
  const _ProspectDetailScreen({required this.prospect, required this.locale});

  @override
  State<_ProspectDetailScreen> createState() => _ProspectDetailScreenState();
}

class _ProspectDetailScreenState extends State<_ProspectDetailScreen> {
  late String _status;
  bool _saving = false;
  bool _savingNote = false;
  String? _successMsg;
  String? _createdMemberId;
  String? _setupLink;
  late TextEditingController _noteCtrl;

  @override
  void initState() {
    super.initState();
    _status = (widget.prospect['status'] as String? ?? 'pending').toLowerCase();
    _noteCtrl = TextEditingController(
        text: widget.prospect['accepterNote'] as String? ?? '');
  }

  /// Mints a fresh setup link (requires the member to have an email on
  /// file) and shows the share sheet with it. Falls back to whatever
  /// token is cached on the member record — which may be expired — only
  /// if a fresh one can't be minted (e.g. no email on file), so phone-only
  /// members can still be shared with.
  Future<void> _shareSetupLink() async {
    final memberId = widget.prospect['memberId'] as String? ?? _createdMemberId;
    if (memberId == null || memberId.isEmpty) return;
    try {
      final api = context.read<AuthProvider>().apiService!;
      final (_, link) = await api.sendMemberPasswordSetupEmail(memberId);
      if (link != null && mounted) {
        setState(() => _setupLink = link);
        _showShareSheet(link);
        return;
      }
    } catch (_) {}
    await _loadSetupLink();
    if (_setupLink != null && mounted) _showShareSheet(_setupLink!);
  }

  Future<void> _loadSetupLink() async {
    try {
      final api      = context.read<AuthProvider>().apiService!;
      final memberId = widget.prospect['memberId'] as String?;
      Member? member;

      if (memberId != null && memberId.isNotEmpty) {
        member = await api.getMember(memberId);
      } else {
        // Fall back: find member by matching phone from the members list.
        final phone = (widget.prospect['phone'] as String? ?? '').trim();
        if (phone.isEmpty) return;
        final all = await api.listMembers();
        member = all.cast<Member?>().firstWhere(
          (m) => m?.phone == phone,
          orElse: () => null,
        );
      }

      final token = member?.setupToken;
      if (token != null && token.isNotEmpty && mounted) {
        setState(() => _setupLink = '$kMemberPortalUrl?setup=$token');
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _setStatus(String newStatus) async {
    final id  = widget.prospect['id'] as String? ?? '';
    final api = context.read<AuthProvider>().apiService!;
    if (id.isEmpty) return;

    final locale = widget.locale;
    String s(String k) => AppStrings.get(k, locale);

    if (newStatus == 'accepted' && _status != 'accepted') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text(s('adminConvertToMember')),
          content: Text(s('cancel') == 'Cancel'
              ? 'This will create a new member record from this prospect\'s data. Continue?'
              : AppStrings.get('enrollmentNote', locale)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(s('cancel'))),
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: _green),
                onPressed: () => Navigator.pop(context, true),
                child: Text(s('adminConvertToMember'))),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    setState(() { _saving = true; _successMsg = null; });
    try {
      final result = await api.updateProspectStatus(id, newStatus, note: _noteCtrl.text.trim());
      setState(() {
        _status = newStatus;
        _saving = false;
        if (result['memberCreated'] == true) {
          _createdMemberId = result['memberId'] as String?;
          _successMsg = '${s('adminMembers')}: ${_createdMemberId ?? ''}';
        } else {
          _successMsg = _statusLabel(newStatus);
        }
      });
      if (result['memberCreated'] == true && mounted) {
        final link = result['setupLink'] as String?;
        if (link != null) {
          setState(() => _setupLink = link);
          _showShareSheet(link);
        }
      }
    } catch (e) {
      debugPrint('[ProspectsScreen] save error: $e');
      setState(() { _saving = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Something went wrong. Please try again.'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showShareSheet(String setupLink) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ShareSheet(
        setupLink: setupLink,
        whatsAppUrl: _buildWhatsAppUrl(setupLink),
      ),
    );
  }

  String _buildWhatsAppUrl(String setupLink) {
    final p         = widget.prospect;
    final firstName = p['firstName'] as String? ?? '';
    final lastName  = p['lastName']  as String? ?? '';
    final name      = '$firstName $lastName'.trim();
    final memberId  = _createdMemberId ?? '';
    // Normalize to E.164: 10-digit NANP numbers need a leading 1.
    var phone = (p['phone'] as String? ?? '').replaceAll(RegExp(r'[^0-9]'), '');
    if (phone.length == 10) phone = '1$phone';

    final message = 'Congratulations, $name! 🎉\n\n'
        'We are pleased to inform you that your KAFA membership application has been *approved*. '
        'Welcome to the KAFA family!\n\n'
        '*Your Member Number*\n'
        '$memberId\n\n'
        'You can continue your account setup here:\n'
        '$setupLink\n\n'
        'If you have any questions, feel free to reach us:\n'
        '📧 kontak@kafayiti.com\n'
        '📞 (509) 3500-0326 / (509) 4439-8595\n'
        '🌐 kafayiti.com\n\n'
        'KAFA — 874 Rue Ste Catherine, Léogâne, Haïti';

    final encoded = Uri.encodeComponent(message);
    return phone.isNotEmpty
        ? 'https://wa.me/$phone?text=$encoded'
        : 'https://wa.me/?text=$encoded';
  }

  String _statusLabelLocalized(String status, String Function(String) s) {
    switch (status.toLowerCase()) {
      case 'accepted': return s('adminStatusAccepted');
      case 'rejected': return s('adminStatusRejected');
      case 'pending':  return s('adminStatusPending');
      default:         return s('adminStatusNew');
    }
  }

  Future<void> _saveNote() async {
    final id  = widget.prospect['id'] as String? ?? '';
    final api = context.read<AuthProvider>().apiService!;
    if (id.isEmpty) return;
    setState(() => _savingNote = true);
    try {
      await api.saveProspectNote(id, _noteCtrl.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppStrings.get('noteSaved', widget.locale)), backgroundColor: _green),
        );
      }
    } catch (e) {
      debugPrint('[ProspectsScreen] note save error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Something went wrong. Please try again.'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _savingNote = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p         = widget.prospect;
    final firstName = p['firstName'] as String? ?? '';
    final lastName  = p['lastName']  as String? ?? '';
    final fullName  = '$firstName $lastName'.trim();

    final locale = widget.locale;
    String s(String k) => AppStrings.get(k, locale);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _green,
        title: Text(fullName.isEmpty ? s('adminProspects') : fullName,
            style: const TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_status == 'accepted')
            IconButton(
              icon: const Icon(Icons.share, color: Colors.white),
              tooltip: 'Share',
              onPressed: _shareSetupLink,
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(s('sectionStatus'),
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _green,
                        letterSpacing: 0.5)),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: _statusBg(_status),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(_statusLabelLocalized(_status, s),
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _statusColor(_status))),
                ),
              ]),
              const SizedBox(height: 12),
              if (_saving)
                const Center(child: CircularProgressIndicator(color: _green))
              else
                Row(children: [
                  _StatusBtn(
                    label: s('adminConvertToMember'),
                    icon: Icons.person_add_outlined,
                    color: _green,
                    active: _status == 'accepted',
                    onTap: () => _setStatus('accepted'),
                  ),
                  const SizedBox(width: 8),
                  _StatusBtn(
                    label: s('adminStatusPending'),
                    icon: Icons.hourglass_empty,
                    color: const Color(0xFF1565C0),
                    active: _status == 'pending',
                    onTap: () => _setStatus('pending'),
                  ),
                  const SizedBox(width: 8),
                  _StatusBtn(
                    label: s('adminStatusRejected'),
                    icon: Icons.cancel_outlined,
                    color: Colors.red.shade600,
                    active: _status == 'rejected',
                    onTap: () => _setStatus('rejected'),
                  ),
                ]),
              if (_successMsg != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _statusBg(_status),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.check_circle, color: _statusColor(_status), size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_successMsg!,
                          style: TextStyle(
                              fontSize: 13,
                              color: _statusColor(_status),
                              fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),
              ],
              if (_status == 'accepted') ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Share'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _green,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: _shareSetupLink,
                  ),
                ),
              ],
            ]),
          ),
          const SizedBox(height: 12),
          _DetailCard(title: s('sectionContact'), fields: {
            s('fullName').split(' ').first:  p['firstName'],
            s('fullName').split(' ').last:   p['lastName'],
            s('phone'):    p['phone'],
            s('email'):    p['email'],
            s('memberNumberLabel'): p['memberNumber'],
            s('planLabel'): p['plan'],
          }),
          const SizedBox(height: 12),
          _DetailCard(title: s('sectionPersonalInfo'), fields: {
            s('commune'):    p['gender'],
            s('notes'):      p['profession'],
            s('address'):    p['address'],
            s('commune'):    p['commune'],
            s('dateOfBirth'): p['birthDatePlace'],
          }),
          const SizedBox(height: 12),
          _DetailCard(title: s('sectionIdentification'), fields: {
            s('idType'):   p['idType'],
            s('idNumber'): p['idNumber'],
            s('issueLabel'):      p['idIssueDetails'],
            s('expirationLabel'): p['idExpirationDate'],
          }),
          if ((p['message'] as String? ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            _DetailCard(title: s('sectionNotes'), fields: {s('notes'): p['message']}),
          ],
          const SizedBox(height: 12),
          _DetailCard(title: s('metaLabel'), fields: {
            'ID':        p['id'],
            s('issuedDate'): p['createdAt'],
          }),
          const SizedBox(height: 12),
          // ── Accepter's Note ────────────────────────────────────────────────
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s('adminAcceptersNote'),
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: _green,
                      letterSpacing: 0.5)),
              const SizedBox(height: 10),
              TextField(
                controller: _noteCtrl,
                maxLines: 4,
                decoration: InputDecoration(
                  hintText: '...',
                  hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                  filled: true,
                  fillColor: _bg,
                  contentPadding: const EdgeInsets.all(12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: _green,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: _savingNote ? null : _saveNote,
                  child: _savingNote
                      ? const SizedBox(
                          height: 18, width: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : Text(s('adminSaveNote')),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}

class _StatusBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool active;
  final VoidCallback onTap;
  const _StatusBtn({
    required this.label, required this.icon, required this.color,
    required this.active, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: active ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: active ? color : color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: active ? 0 : 0.3)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: active ? Colors.white : color, size: 20),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: active ? Colors.white : color)),
          ]),
        ),
      ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  final String title;
  final Map<String, dynamic> fields;
  const _DetailCard({required this.title, required this.fields});

  @override
  Widget build(BuildContext context) {
    final rows = fields.entries
        .where((e) => (e.value as String? ?? '').isNotEmpty)
        .toList();

    if (rows.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Text(title,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _green,
                  letterSpacing: 0.5)),
        ),
        const Divider(height: 1),
        ...rows.map((e) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(e.key,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500)),
                  ),
                  Expanded(
                    child: Text(
                      e.value as String? ?? '',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            )),
      ]),
    );
  }
}

// ── Share sheet ───────────────────────────────────────────────────────────────

class _ShareSheet extends StatefulWidget {
  final String setupLink;
  final String whatsAppUrl;
  const _ShareSheet({required this.setupLink, required this.whatsAppUrl});

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
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
            const Text(
              'Share',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            _ShareOption(
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
            _ShareOption(
              icon: _copied ? Icons.check_circle : Icons.link,
              iconColor: _copied ? _green : Colors.grey.shade700,
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

class _ShareOption extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final VoidCallback onTap;
  const _ShareOption({
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
