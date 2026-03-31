import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../services/session_service.dart';
import 'member_login_screen.dart';
import 'chatbot_widget.dart';
import 'policy_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Colour palette
// ─────────────────────────────────────────────────────────────────────────────
const _green = Color(0xFF1A5C2A);
const _gold = Color(0xFFC8A96E);
const _bg = Color(0xFFF2F4F7);

class MemberDashboardScreen extends StatefulWidget {
  final Map<String, dynamic> member;
  const MemberDashboardScreen({super.key, required this.member});

  @override
  State<MemberDashboardScreen> createState() => _MemberDashboardScreenState();
}

class _MemberDashboardScreenState extends State<MemberDashboardScreen> {
  int  _tab       = 0;
  bool _hasPolicy = true; // optimistic — updated after first fetch

  @override
  void initState() {
    super.initState();
    _checkPolicy();
  }

  Future<void> _checkPolicy() async {
    final memberId = widget.member['memberId'] as String? ?? '';
    if (memberId.isEmpty) return;
    try {
      final uri = Uri.parse(
          'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod'
          '/member/policy?memberId=${Uri.encodeComponent(memberId)}');
      final response = await http.get(uri);
      if (!mounted) return;
      final data     = json.decode(response.body) as Map<String, dynamic>;
      final policies = (data['policies'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      setState(() => _hasPolicy = policies.isNotEmpty);
    } catch (_) {}
  }

  void _goTab(int t) => setState(() => _tab = t);

  @override
  Widget build(BuildContext context) {
    final langProvider = context.watch<LanguageProvider>();
    final locale = langProvider.locale;
    String s(String key) => AppStrings.get(key, locale);

    final member = widget.member;
    final name = member['full_name'] as String? ?? '';
    final isActive =
        member['status'] == true || member['status'] == 'true';

    final tabs = [
      _DashboardTab(member: member, locale: locale, onGoTransactions: () => _goTab(1)),
      _TransactionsTab(member: member, locale: locale),
      PolicyScreen(member: member, embedded: true),
      ChatbotWidget(member: member, locale: locale),
    ];

    const navItems = [
      BottomNavigationBarItem(
          icon: Icon(Icons.dashboard_outlined),
          activeIcon: Icon(Icons.dashboard),
          label: 'Dashboard'),
      BottomNavigationBarItem(
          icon: Icon(Icons.receipt_long_outlined),
          activeIcon: Icon(Icons.receipt_long),
          label: 'Payments'),
      BottomNavigationBarItem(
          icon: Icon(Icons.policy_outlined),
          activeIcon: Icon(Icons.policy),
          label: 'Policies'),
      BottomNavigationBarItem(
          icon: Icon(Icons.chat_bubble_outline),
          activeIcon: Icon(Icons.chat_bubble),
          label: 'Assistant'),
    ];

    return Scaffold(
      backgroundColor: _bg,
      appBar: _KafaAppBar(
        name: name,
        isActive: isActive,
        locale: locale,
        s: s,
        hasPolicy: _hasPolicy,
        onLogout: () async {
          await SessionService.clearSession();
          if (!context.mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const MemberLoginScreen()),
            (_) => false,
          );
        },
        onLangToggle: () => context.read<LanguageProvider>().toggle(),
      ),
      body: IndexedStack(index: _tab, children: tabs),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        onTap: _goTab,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: _green,
        unselectedItemColor: Colors.grey.shade500,
        backgroundColor: Colors.white,
        elevation: 12,
        selectedFontSize: 11,
        unselectedFontSize: 11,
        items: navItems,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  AppBar
// ─────────────────────────────────────────────────────────────────────────────

class _KafaAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String name, locale;
  final bool isActive;
  final bool hasPolicy;
  final String Function(String) s;
  final VoidCallback onLogout, onLangToggle;

  const _KafaAppBar({
    required this.name,
    required this.isActive,
    required this.locale,
    required this.s,
    required this.hasPolicy,
    required this.onLogout,
    required this.onLangToggle,
  });

  @override
  Size get preferredSize => Size.fromHeight(
      hasPolicy ? kToolbarHeight : kToolbarHeight + 40);

  @override
  Widget build(BuildContext context) {
    final initials  = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final langLabel = locale == 'fr' ? '🇺🇸 EN' : '🇫🇷 FR';

    return AppBar(
      backgroundColor: _green,
      elevation: 0,
      automaticallyImplyLeading: false,
      titleSpacing: 16,
      title: Row(mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.asset(
            'assets/images/kafa_logo.png',
            width: 34, height: 34, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                  color: _gold, borderRadius: BorderRadius.circular(6)),
              child: const Icon(Icons.shield, color: Colors.white, size: 20),
            ),
          ),
        ),
        const SizedBox(width: 10),
        const Text('KAFA',
            style: TextStyle(
                color: _gold,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 3)),
      ]),
      // ── No-policy warning banner ──────────────────────────────────────────
      bottom: hasPolicy ? null : PreferredSize(
        preferredSize: const Size.fromHeight(40),
        child: Container(
          width: double.infinity,
          color: const Color(0xFFFFF3CD),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            const Icon(Icons.info_outline, size: 16, color: Color(0xFF856404)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Please contact KAFA for authorization',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF856404)),
              ),
            ),
            TextButton(
              onPressed: () =>
                  html.window.open('https://admin.kafayiti.com', '_blank'),
              style: TextButton.styleFrom(
                backgroundColor: const Color(0xFF856404),
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6)),
              ),
              child: const Text('Contact Admin',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ]),
        ),
      ),
      actions: [
        PopupMenuButton<String>(
          offset: const Offset(0, 48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          onSelected: (v) {
            if (v == 'logout') onLogout();
            if (v == 'lang') onLangToggle();
          },
          itemBuilder: (_) => [
            PopupMenuItem<String>(
              enabled: false,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isActive
                      ? Colors.green.shade100
                      : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.circle,
                      size: 8,
                      color: isActive
                          ? Colors.green.shade700
                          : Colors.grey.shade500),
                  const SizedBox(width: 6),
                  Text(
                    isActive
                        ? s('activeMember')
                        : s('inactiveMember'),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isActive
                            ? Colors.green.shade700
                            : Colors.grey.shade600),
                  ),
                ]),
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'lang',
              child: Row(children: [
                const Icon(Icons.language, size: 18, color: _green),
                const SizedBox(width: 12),
                Text(langLabel),
              ]),
            ),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'logout',
              child: Row(children: [
                Icon(Icons.logout, size: 18, color: Colors.red.shade400),
                const SizedBox(width: 12),
                Text(s('logout'),
                    style: TextStyle(color: Colors.red.shade400)),
              ]),
            ),
          ],
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
              const SizedBox(width: 8),
              CircleAvatar(
                radius: 18,
                backgroundColor: _gold,
                child: Text(initials,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
              ),
            ]),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Dashboard Tab — BofA-style card grid
