import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../services/session_service.dart';
import 'member_login_screen.dart';
import 'policy_screen.dart';
import 'plans_screen.dart';
import 'funeral_services_screen.dart';
import 'documents_screen.dart';
import 'death_report_screen.dart';
import 'enrollment_form_screen.dart';
import 'quick_quote_screen.dart';

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
  int _tab = 0;
  bool _hasPolicy = true;

  final _chatPanelKey = GlobalKey<_DashboardChatPanelState>();

  // Live member data — refreshed from server on init so notifications are current
  late Map<String, dynamic> _member;

  static const _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  @override
  void initState() {
    super.initState();
    _member = widget.member; // start with cached session immediately
    _checkPolicy();
    _refreshMember(); // silently fetch fresh profile in background
  }

  /// Re-fetches the member profile from the server so payment_notification
  /// and payment_access are always current, even when loaded from session cache.
  Future<void> _refreshMember() async {
    final memberId = widget.member['memberId'] as String? ?? '';
    final companyId = widget.member['companyId'] as String? ?? 'KAFA-001';
    if (memberId.isEmpty) return;
    try {
      final uri = Uri.parse(
          '$_baseUrl/member/profile?memberId=${Uri.encodeComponent(memberId)}'
          '&companyId=${Uri.encodeComponent(companyId)}');
      final response = await http.get(uri);
      if (!mounted || response.statusCode != 200) return;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final fresh = data['member'] as Map<String, dynamic>?;
      if (fresh == null) return;
      await SessionService.saveSession(fresh);
      if (mounted) setState(() => _member = fresh);
    } catch (_) {}
  }

  Future<void> _checkPolicy() async {
    final memberId = _member['memberId'] as String? ?? '';
    if (memberId.isEmpty) return;
    try {
      final uri = Uri.parse(
          'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod'
          '/member/policy?memberId=${Uri.encodeComponent(memberId)}');
      final response = await http.get(uri);
      if (!mounted) return;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final policies =
          (data['policies'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      setState(() => _hasPolicy = policies.isNotEmpty);
    } catch (_) {}
  }

  void _goTab(int t) => setState(() => _tab = t);

  @override
  Widget build(BuildContext context) {
    final langProvider = context.watch<LanguageProvider>();
    final locale = langProvider.locale;
    String s(String key) => AppStrings.get(key, locale);

    final member = _member;
    final name = member['full_name'] as String? ?? '';
    final isActive = member['status'] == true || member['status'] == 'true';

    Future<void> handleLogout() async {
      await SessionService.clearSession();
      if (!context.mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const MemberLoginScreen()),
        (_) => false,
      );
    }

    final tabs = [
      _DashboardTab(
        member: _member,
        onGoPolicies: () => _goTab(1),
        onOpenChat: () => _chatPanelKey.currentState?.expand(),
      ),
      PolicyScreen(member: _member, embedded: true),
      _ServicesTab(member: _member, locale: locale),
      _ProfileTab(member: _member, locale: locale, onLogout: handleLogout),
    ];

    final navItems = [
      BottomNavigationBarItem(
          icon: const Icon(Icons.home_outlined),
          activeIcon: const Icon(Icons.home),
          label: s('navDashboard')),
      BottomNavigationBarItem(
          icon: const Icon(Icons.policy_outlined),
          activeIcon: const Icon(Icons.policy),
          label: s('navPolicies')),
      BottomNavigationBarItem(
          icon: const Icon(Icons.room_service_outlined),
          activeIcon: const Icon(Icons.room_service),
          label: s('navServices')),
      BottomNavigationBarItem(
          icon: const Icon(Icons.person_outline),
          activeIcon: const Icon(Icons.person),
          label: s('navProfile')),
    ];

    return Scaffold(
      backgroundColor: _bg,
      appBar: _KafaAppBar(
        name: name,
        locale: locale,
        isActive: isActive,
        hasPolicy: _hasPolicy,
        onLogout: () async {
          await SessionService.clearSession();
          if (!context.mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const MemberLoginScreen()),
            (_) => false,
          );
        },
        onLocaleChange: (code) =>
            context.read<LanguageProvider>().setLocale(code),
        member: _member,
      ),
      body: IndexedStack(index: _tab, children: tabs),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Offstage(
            offstage: _tab != 0,
            child: _DashboardChatPanel(key: _chatPanelKey, member: _member, locale: locale),
          ),
          BottomNavigationBar(
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
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  AppBar
// ─────────────────────────────────────────────────────────────────────────────

class _KafaAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String name;
  final String locale;
  final bool isActive;
  final bool hasPolicy;
  final VoidCallback onLogout;
  final void Function(String) onLocaleChange;
  final Map<String, dynamic> member;

  const _KafaAppBar({
    required this.name,
    required this.locale,
    required this.isActive,
    required this.hasPolicy,
    required this.onLogout,
    required this.onLocaleChange,
    required this.member,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  void _showViewOptionsSheet(BuildContext context) {
    String s(String key) => AppStrings.get(key, locale);
    final memberId   = member['memberId']  as String? ?? '';
    final memberName = member['full_name'] as String? ?? '';
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(s('viewOptions'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          _OptionsButton(
            icon: Icons.request_quote_outlined,
            label: s('viewQuote'),
            color: _green,
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => QuickQuoteScreen(
                  memberId:   memberId,
                  memberName: memberName,
                  phone:      member['phone']  as String?,
                  email:      member['email']  as String?,
                ),
              ));
            },
          ),
          const SizedBox(height: 12),
          _OptionsButton(
            icon: Icons.shield_outlined,
            label: s('viewPlansAndCoverage'),
            color: const Color(0xFF1565C0),
            onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(
                builder: (_) => PlansScreen(memberId: memberId),
              ));
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watch directly so AppBar always reflects the current locale
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    final initials = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final currentLang = LanguageProvider.supportedLanguages.firstWhere(
        (l) => l['code'] == locale,
        orElse: () => LanguageProvider.supportedLanguages.first);

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
            width: 34,
            height: 34,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              width: 34,
              height: 34,
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
      bottom: null,
      actions: [
        // ── Alerts bell ───────────────────────────────────────────────────
        _AlertsBellButton(member: member, locale: locale),

        // ── Profile menu (includes language) ─────────────────────────────
        PopupMenuButton<String>(
          offset: const Offset(0, 48),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          onSelected: (v) {
            if (v == 'logout') {
              onLogout();
            } else {
              onLocaleChange(v);
            }
          },
          itemBuilder: (_) => [
            // Status badge
            PopupMenuItem<String>(
              enabled: false,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color:
                      isActive ? Colors.green.shade100 : Colors.grey.shade200,
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
                    isActive ? s('activeMember') : s('inactiveMember'),
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
            // Language submenu header (non-interactive label)
            PopupMenuItem<String>(
              enabled: false,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(children: [
                const Icon(Icons.language, size: 16, color: Colors.grey),
                const SizedBox(width: 8),
                Text(s('navAssistant').isNotEmpty ? currentLang['label']! : '',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ]),
            ),
            // One item per language
            ...LanguageProvider.supportedLanguages
                .map((lang) => PopupMenuItem<String>(
                      value: lang['code'],
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 4),
                      child: Row(children: [
                        Text(lang['label']!,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: lang['code'] == locale
                                    ? FontWeight.bold
                                    : FontWeight.normal)),
                        if (lang['code'] == locale) ...[
                          const Spacer(),
                          const Icon(Icons.check, size: 15, color: _green),
                        ],
                      ]),
                    )),
            const PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'logout',
              child: Row(children: [
                Icon(Icons.logout, size: 18, color: Colors.red.shade400),
                const SizedBox(width: 12),
                Text(s('logout'), style: TextStyle(color: Colors.red.shade400)),
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
//  Bell button — shows alerts badge + bottom sheet
// ─────────────────────────────────────────────────────────────────────────────

class _AlertsBellButton extends StatelessWidget {
  final Map<String, dynamic> member;
  final String locale;

  const _AlertsBellButton({required this.member, required this.locale});

  List<Map<String, dynamic>> _buildAlerts(String Function(String) s) {
    final isActive = member['status'] == true || member['status'] == 'true';
    final alerts = <Map<String, dynamic>>[];

    if (!isActive) {
      alerts.add({
        'icon': Icons.warning_amber_rounded,
        'color': Colors.orange,
        'text': s('alertInactive'),
      });
    }
    alerts.add({
      'icon': Icons.info_outline,
      'color': const Color(0xFF1565C0),
      'text': s('alertContactInfo'),
    });
    return alerts;
  }

  void _show(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);
    final alerts = _buildAlerts(s);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const Icon(Icons.notifications_outlined, color: _green, size: 22),
            const SizedBox(width: 10),
            Text(s('alertsReminders'),
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 16),
          ...alerts.map((a) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(a['icon'] as IconData,
                          color: a['color'] as Color, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(a['text'] as String,
                            style: const TextStyle(
                                fontSize: 14, color: Color(0xFF333333))),
                      ),
                    ]),
              )),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);
    final count = _buildAlerts(s).length;
    final hasWarn = member['status'] != true && member['status'] != 'true';

    return IconButton(
      onPressed: () => _show(context),
      icon: Stack(clipBehavior: Clip.none, children: [
        const Icon(Icons.notifications_outlined, color: Colors.white, size: 24),
        Positioned(
          top: -4,
          right: -4,
          child: Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: hasWarn ? Colors.orange : Colors.green.shade600,
              shape: BoxShape.circle,
              border: Border.all(color: _green, width: 1.5),
            ),
            child: Center(
              child: Text('$count',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.bold)),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Dashboard Tab — BofA-style card grid
// ─────────────────────────────────────────────────────────────────────────────

class _DashboardTab extends StatefulWidget {
  final Map<String, dynamic> member;
  final VoidCallback onGoPolicies;
  final VoidCallback onOpenChat;

  const _DashboardTab({
    required this.member,
    required this.onGoPolicies,
    required this.onOpenChat,
  });

  @override
  State<_DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<_DashboardTab>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _policies = [];
  bool _loadingPolicies = true;
  bool _quickActExpanded = true;
  bool _optionsOpen = false;

  late final AnimationController _qaCtrl;
  late final Animation<double> _qaAnim;

  static const String _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  @override
  void initState() {
    super.initState();
    _qaCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: 1.0, // starts expanded
    );
    _qaAnim = CurvedAnimation(parent: _qaCtrl, curve: Curves.easeInOut);
    _fetchPolicies();
  }

  @override
  void dispose() {
    _qaCtrl.dispose();
    super.dispose();
  }

  void _openChat() => widget.onOpenChat();

  void _toggleQuickActions() {
    setState(() => _quickActExpanded = !_quickActExpanded);
    if (_quickActExpanded) {
      _qaCtrl.forward();
    } else {
      _qaCtrl.reverse();
    }
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
            _policies = List<Map<String, dynamic>>.from(data['policies'] ?? []);
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
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);

    final member = widget.member;
    final name = member['full_name'] as String? ?? '';
    final memberId = member['memberId'] as String? ?? '';
    final isActive = member['status'] == true || member['status'] == 'true';
    final totalPolicies = _policies.length;
    final activePolicies = _policies.where((p) {
      final pol = p['policy'] as Map<String, dynamic>? ?? {};
      return (pol['policyStatus'] as String? ?? '').toUpperCase() == 'ACTIVE';
    }).length;

    // Derive next premium from first active policy if available
    final firstPolicyMap = _policies.isNotEmpty
        ? _policies.first['policy'] as Map<String, dynamic>?
        : null;
    final premiumAmount = firstPolicyMap?['premiumAmount']?.toString() ?? '—';
    final nextPayDate = firstPolicyMap?['nextDueDate'] as String? ?? '—';
    final deathReportPolicyNo = firstPolicyMap?['policyNo'] as String? ?? '';

    final firstName = name.split(' ').first;

    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _fetchPolicies,
            color: _green,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 92),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Greeting ──────────────────────────────────────────────────────
                    Text('${s('helloGreeting')}, $firstName 👋',
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A1A))),
                    const SizedBox(height: 2),
                    Text(
                      isActive
                          ? s('membershipActive')
                          : s('membershipInactive'),
                      style: TextStyle(
                          fontSize: 13,
                          color: isActive
                              ? Colors.green.shade700
                              : Colors.grey.shade600),
                    ),
                    // ── No-policy inline warning + options dropdown ───────────────────
                    if (!_loadingPolicies && _policies.isEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3CD),
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(10),
                            topRight: const Radius.circular(10),
                            bottomLeft: Radius.circular(_optionsOpen ? 0 : 10),
                            bottomRight: Radius.circular(_optionsOpen ? 0 : 10),
                          ),
                        ),
                        child: Row(children: [
                          const Icon(Icons.crisis_alert,
                              size: 18, color: Colors.red),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${s('contactKafaForAuth').split('.').first}.',
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF856404)),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () =>
                                setState(() => _optionsOpen = !_optionsOpen),
                            style: TextButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6)),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Text(s('viewOptions'),
                                  style: const TextStyle(
                                      fontSize: 11, fontWeight: FontWeight.bold)),
                              const SizedBox(width: 4),
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(12),
                                  splashColor: Colors.white38,
                                  highlightColor: Colors.white24,
                                  onTap: () => setState(() => _optionsOpen = !_optionsOpen),
                                  child: Padding(
                                    padding: const EdgeInsets.all(2),
                                    child: AnimatedRotation(
                                      turns: _optionsOpen ? 0.5 : 0.0,
                                      duration: const Duration(milliseconds: 200),
                                      child: const Icon(Icons.keyboard_arrow_down,
                                          size: 14),
                                    ),
                                  ),
                                ),
                              ),
                            ]),
                          ),
                        ]),
                      ),
                      // ── Inline dropdown ─────────────────────────────────────────────
                      if (_optionsOpen)
                        Container(
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: const BorderRadius.only(
                              bottomLeft: Radius.circular(10),
                              bottomRight: Radius.circular(10),
                            ),
                            border: Border.all(
                                color: const Color(0xFFE5C96B), width: 1),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.07),
                                  blurRadius: 8,
                                  offset: const Offset(0, 4)),
                            ],
                          ),
                          child: Column(children: [
                            _OptionsButton(
                              icon: Icons.request_quote_outlined,
                              label: s('createQuote'),
                              color: _green,
                              onTap: () {
                                setState(() => _optionsOpen = false);
                                Navigator.push(context, MaterialPageRoute(
                                  builder: (_) => QuickQuoteScreen(
                                    memberId:   memberId,
                                    memberName: name,
                                    phone: member['phone'] as String?,
                                    email: member['email'] as String?,
                                  ),
                                ));
                              },
                            ),
                            const Divider(height: 1),
                            _OptionsButton(
                              icon: Icons.shield_outlined,
                              label: s('viewPlansAndCoverage'),
                              color: const Color(0xFF1565C0),
                              onTap: () {
                                setState(() => _optionsOpen = false);
                                Navigator.push(context, MaterialPageRoute(
                                  builder: (_) => PlansScreen(memberId: memberId),
                                ));
                              },
                            ),
                            const Divider(height: 1),
                            _OptionsButton(
                              icon: Icons.chat_bubble_outline,
                              label: s('talkToAssistant'),
                              color: _gold,
                              onTap: () {
                                setState(() => _optionsOpen = false);
                                _openChat();
                              },
                            ),
                          ]),
                        ),
                    ],
                    const SizedBox(height: 16),

                    // ── Summary cards row ─────────────────────────────────────────────
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: _MemberSummaryCard(
                              isActive: isActive,
                              activePolicies:
                                  _loadingPolicies ? null : activePolicies,
                              totalPolicies:
                                  _loadingPolicies ? null : totalPolicies,
                              locale: locale,
                              memberId: memberId,
                            ),
                          ),
                          const SizedBox(width: 12),
                          if (_policies.isNotEmpty)
                            Expanded(
                              child: _NextPaymentCard(
                                nextPayDate: nextPayDate,
                                premiumAmount: premiumAmount,
                                locale: locale,
                                onPayNow: () => _showSupportSheet(context, s),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // ── Quick Actions (collapsible, animated) ─────────────────────────
                    GestureDetector(
                      onTap: _toggleQuickActions,
                      child: Row(children: [
                        Text(s('quickActions'),
                            style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A1A1A))),
                        const Spacer(),
                        AnimatedRotation(
                          turns: _quickActExpanded ? 0.0 : 0.5,
                          duration: const Duration(milliseconds: 280),
                          curve: Curves.easeInOut,
                          child: Icon(Icons.keyboard_arrow_up,
                              color: Colors.grey.shade500, size: 22),
                        ),
                      ]),
                    ),
                    SizeTransition(
                      sizeFactor: _qaAnim,
                      axisAlignment: -1,
                      child: Column(children: [
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
                            if (_policies.isNotEmpty)
                              _QuickAction(
                                icon: Icons.credit_card,
                                label: s('payPremium'),
                                subtitle: s('payPremiumSub'),
                                color: _green,
                                isFirst: true,
                                isLast: false,
                                onTap: widget.onGoPolicies,
                              ),
                            _QuickAction(
                              icon: Icons.description,
                              label: s('myCertificate'),
                              subtitle: s('myCertificateSub'),
                              color: const Color(0xFF1565C0),
                              isFirst: _policies.isEmpty,
                              isLast: false,
                              onTap: () =>
                                  _showCertificateSheet(context, member, s),
                            ),
                            if (_policies.isNotEmpty)
                              _QuickAction(
                                icon: Icons.receipt_long,
                                label: s('paymentHistory'),
                                subtitle: s('paymentHistorySub'),
                                color: const Color(0xFF7B1FA2),
                                isFirst: false,
                                isLast: false,
                                onTap: widget.onGoPolicies,
                              ),
                            _QuickAction(
                              icon: Icons.headset_mic,
                              label: s('contactSupport'),
                              subtitle: s('contactSupportSub'),
                              color: const Color(0xFFE65100),
                              isFirst: false,
                              isLast: false,
                              onTap: () => _showSupportSheet(context, s),
                            ),
                            _QuickAction(
                              icon: Icons.crisis_alert,
                              label: s('deathEmergency'),
                              subtitle: s('deathEmergencySub'),
                              color: const Color(0xFFB71C1C),
                              isFirst: false,
                              isLast: true,
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => DeathReportScreen(
                                    memberId: memberId,
                                    memberName: name,
                                    policyNo: deathReportPolicyNo,
                                  ),
                                ),
                              ),
                            ),
                          ]),
                        ),
                      ]),
                    ),
                  ]),
            ),
          ),
        ),
      ],
    );
  }


  void _showCertificateSheet(BuildContext context, Map<String, dynamic> member,
      String Function(String) s) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.description, color: _green, size: 48),
          const SizedBox(height: 12),
          Text(s('memberCertificateTitle'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(s('downloadCertificateDesc'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            icon: const Icon(Icons.download),
            label: Text(s('downloadPdf')),
            style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            onPressed: () {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                    content: Text(s('certificateComingSoon')),
                    backgroundColor: _green),
              );
            },
          ),
        ]),
      ),
    );
  }

  void _showSupportSheet(BuildContext context, String Function(String) s) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.support_agent, color: _green, size: 48),
          const SizedBox(height: 12),
          Text(s('contactSupport'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          _SupportTile(
              icon: Icons.phone, label: s('callUs'), value: '+509 XXXX-XXXX'),
          const Divider(),
          _SupportTile(
              icon: Icons.email, label: s('email'), value: 'kontak@kafa.org'),
          const Divider(),
          _SupportTile(
              icon: Icons.access_time,
              label: s('hours'),
              value: s('hoursValue')),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Dashboard Chat Panel — Claude Code-style persistent input bar
// ─────────────────────────────────────────────────────────────────────────────

class _DashboardChatPanel extends StatefulWidget {
  final Map<String, dynamic> member;
  final String locale;

  const _DashboardChatPanel({super.key, required this.member, required this.locale});

  @override
  State<_DashboardChatPanel> createState() => _DashboardChatPanelState();
}

class _DashboardChatPanelState extends State<_DashboardChatPanel>
    with SingleTickerProviderStateMixin {
  static const _chatUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod/member/chat';

  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<Map<String, String>> _history = [];
  final List<_ChatMsg> _messages = [];

  bool _expanded = false;
  bool _thinking = false;

  late final AnimationController _animCtrl;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _animCtrl.dispose();
    super.dispose();
  }

  String get _locale => widget.locale;

  // Public so _DashboardTabState can trigger via GlobalKey
  void expand() {
    if (!_expanded) {
      setState(() => _expanded = true);
      _animCtrl.forward();
    }
  }

  void _collapse() {
    setState(() => _expanded = false);
    _animCtrl.reverse();
  }

  Future<void> _send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _thinking) return;
    _textCtrl.clear();
    expand();

    setState(() {
      _messages.add(_ChatMsg(text: trimmed, isUser: true));
      _thinking = true;
    });
    _scrollToBottom();
    _history.add({'role': 'user', 'content': trimmed});

    try {
      final response = await http
          .post(
            Uri.parse(_chatUrl),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({
              'messages': _history,
              'member': widget.member,
              'locale': _locale,
            }),
          )
          .timeout(const Duration(seconds: 35));

      if (!mounted) return;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final reply = data['reply'] as String? ?? '…';
      _history.add({'role': 'assistant', 'content': reply});
      setState(() {
        _thinking = false;
        _messages.add(_ChatMsg(text: reply, isUser: false));
      });
    } catch (_) {
      if (!mounted) return;
      _history.removeLast();
      setState(() {
        _thinking = false;
        _messages.add(_ChatMsg(
          text: AppStrings.get('chatbotDefaultReply', _locale),
          isUser: false,
        ));
      });
    }
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final panelH = MediaQuery.of(context).size.height * 0.55;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOut,
      height: _expanded ? panelH : 52,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        border: const Border(
          top: BorderSide(color: _green, width: 2),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(children: [
        // ── Handle / header ──────────────────────────────────────────────────
        GestureDetector(
          onTap: () => _expanded ? _collapse() : expand(),
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration:
                      const BoxDecoration(color: _green, shape: BoxShape.circle),
                  child: const Icon(Icons.support_agent,
                      color: Colors.white, size: 15),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Chat',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A1A)),
                ),
                const Spacer(),
                AnimatedRotation(
                  turns: _expanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 320),
                  child: const Icon(Icons.keyboard_arrow_up,
                      size: 20, color: Colors.grey),
                ),
              ]),
            ),
          ),
        ),

        // ── Messages list ────────────────────────────────────────────────────
        if (_expanded) ...[
          Expanded(
            child: ListView.builder(
              controller: _scrollCtrl,
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
              itemCount: _messages.length + (_thinking ? 1 : 0),
              itemBuilder: (_, i) {
                if (_thinking && i == _messages.length) {
                  return const _PanelThinkingBubble();
                }
                return _PanelBubble(msg: _messages[i]);
              },
            ),
          ),

        // ── Input bar ────────────────────────────────────────────────────────
          Padding(
            padding: EdgeInsets.fromLTRB(
                12, 4, 12, MediaQuery.of(context).viewInsets.bottom > 0 ? 4 : 12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _textCtrl,
                  textInputAction: TextInputAction.send,
                  onSubmitted: _send,
                  enabled: !_thinking,
                  decoration: InputDecoration(
                    hintText: AppStrings.get('chatbotInputHint', _locale),
                    hintStyle:
                        TextStyle(color: Colors.grey.shade400, fontSize: 14),
                    filled: true,
                    fillColor: const Color(0xFFF3F4F6),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(22),
                      borderSide:
                          const BorderSide(color: Color(0xFF1A5C2A), width: 1.5),
                    ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _thinking ? null : () => _send(_textCtrl.text),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _thinking ? Colors.grey.shade300 : _green,
                ),
                child: _thinking
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.arrow_upward_rounded,
                        color: Colors.white, size: 18),
              ),
            ),
          ]),
          ),
        ],
      ]),
    );
  }
}