// ─────────────────────────────────────────────────────────────────────────────

class _DashboardTab extends StatefulWidget {
  final Map<String, dynamic> member;
  final String locale;
  final VoidCallback onGoTransactions;

  const _DashboardTab(
      {required this.member,
      required this.locale,
      required this.onGoTransactions});

  @override
  State<_DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<_DashboardTab> {
  List<Map<String, dynamic>> _policies = [];
  bool _loadingPolicies = true;

  static const String _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  @override
  void initState() {
    super.initState();
    _fetchPolicies();
  }

  Future<void> _fetchPolicies() async {
    final memberId = widget.member['memberId'] as String? ?? '';
    try {
      final uri = Uri.parse(
          '$_baseUrl/member/policy?memberId=${Uri.encodeComponent(memberId)}');
      final response =
          await http.get(uri, headers: {'Content-Type': 'application/json'});
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _policies =
                List<Map<String, dynamic>>.from(data['policies'] ?? []);
            _loadingPolicies = false;
          });
        }
      } else {
        if (mounted) setState(() => _loadingPolicies = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingPolicies = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final member = widget.member;
    final name = member['full_name'] as String? ?? '';
    final memberId = member['memberId'] as String? ?? '';
    final isActive =
        member['status'] == true || member['status'] == 'true';
    final issuedDate = member['issued_date'] as String? ??
        member['issuedDate'] as String? ?? '';

    final activePolicies = _policies.where((p) {
      final pol = p['policy'] as Map<String, dynamic>? ?? {};
      return (pol['policyStatus'] as String? ?? '').toUpperCase() == 'ACTIVE';
    }).length;
    final totalPolicies = _policies.length;

    // Derive next premium from first active policy if available
    final firstEntry = _policies.isNotEmpty ? _policies.first : null;
    final firstPolicy = firstEntry?['policy'] as Map<String, dynamic>?;
    final premiumAmount = firstPolicy?['premiumAmount']?.toString() ?? '—';
    final nextPayDate   = firstPolicy?['nextDueDate']  as String? ?? '—';

    final firstName = name.split(' ').first;

    return RefreshIndicator(
      onRefresh: _fetchPolicies,
      color: _green,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ── Payment notification banner ───────────────────────────────────
          _PaymentNotificationBanner(member: widget.member),

          // ── Greeting ──────────────────────────────────────────────────────
          Text('Hello, $firstName 👋',
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A1A))),
          const SizedBox(height: 2),
          Text(
            isActive ? 'Your membership is active' : 'Your membership is inactive',
            style: TextStyle(
                fontSize: 13,
                color: isActive ? Colors.green.shade700 : Colors.grey.shade600),
          ),
          const SizedBox(height: 20),

          // ── 2 × 2 card grid ───────────────────────────────────────────────
          Row(children: [
            Expanded(
              child: _DashCard(
                icon: Icons.badge_outlined,
                iconColor: _green,
                accentColor: const Color(0xFFE8F5E9),
                label: 'Member ID',
                value: memberId.isNotEmpty
                    ? memberId.length > 12
                        ? '…${memberId.substring(memberId.length - 8)}'
                        : memberId
                    : '—',
                sub: isActive ? 'Active' : 'Inactive',
                subColor: isActive ? Colors.green.shade700 : Colors.grey,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _DashCard(
                icon: Icons.policy_outlined,
                iconColor: const Color(0xFF1565C0),
                accentColor: const Color(0xFFE3F2FD),
                label: 'Policies',
                value: _loadingPolicies ? '…' : '$activePolicies active',
                sub: _loadingPolicies
                    ? ''
                    : '$totalPolicies total',
                subColor: Colors.grey.shade600,
              ),
            ),
          ]),
          const SizedBox(height: 12),

          Row(children: [
            Expanded(
              child: _DashCard(
                icon: Icons.payments_outlined,
                iconColor: const Color(0xFF7B1FA2),
                accentColor: const Color(0xFFF3E5F5),
                label: 'Premium',
                value: premiumAmount != '—' ? 'HTG $premiumAmount' : '—',
                sub: 'Monthly due',
                subColor: Colors.grey.shade600,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _DashCard(
                icon: Icons.calendar_month_outlined,
                iconColor: const Color(0xFFE65100),
                accentColor: const Color(0xFFFFF3E0),
                label: 'Next Payment',
                value: nextPayDate != '—'
                    ? _formatShortDate(nextPayDate)
                    : '—',
                sub: 'Due date',
                subColor: Colors.grey.shade600,
              ),
            ),
          ]),
          const SizedBox(height: 24),

          // ── Quick actions ─────────────────────────────────────────────────
          const Text('Quick Actions',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A1A))),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 8,
                    offset: const Offset(0, 2))
              ],
            ),
            child: Column(children: [
              _QuickAction(
                icon: Icons.credit_card,
                label: 'Pay Premium',
                subtitle: 'Make a payment toward your policy',
                color: _green,
                isFirst: true,
                isLast: false,
                onTap: widget.onGoTransactions,
              ),
              _QuickAction(
                icon: Icons.description,
                label: 'My Certificate',
                subtitle: 'Download your membership certificate',
                color: const Color(0xFF1565C0),
                isFirst: false,
                isLast: false,
                onTap: () => _showCertificateSheet(context, member),
              ),
              _QuickAction(
                icon: Icons.receipt_long,
                label: 'Payment History',
                subtitle: 'View past and upcoming payments',
                color: const Color(0xFF7B1FA2),
                isFirst: false,
                isLast: false,
                onTap: widget.onGoTransactions,
              ),
              _QuickAction(
                icon: Icons.headset_mic,
                label: 'Contact Support',
                subtitle: 'Get help from the KAFA team',
                color: const Color(0xFFE65100),
                isFirst: false,
                isLast: true,
                onTap: () => _showSupportSheet(context),
              ),
            ]),
          ),
          const SizedBox(height: 24),

          // ── Member info card ──────────────────────────────────────────────
          _SectionCard(
            title: 'Member Overview',
            icon: Icons.person_outline,
            child: Column(children: [
              _OverviewRow(
                  icon: Icons.person, label: 'Full Name', value: name),
              _OverviewRow(
                  icon: Icons.location_on_outlined,
                  label: 'Commune',
                  value: (member['locality'] as Map<String, dynamic>?)?['commune'] as String? ?? '—'),
              _OverviewRow(
                  icon: Icons.phone_outlined,
                  label: 'Phone',
                  value: member['phone'] as String? ?? '—'),
              _OverviewRow(
                  icon: Icons.email_outlined,
                  label: 'Email',
                  value: member['email'] as String? ?? '—'),
              if (issuedDate.isNotEmpty)
                _OverviewRow(
                    icon: Icons.verified_outlined,
                    label: 'Member Since',
                    value: _formatShortDate(issuedDate)),
            ]),
          ),
          const SizedBox(height: 16),

          // ── Alerts card ───────────────────────────────────────────────────
          _AlertsCard(isActive: isActive, nextPayDate: nextPayDate),
        ]),
      ),
    );
  }

  String _formatShortDate(String raw) {
    try {
      final parts = raw.split('-');
      if (parts.length == 3) {
        const months = [
          '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
        ];
        final m = int.tryParse(parts[1]) ?? 0;
        return '${months[m]} ${parts[2]}, ${parts[0]}';
      }
    } catch (_) {}
    return raw;
  }

  void _showCertificateSheet(
      BuildContext context, Map<String, dynamic> member) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.description, color: _green, size: 48),
          const SizedBox(height: 12),
          const Text('Member Certificate',
              style:
                  TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Download your official KAFA membership certificate.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('Download PDF'),
            style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Certificate download coming soon'),
                    backgroundColor: _green),
              );
            },
          ),
        ]),
      ),
    );
  }

  void _showSupportSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: const [
          Icon(Icons.support_agent, color: _green, size: 48),
          SizedBox(height: 12),
          Text('Contact Support',
              style:
                  TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          SizedBox(height: 16),
          _SupportTile(
              icon: Icons.phone,
              label: 'Call Us',
              value: '+509 XXXX-XXXX'),
          Divider(),
          _SupportTile(
              icon: Icons.email,
              label: 'Email',
              value: 'support@kafa.org'),
          Divider(),
          _SupportTile(
              icon: Icons.access_time,
              label: 'Hours',
              value: 'Mon–Fri 8am–5pm'),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Transactions Tab
// ─────────────────────────────────────────────────────────────────────────────

class _TransactionsTab extends StatefulWidget {
  final Map<String, dynamic> member;
  final String locale;

  const _TransactionsTab({required this.member, required this.locale});

  @override
  State<_TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<_TransactionsTab> {
  static const String _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  bool _loading = true;
  List<Map<String, dynamic>> _policies = [];
  bool _payLoading = false;

  @override
  void initState() {
    super.initState();
    _fetchPolicies();
  }

  Future<void> _fetchPolicies() async {
    setState(() => _loading = true);
    final memberId = widget.member['memberId'] as String? ?? '';
    try {
      final uri = Uri.parse(
          '$_baseUrl/member/policy?memberId=${Uri.encodeComponent(memberId)}');
      final response =
          await http.get(uri, headers: {'Content-Type': 'application/json'});
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (mounted) {
          setState(() {
            _policies =
                List<Map<String, dynamic>>.from(data['policies'] ?? []);
            _loading = false;
          });
        }
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final firstEntry    = _policies.isNotEmpty ? _policies.first : null;
    final firstPolicy   = firstEntry?['policy']  as Map<String, dynamic>?;
    final firstLastPay  = firstEntry?['lastPay']  as Map<String, dynamic>?;
    final premiumAmount = firstPolicy?['premiumAmount']?.toString() ?? '—';
    final lastPayDate   = firstLastPay?['paymentDate']  as String? ??
                          firstPolicy?['lastPaidDate']   as String? ?? '—';
    final nextPayDate   = firstPolicy?['nextDueDate']    as String? ?? '—';
    final policyNo      = firstPolicy?['policyNo']       as String? ?? '—';

    // Check if member has payment access
    final paymentAccess = widget.member['payment_access'] == true;

    return RefreshIndicator(
      onRefresh: _fetchPolicies,
      color: _green,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Payments',
              style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A1A))),
          const SizedBox(height: 4),
          Text('Manage your premium payments',
              style:
                  TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          const SizedBox(height: 20),

          // ── Payment summary cards ─────────────────────────────────────
          if (_loading)
            const Center(
                child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(color: _green),
            ))
          else ...[
            Row(children: [
              Expanded(
                child: _PayInfoCard(
                  label: 'Last Payment',
                  icon: Icons.check_circle_outline,
                  iconColor: Colors.green.shade600,
                  value: lastPayDate != '—'
                      ? _fmtDate(lastPayDate)
                      : 'No record',
                  sub: premiumAmount != '—' ? 'HTG $premiumAmount' : '',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PayInfoCard(
                  label: 'Next Payment',
                  icon: Icons.schedule,
                  iconColor: const Color(0xFFE65100),
                  value: nextPayDate != '—'
                      ? _fmtDate(nextPayDate)
                      : 'Contact us',
                  sub: premiumAmount != '—' ? 'HTG $premiumAmount' : '',
                ),
              ),
            ]),
            const SizedBox(height: 20),

            // ── Pay Premium button ────────────────────────────────────
            _SectionCard(
              title: 'Pay Premium',
              icon: Icons.credit_card,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (policyNo != '—') ...[
                      Text('Policy: $policyNo',
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey.shade600)),
                      const SizedBox(height: 4),
                    ],
                    if (premiumAmount != '—') ...[
                      RichText(
                        text: TextSpan(children: [
                          TextSpan(
                              text: 'Amount due: ',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey.shade600)),
                          TextSpan(
                              text: 'HTG $premiumAmount',
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: _green)),
                        ]),
                      ),
                      const SizedBox(height: 16),
                    ],
                    ElevatedButton.icon(
                      icon: _payLoading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2))
                          : const Icon(Icons.payment),
                      label: Text(
                          _payLoading ? 'Processing…' : 'Pay Now'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: paymentAccess ? _green : Colors.grey.shade400,
                          foregroundColor: Colors.white,
                          minimumSize:
                              const Size(double.infinity, 52),
                          shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(12))),
                      onPressed: (!paymentAccess || _payLoading)
                          ? null
                          : () => _handlePayNow(context),
                    ),
                    if (!paymentAccess) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        Icon(Icons.lock_outline,
                            size: 14, color: Colors.grey.shade500),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Payment access is not enabled for your account. Please contact your KAFA administrator.',
                            style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500),
                          ),
                        ),
                      ]),
                    ],
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        'Secure payment processed by KAFA',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade500),
                      ),
                    ),
                  ]),
            ),
            const SizedBox(height: 20),

            // ── Payment history ───────────────────────────────────────
            _SectionCard(
              title: 'Payment History',
              icon: Icons.history,
              child: _policies.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text('No payment records available.',
                          style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 13)),
                    )
                  : Column(
                      children: _policies
                          .map((p) => _PaymentHistoryTile(policy: p))
                          .toList()),
            ),
          ],
        ]),
      ),
    );
  }

  Future<void> _handlePayNow(BuildContext context) async {
    setState(() => _payLoading = true);
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    setState(() => _payLoading = false);
    // ignore: use_build_context_synchronously
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
                color: Colors.green.shade50, shape: BoxShape.circle),
            child:
                Icon(Icons.check_circle, color: Colors.green.shade600, size: 36),
          ),
          const SizedBox(height: 16),
          const Text('Payment Portal',
              style:
                  TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Online payment is coming soon. Please visit a KAFA office or contact support to make your payment.',
            textAlign: TextAlign.center,
            style:
                TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: const Text('OK'),
          ),
        ]),
      ),
    );
  }

  String _fmtDate(String raw) {
    try {
      final parts = raw.split('-');
      if (parts.length == 3) {
        const months = [
          '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
          'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
        ];
        final m = int.tryParse(parts[1]) ?? 0;
        return '${months[m]} ${parts[2]}, ${parts[0]}';
      }
    } catch (_) {}
    return raw;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Reusable small widgets
// ─────────────────────────────────────────────────────────────────────────────

class _DashCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor, accentColor;
  final String label, value, sub;
  final Color subColor;

  const _DashCard({
    required this.icon,
    required this.iconColor,
    required this.accentColor,
    required this.label,
    required this.value,
    required this.sub,
    required this.subColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 8,
                offset: const Offset(0, 2))
          ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration:
              BoxDecoration(color: accentColor, shape: BoxShape.circle),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        const SizedBox(height: 12),
        Text(label,
            style:
                TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        const SizedBox(height: 2),
        Text(value,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
        const SizedBox(height: 2),
        Text(sub, style: TextStyle(fontSize: 11, color: subColor)),
      ]),
    );
  }
}

class _QuickAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final Color color;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;

  const _QuickAction({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.isFirst,
    required this.isLast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.vertical(
            top: isFirst ? const Radius.circular(16) : Radius.zero,
            bottom: isLast ? const Radius.circular(16) : Radius.zero,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A1A1A))),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500)),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_ios,
                  size: 14, color: Colors.grey.shade400),
            ]),
          ),
        ),
        if (!isLast)
          Divider(height: 1, indent: 72, endIndent: 16,
              color: Colors.grey.shade100),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;

  const _SectionCard(
      {required this.title, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 8,
                offset: const Offset(0, 2))
          ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: _green, size: 18),
          const SizedBox(width: 8),
          Text(title,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: _green)),
        ]),
        const Divider(height: 20),
        child,
      ]),
    );
  }
}

class _OverviewRow extends StatelessWidget {
  final IconData icon;
  final String label, value;

  const _OverviewRow(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(icon, size: 16, color: Colors.grey.shade400),
        const SizedBox(width: 10),
        SizedBox(
          width: 100,
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey.shade600,
                  fontWeight: FontWeight.w500)),
        ),
        Expanded(
          child: Text(value,
              style:
                  const TextStyle(fontSize: 13, color: Color(0xFF1A1A1A))),
        ),
      ]),
    );
  }
}