// ── Chat panel message model ──────────────────────────────────────────────────

class _ChatMsg {
  final String text;
  final bool isUser;
  const _ChatMsg({required this.text, required this.isUser});
}

// ── Bubble widget ─────────────────────────────────────────────────────────────

class _PanelBubble extends StatelessWidget {
  final _ChatMsg msg;
  const _PanelBubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    final isUser = msg.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            const CircleAvatar(
              radius: 13,
              backgroundColor: _green,
              child: Icon(Icons.support_agent, color: Colors.white, size: 13),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isUser ? _green : Colors.grey.shade100,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 16),
                ),
              ),
              child: isUser
                  ? Text(
                      msg.text,
                      style: const TextStyle(
                          fontSize: 13, color: Colors.white, height: 1.4),
                    )
                  : MarkdownBody(
                      data: msg.text,
                      styleSheet: MarkdownStyleSheet(
                        p: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF1A1A1A),
                            height: 1.4),
                        strong: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF1A1A1A),
                            fontWeight: FontWeight.bold,
                            height: 1.4),
                        em: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF1A1A1A),
                            fontStyle: FontStyle.italic,
                            height: 1.4),
                        listBullet: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFF1A1A1A),
                            height: 1.4),
                        blockSpacing: 6,
                      ),
                    ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 6),
            CircleAvatar(
              radius: 13,
              backgroundColor: _green.withValues(alpha: 0.20),
              child: const Icon(Icons.person, color: _green, size: 13),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Thinking bubble ───────────────────────────────────────────────────────────

class _PanelThinkingBubble extends StatefulWidget {
  const _PanelThinkingBubble();

  @override
  State<_PanelThinkingBubble> createState() => _PanelThinkingBubbleState();
}

class _PanelThinkingBubbleState extends State<_PanelThinkingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        const CircleAvatar(
          radius: 13,
          backgroundColor: _green,
          child: Icon(Icons.support_agent, color: Colors.white, size: 13),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomRight: Radius.circular(16),
              bottomLeft: Radius.circular(4),
            ),
          ),
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final offset = ((_ctrl.value * 3 - i) % 1.0).clamp(0.0, 1.0);
                final dy = offset < 0.5
                    ? -6.0 * (offset * 2)
                    : -6.0 * (1 - (offset - 0.5) * 2);
                return Padding(
                  padding: EdgeInsets.only(right: i < 2 ? 4.0 : 0),
                  child: Transform.translate(
                    offset: Offset(0, dy),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: _green),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Transactions Tab
// ─────────────────────────────────────────────────────────────────────────────

class _TransactionsTab extends StatefulWidget {
  final Map<String, dynamic> member;

  const _TransactionsTab({required this.member});

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
            _policies = List<Map<String, dynamic>>.from(data['policies'] ?? []);
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
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);

    final firstEntry = _policies.isNotEmpty ? _policies.first : null;
    final firstPolicy = firstEntry?['policy'] as Map<String, dynamic>?;
    final firstLastPay = firstEntry?['lastPay'] as Map<String, dynamic>?;
    final premiumAmount = firstPolicy?['premiumAmount']?.toString() ?? '—';
    final lastPayDate = firstLastPay?['paymentDate'] as String? ??
        firstPolicy?['lastPaidDate'] as String? ??
        '—';
    final nextPayDate = firstPolicy?['nextDueDate'] as String? ?? '—';
    final policyNo = firstPolicy?['policyNo'] as String? ?? '—';

    final paymentAccess = widget.member['payment_access'] == true;

    return RefreshIndicator(
      onRefresh: _fetchPolicies,
      color: _green,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s('paymentsTitle'),
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A1A))),
          const SizedBox(height: 4),
          Text(s('managePayments'),
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          const SizedBox(height: 20),
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
                  label: s('lastPayment'),
                  icon: Icons.check_circle_outline,
                  iconColor: Colors.green.shade600,
                  value: lastPayDate != '—'
                      ? AppStrings.formatDate(lastPayDate, locale)
                      : s('noRecord'),
                  sub: premiumAmount != '—' ? 'HTG $premiumAmount' : '',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _PayInfoCard(
                  label: s('nextPaymentLabel'),
                  icon: Icons.schedule,
                  iconColor: const Color(0xFFE65100),
                  value: nextPayDate != '—'
                      ? AppStrings.formatDate(nextPayDate, locale)
                      : s('contactUs'),
                  sub: premiumAmount != '—' ? 'HTG $premiumAmount' : '',
                ),
              ),
            ]),
            const SizedBox(height: 20),
            _SectionCard(
              title: s('payPremium'),
              icon: Icons.credit_card,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (policyNo != '—') ...[
                      Text('${s('policyPrefix')}: $policyNo',
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey.shade600)),
                      const SizedBox(height: 4),
                    ],
                    if (premiumAmount != '—') ...[
                      RichText(
                        text: TextSpan(children: [
                          TextSpan(
                              text: s('amountDue'),
                              style: TextStyle(
                                  fontSize: 13, color: Colors.grey.shade600)),
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
                                  color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.payment),
                      label: Text(_payLoading ? s('processing') : s('payNow')),
                      style: ElevatedButton.styleFrom(
                          backgroundColor:
                              paymentAccess ? _green : Colors.grey.shade400,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 52),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12))),
                      onPressed: (!paymentAccess || _payLoading)
                          ? null
                          : () => _handlePayNow(context, s),
                    ),
                    if (!paymentAccess) ...[
                      const SizedBox(height: 8),
                      Row(children: [
                        Icon(Icons.lock_outline,
                            size: 14, color: Colors.grey.shade500),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(s('paymentAccessDisabled'),
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade500)),
                        ),
                      ]),
                    ],
                    const SizedBox(height: 8),
                    Center(
                        child: Text(s('securePayment'),
                            style: TextStyle(
                                fontSize: 11, color: Colors.grey.shade500))),
                  ]),
            ),
            const SizedBox(height: 20),
            _SectionCard(
              title: s('paymentHistory'),
              icon: Icons.history,
              child: _policies.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(s('noPaymentRecords'),
                          style: TextStyle(
                              color: Colors.grey.shade500, fontSize: 13)),
                    )
                  : Column(
                      children: _policies
                          .map((p) =>
                              _PaymentHistoryTile(policy: p, locale: locale))
                          .toList()),
            ),
          ],
        ]),
      ),
    );
  }

  Future<void> _handlePayNow(
      BuildContext context, String Function(String) s) async {
    setState(() => _payLoading = true);
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    setState(() => _payLoading = false);
    showModalBottomSheet(
      // ignore: use_build_context_synchronously
      context: this.context,
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
            child: Icon(Icons.check_circle,
                color: Colors.green.shade600, size: 36),
          ),
          const SizedBox(height: 16),
          Text(s('paymentPortal'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(s('paymentComingSoon'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: () => Navigator.pop(this.context),
            style: ElevatedButton.styleFrom(
                backgroundColor: _green,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            child: Text(s('ok')),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Reusable small widgets
// ─────────────────────────────────────────────────────────────────────────────

// ── Member ID + status + policy count ────────────────────────────────────────

class _MemberSummaryCard extends StatelessWidget {
  final bool isActive;
  final int? activePolicies; // null while loading
  final int? totalPolicies;
  final String locale;
  final String memberId;

  const _MemberSummaryCard({
    required this.isActive,
    required this.activePolicies,
    required this.totalPolicies,
    required this.locale,
    required this.memberId,
  });

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);

    final policyText = activePolicies == null
        ? '…'
        : '$activePolicies/${totalPolicies ?? activePolicies} total ${s('policiesLabel').toLowerCase()}';

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
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration: const BoxDecoration(
              color: Color(0xFFE8F5E9), shape: BoxShape.circle),
          child: const Icon(Icons.badge_outlined, color: _green, size: 20),
        ),
        const SizedBox(height: 10),
        // Status badge
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: isActive ? Colors.green.shade50 : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            isActive ? s('active') : s('inactive'),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isActive ? Colors.green.shade700 : Colors.grey.shade600,
            ),
          ),
        ),
        const SizedBox(height: 10),
        // Member ID
        Text(
          memberId,
          style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade500,
              fontFamily: 'monospace'),
        ),
        const SizedBox(height: 6),
        // Policy count: "1/1 total policies"
        Text(
          policyText,
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A1A)),
        ),
      ]),
    );
  }
}