class _AlertsCard extends StatelessWidget {
  final bool isActive;
  final String nextPayDate;

  const _AlertsCard({required this.isActive, required this.nextPayDate});

  @override
  Widget build(BuildContext context) {
    final alerts = <Map<String, dynamic>>[];

    if (!isActive) {
      alerts.add({
        'icon': Icons.warning_amber_rounded,
        'color': Colors.orange,
        'text': 'Your membership is currently inactive. Contact KAFA to reactivate.',
      });
    }

    if (nextPayDate != '—') {
      alerts.add({
        'icon': Icons.notifications_active_outlined,
        'color': _green,
        'text': 'Next premium payment due: $nextPayDate',
      });
    }

    alerts.add({
      'icon': Icons.info_outline,
      'color': const Color(0xFF1565C0),
      'text': 'Keep your contact information up to date for faster service.',
    });

    return _SectionCard(
      title: 'Alerts & Reminders',
      icon: Icons.notifications_outlined,
      child: Column(
        children: alerts
            .map((a) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(a['icon'] as IconData,
                            color: a['color'] as Color, size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(a['text'] as String,
                              style: const TextStyle(
                                  fontSize: 13, color: Color(0xFF333333))),
                        ),
                      ]),
                ))
            .toList(),
      ),
    );
  }
}

class _PayInfoCard extends StatelessWidget {
  final String label, value, sub;
  final IconData icon;
  final Color iconColor;

  const _PayInfoCard({
    required this.label,
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 8,
                offset: const Offset(0, 2))
          ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: iconColor, size: 18),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
        ]),
        const SizedBox(height: 8),
        Text(value,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A1A))),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(sub,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ],
      ]),
    );
  }
}

class _PaymentHistoryTile extends StatelessWidget {
  final Map<String, dynamic> policy;

  const _PaymentHistoryTile({required this.policy});

  @override
  Widget build(BuildContext context) {
    final pol       = policy['policy'] as Map<String, dynamic>? ?? {};
    final policyNo  = pol['policyNo']      as String? ?? '—';
    final premium   = pol['premiumAmount']?.toString() ?? '—';
    final startDate = pol['startDate']     as String? ?? '—';
    final status    = (pol['policyStatus'] as String? ?? '').toUpperCase();
    final isActive  = status == 'ACTIVE';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color:
                  isActive ? Colors.green.shade50 : Colors.grey.shade100,
              shape: BoxShape.circle),
          child: Icon(
            isActive ? Icons.check_circle : Icons.cancel_outlined,
            color: isActive ? Colors.green.shade600 : Colors.grey.shade400,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Policy $policyNo',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A1A))),
            Text('Since $startDate',
                style:
                    TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (premium != '—')
            Text('HTG $premium',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _green)),
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: isActive
                  ? Colors.green.shade100
                  : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              status.isNotEmpty ? status : '—',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: isActive
                      ? Colors.green.shade700
                      : Colors.grey.shade600),
            ),
          ),
        ]),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Payment Notification Banner