// ── Next payment: date + amount + Pay Now button ──────────────────────────────

class _NextPaymentCard extends StatelessWidget {
  final String nextPayDate;
  final String premiumAmount;
  final String locale;
  final VoidCallback onPayNow;

  const _NextPaymentCard({
    required this.nextPayDate,
    required this.premiumAmount,
    required this.locale,
    required this.onPayNow,
  });

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);
    final hasDate   = nextPayDate   != '—' && nextPayDate.isNotEmpty;
    final hasAmount = premiumAmount != '—' && premiumAmount.isNotEmpty;

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
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36, height: 36,
          decoration: const BoxDecoration(
              color: Color(0xFFFFF3E0), shape: BoxShape.circle),
          child: const Icon(Icons.calendar_month_outlined,
              color: Color(0xFFE65100), size: 20),
        ),
        const SizedBox(height: 10),
        Text(s('nextPaymentLabel'),
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        const SizedBox(height: 2),
        Text(
          hasDate ? AppStrings.formatDate(nextPayDate, locale) : '—',
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A1A)),
        ),
        const Spacer(),
        // Price + Pay Now button on the same row
        Row(children: [
          Text(
            hasAmount ? 'HTG $premiumAmount' : '—',
            style: TextStyle(
                fontSize: 13,
                color: hasAmount ? const Color(0xFFE65100) : Colors.grey.shade400,
                fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          ElevatedButton(
            onPressed: onPayNow,
            style: ElevatedButton.styleFrom(
              backgroundColor: _green,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
              textStyle:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
            child: Text(s('payNow')),
          ),
        ]),
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
          Divider(
              height: 1,
              indent: 72,
              endIndent: 16,
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
                  fontSize: 14, fontWeight: FontWeight.bold, color: _green)),
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
              style: const TextStyle(fontSize: 13, color: Color(0xFF1A1A1A))),
        ),
      ]),
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
  final String locale;

  const _PaymentHistoryTile({required this.policy, required this.locale});

  @override
  Widget build(BuildContext context) {
    String s(String key) => AppStrings.get(key, locale);
    final pol = policy['policy'] as Map<String, dynamic>? ?? {};
    final policyNo = pol['policyNo'] as String? ?? '—';
    final premium = pol['premiumAmount']?.toString() ?? '—';
    final startDate = pol['startDate'] as String? ?? '—';
    final status = (pol['policyStatus'] as String? ?? '').toUpperCase();
    final isActive = status == 'ACTIVE';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
              color: isActive ? Colors.green.shade50 : Colors.grey.shade100,
              shape: BoxShape.circle),
          child: Icon(
            isActive ? Icons.check_circle : Icons.cancel_outlined,
            color: isActive ? Colors.green.shade600 : Colors.grey.shade400,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s('policyPrefix')} $policyNo',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1A1A1A))),
            Text('${s('sincePrefix')} $startDate',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          if (premium != '—')
            Text('HTG $premium',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.bold, color: _green)),
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: isActive ? Colors.green.shade100 : Colors.grey.shade200,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              status.isNotEmpty ? status : '—',
              style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color:
                      isActive ? Colors.green.shade700 : Colors.grey.shade600),
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
  final String locale;
  const _PaymentNotificationBanner(
      {required this.member, required this.locale});

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
    String s(String key) => AppStrings.get(key, widget.locale);

    final notif =
        widget.member['payment_notification'] as Map<String, dynamic>?;
    if (notif == null) return const SizedBox.shrink();
    final seen = notif['seen'] == true || notif['seen'] == 'true';
    if (seen || _dismissed) return const SizedBox.shrink();

    final amount = notif['amountPaid']?.toString() ?? '—';
    final rawDate = notif['paymentDate'] as String? ?? '—';
    final date = AppStrings.formatDate(rawDate, widget.locale);
    final ref = notif['referenceNo'] as String? ?? '—';
    final policyNo = notif['policyNo'] as String? ?? '—';
    final method = notif['paymentMethod'] as String? ?? '—';
    final paymentPeriod = notif['paymentPeriod'] as String? ?? '';

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
          Icon(Icons.check_circle, color: Colors.green.shade600, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              s('paymentReceived'),
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: Colors.green.shade800),
            ),
          ),
          GestureDetector(
            onTap: _acknowledge,
            child: Icon(Icons.close, size: 18, color: Colors.green.shade600),
          ),
        ]),
        const SizedBox(height: 8),
        Text(
          s('paymentReceivedDesc').replaceAll('{amount}', amount),
          style: TextStyle(fontSize: 13, color: Colors.green.shade800),
        ),
        const SizedBox(height: 8),
        if (paymentPeriod.isNotEmpty)
          _NotifRow(s('periodLabel'), paymentPeriod),
        _NotifRow(s('collectedOnLabel'), date),
        _NotifRow(s('policyPrefix'), policyNo),
        _NotifRow(s('methodLabel'), method),
        _NotifRow(s('referenceLabel'), ref),
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
            child: Text(s('gotItDismiss')),
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
              style: TextStyle(fontSize: 12, color: Colors.green.shade600)),
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
//  Services Tab
// ─────────────────────────────────────────────────────────────────────────────