// ─────────────────────────────────────────────────────────────────────────────

class _PaymentNotificationBanner extends StatefulWidget {
  final Map<String, dynamic> member;
  const _PaymentNotificationBanner({required this.member});

  @override
  State<_PaymentNotificationBanner> createState() =>
      _PaymentNotificationBannerState();
}

class _PaymentNotificationBannerState
    extends State<_PaymentNotificationBanner> {
  static const _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  bool _dismissed = false;

  Future<void> _acknowledge() async {
    setState(() => _dismissed = true);
    try {
      final memberId = widget.member['memberId'] as String? ?? '';
      await http.post(
        Uri.parse('$_baseUrl/member/acknowledge-payment'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'memberId': memberId, 'companyId': 'KAFA-001'}),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final notif =
        widget.member['payment_notification'] as Map<String, dynamic>?;
    if (notif == null) return const SizedBox.shrink();
    final seen = notif['seen'] == true || notif['seen'] == 'true';
    if (seen || _dismissed) return const SizedBox.shrink();

    final amount    = notif['amountPaid']?.toString()  ?? '—';
    final date      = notif['paymentDate'] as String?  ?? '—';
    final ref       = notif['referenceNo'] as String?  ?? '—';
    final policyNo  = notif['policyNo']    as String?  ?? '—';
    final method    = notif['paymentMethod'] as String? ?? '—';

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.shade50,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.green.shade300),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.check_circle,
              color: Colors.green.shade600, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Payment Received',
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.green.shade800),
            ),
          ),
          GestureDetector(
            onTap: _acknowledge,
            child: Icon(Icons.close,
                size: 18, color: Colors.green.shade600),
          ),
        ]),
        const SizedBox(height: 8),
        Text(
          'Your payment of HTG $amount has been collected by a KAFA administrator.',
          style: TextStyle(fontSize: 13, color: Colors.green.shade800),
        ),
        const SizedBox(height: 8),
        _NotifRow('Date',      date),
        _NotifRow('Policy',    policyNo),
        _NotifRow('Method',    method),
        _NotifRow('Reference', ref),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: _acknowledge,
            style: TextButton.styleFrom(
              backgroundColor: Colors.green.shade100,
              foregroundColor: Colors.green.shade800,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Got it — Dismiss'),
          ),
        ),
      ]),
    );
  }
}

class _NotifRow extends StatelessWidget {
  final String label, value;
  const _NotifRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(
          width: 80,
          child: Text(label,
              style: TextStyle(
                  fontSize: 12, color: Colors.green.shade600)),
        ),
        Text(value,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.green.shade900)),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _SupportTile extends StatelessWidget {
  final IconData icon;
  final String label, value;

  const _SupportTile(
      {required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Icon(icon, color: _green, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12, color: Colors.grey.shade500)),
            Text(value,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }
}