class _ServicesTab extends StatelessWidget {
  final Map<String, dynamic> member;
  final String locale;

  const _ServicesTab({required this.member, required this.locale});

  String s(String k) => AppStrings.get(k, locale);

  void _openSupportSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.support_agent, color: _green, size: 48),
          const SizedBox(height: 12),
          Text(s('assistance24h'),
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          _SupportTile(
              icon: Icons.phone, label: s('callUs'), value: '+509 XXXX-XXXX'),
          const Divider(),
          _SupportTile(
              icon: Icons.email, label: s('email'), value: 'kontak@kafa.org'),
          const Divider(),
          _SupportTile(
              icon: Icons.access_time,
              label: s('hours'),
              value: s('hoursValue')),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Derive member's current plan code from member data if available
    final String? currentPlanCode =
        (member['product_code'] ?? member['productCode']) as String?;
    final memberId = member['memberId'] as String? ?? '';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s('servicesTitle'),
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A1A))),
        const SizedBox(height: 20),

        // Quick Quote card
        _ServiceCard(
          icon: Icons.request_quote_outlined,
          iconColor: const Color(0xFF0277BD),
          accentColor: const Color(0xFFE1F5FE),
          title: s('quickQuoteCard'),
          subtitle: s('quickQuoteCardSub'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => QuickQuoteScreen(
                memberId:   memberId,
                memberName: member['full_name'] as String? ?? '',
                phone:      member['phone']     as String?,
                email:      member['email']     as String?,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Plans & Coverage card
        _ServiceCard(
          icon: Icons.shield_outlined,
          iconColor: _green,
          accentColor: const Color(0xFFE8F5E9),
          title: s('viewPlans'),
          subtitle: s('viewPlansSub'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PlansScreen(
                  memberId:       memberId,
                  currentPlanCode: currentPlanCode,
                  memberName:     member['full_name'] as String? ?? '',
                  phone:          member['phone']     as String?,
                  email:          member['email']     as String?),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // 24/7 Assistance card
        _ServiceCard(
          icon: Icons.headset_mic_outlined,
          iconColor: const Color(0xFF7B1FA2),
          accentColor: const Color(0xFFF3E5F5),
          title: s('assistance24h'),
          subtitle: s('assistance24hSub'),
          onTap: () => _openSupportSheet(context),
        ),
        const SizedBox(height: 12),

        // Funeral Services card
        _ServiceCard(
          icon: Icons.local_florist_outlined,
          iconColor: const Color(0xFF4A148C),
          accentColor: const Color(0xFFEDE7F6),
          title: s('funeralServicesCard'),
          subtitle: s('funeralServicesCardSub'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const FuneralServicesScreen()),
          ),
        ),
        const SizedBox(height: 12),

        // Documents & Wishes card
        _ServiceCard(
          icon: Icons.folder_outlined,
          iconColor: const Color(0xFF0277BD),
          accentColor: const Color(0xFFE1F5FE),
          title: s('documentsCard'),
          subtitle: s('documentsCardSub'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => DocumentsScreen(memberId: memberId),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Death Emergency card
        _ServiceCard(
          icon: Icons.crisis_alert,
          iconColor: const Color(0xFFB71C1C),
          accentColor: const Color(0xFFFFEBEE),
          title: s('deathEmergency'),
          subtitle: s('deathEmergencySub'),
          onTap: () {
            final policies = member['policies'] as List<dynamic>?;
            final policyNo = policies != null && policies.isNotEmpty
                ? (policies.first as Map<String, dynamic>)['policyNo']
                        as String? ??
                    ''
                : '';
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DeathReportScreen(
                  memberId: memberId,
                  memberName: member['fullName'] as String? ?? '',
                  policyNo: policyNo,
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 12),

        // Express Enrollment card
        _ServiceCard(
          icon: Icons.assignment_outlined,
          iconColor: const Color(0xFF1A5C2A),
          accentColor: const Color(0xFFE8F5E9),
          title: s('expressEnrollment'),
          subtitle: s('expressEnrollmentSub'),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => EnrollmentFormScreen(
                memberId: memberId,
                memberName: member['fullName'] as String? ?? '',
                phone: member['phone'] as String?,
                email: member['email'] as String?,
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor, accentColor;
  final String title, subtitle;
  final VoidCallback onTap;

  const _ServiceCard({
    required this.icon,
    required this.iconColor,
    required this.accentColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 8,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Row(children: [
          Container(
            width: 52,
            height: 52,
            decoration:
                BoxDecoration(color: accentColor, shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 26),
          ),
          const SizedBox(width: 16),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold)),
              const SizedBox(height: 3),
              Text(subtitle,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
            ]),
          ),
          Icon(Icons.arrow_forward_ios, size: 14, color: Colors.grey.shade400),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Profile Tab
// ─────────────────────────────────────────────────────────────────────────────

class _ProfileTab extends StatelessWidget {
  final Map<String, dynamic> member;
  final String locale;
  final Future<void> Function() onLogout;

  const _ProfileTab({
    required this.member,
    required this.locale,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    final name = member['full_name'] as String? ?? '—';
    final phone = member['phone'] as String? ?? '—';
    final email = member['email'] as String? ?? '—';
    final address = member['address'] as String? ?? '—';
    final dob = member['date_of_birth'] as String? ??
        member['dateOfBirth'] as String? ??
        '—';
    final idNumber = member['identification_number'] as String? ??
        member['identificationNumber'] as String? ??
        '—';
    final idType = member['identification_type'] as String? ??
        member['identificationType'] as String? ??
        '—';
    final memberId = member['memberId'] as String? ?? '—';
    final commune =
        (member['locality'] as Map<String, dynamic>?)?['commune'] as String? ??
            '—';
    final issuedDate = member['issued_date'] as String? ??
        member['issuedDate'] as String? ??
        '';
    final isActive = member['status'] == true || member['status'] == 'true';

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Avatar + name header
        Center(
          child: Column(children: [
            CircleAvatar(
              radius: 40,
              backgroundColor: _green,
              child: Text(
                name.isNotEmpty ? name[0].toUpperCase() : '?',
                style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
            ),
            const SizedBox(height: 12),
            Text(name,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              decoration: BoxDecoration(
                color: isActive ? Colors.green.shade100 : Colors.grey.shade200,
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
                  isActive ? s('activeMember') : s('inactiveMember'),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isActive
                          ? Colors.green.shade700
                          : Colors.grey.shade600),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 24),

        // Personal info
        _SectionCard(
          title: s('profileInfo'),
          icon: Icons.person_outline,
          child: Column(children: [
            _OverviewRow(
                icon: Icons.badge_outlined,
                label: s('memberId'),
                value: memberId),
            _OverviewRow(
                icon: Icons.location_on_outlined,
                label: s('commune'),
                value: commune),
            _OverviewRow(
                icon: Icons.home_outlined, label: s('address'), value: address),
            _OverviewRow(
                icon: Icons.phone_outlined, label: s('phone'), value: phone),
            _OverviewRow(
                icon: Icons.email_outlined, label: s('email'), value: email),
            _OverviewRow(
                icon: Icons.cake_outlined,
                label: s('dateOfBirth'),
                value: AppStrings.formatDate(dob, locale)),
            if (issuedDate.isNotEmpty)
              _OverviewRow(
                  icon: Icons.verified_outlined,
                  label: s('memberSince'),
                  value: AppStrings.formatDate(issuedDate, locale)),
          ]),
        ),
        const SizedBox(height: 16),

        // Identification
        _SectionCard(
          title: s('identification'),
          icon: Icons.fingerprint,
          child: Column(children: [
            _OverviewRow(
                icon: Icons.credit_card, label: s('idType'), value: idType),
            _OverviewRow(
                icon: Icons.numbers, label: s('idNumber'), value: idNumber),
          ]),
        ),
        const SizedBox(height: 24),

        // Logout button
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.logout, color: Colors.red),
            label: Text(s('logout'), style: const TextStyle(color: Colors.red)),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 50),
              side: const BorderSide(color: Colors.red),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: onLogout,
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _OptionsButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _OptionsButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Text(label,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: color)),
          const Spacer(),
          Icon(Icons.arrow_forward_ios, size: 14, color: color),
        ]),
      ),
    );
  }
}

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
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            Text(value,
                style:
                    const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }
}
