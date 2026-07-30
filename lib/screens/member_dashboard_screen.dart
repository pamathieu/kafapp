import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../services/session_service.dart';
import '../services/dev_env.dart';
import '../services/share_service.dart';
import 'member_login_screen.dart';
import 'policy_screen.dart';
import 'plans_screen.dart';
import 'funeral_services_screen.dart';
import 'documents_screen.dart';
import 'death_report_screen.dart';
import 'enrollment_form_screen.dart';
import 'quick_quote_screen.dart';
import 'payment_screen.dart';
import 'shares_screen.dart';

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
  bool _showPaymentSuccess = false;

  final _chatPanelKey = GlobalKey<_DashboardChatPanelState>();
  final _dashboardTabKey = GlobalKey<_DashboardTabState>();

  // Live member data — refreshed from server on init so notifications are current
  late Map<String, dynamic> _member;

  Timer? _refreshTimer;

  static const _baseUrl = kApiBaseUrl;

  @override
  void initState() {
    super.initState();
    if (kIsWeb && Uri.base.queryParameters['payment'] == 'success') {
      _showPaymentSuccess = true;
    }
    
    // Validate member data before using
    try {
      final memberId = widget.member['memberId'] as String?;
      final fullName = widget.member['full_name'] as String?;
      
      if (memberId == null || memberId.isEmpty ||
          fullName == null || fullName.isEmpty) {
        throw Exception('Invalid member data on dashboard init');
      }
      
      _member = widget.member;
      try {
        _checkPolicy();
        _refreshMember();
        // Silently re-fetch so notifications/payment access stay current
        // without the member needing to log out and back in.
        _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
          _checkPolicy();
          _refreshMember();
        });
      } catch (e) {
        debugPrint('Error during policy/member refresh: $e');
        // Continue with cached data
      }
    } catch (e) {
      debugPrint('Dashboard init error: $e');
      // Force logout on invalid data
      WidgetsBinding.instance.addPostFrameCallback((_) {
        SessionService.clearSession().then((_) {
          if (mounted && context.mounted) {
            Navigator.of(context).pushAndRemoveUntil(
              MaterialPageRoute(builder: (_) => const MemberLoginScreen()),
              (_) => false,
            );
          }
        });
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// Re-fetches the member profile from the server so payment_notification
  /// and payment_access are always current, even when loaded from session cache.
  Future<void> _refreshMember() async {
    final memberId = widget.member['memberId'] as String? ?? '';
    final companyId = widget.member['companyId'] as String? ?? 'KAFA-001';
    if (memberId.isEmpty) return;
    try {
      final uri = Uri.parse(
          '$_baseUrl${devPath('/member/profile')}?memberId=${Uri.encodeComponent(memberId)}'
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
          '$kApiBaseUrl${devPath('/member/policy')}?memberId=${Uri.encodeComponent(memberId)}');
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
    try {
      final langProvider = context.watch<LanguageProvider>();
      final locale = langProvider.locale;
      String s(String key) => AppStrings.get(key, locale);

      final member = _member;
      final name = member['full_name'] as String? ?? s('memberFallback');
      final isActive = member['status'] == 'Active';
      final isPendingStatus = member['status'] == 'Pending';

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
          key: _dashboardTabKey,
          member: _member,
          onGoPolicies: () => _goTab(1),
          onOpenChat: () => _chatPanelKey.currentState?.expand(),
          onPaymentMade: () => setState(() => _showPaymentSuccess = true),
        ),
        PolicyScreen(
          member: _member,
          embedded: true,
          onPaymentMade: () {
            _dashboardTabKey.currentState?.refresh();
            setState(() => _showPaymentSuccess = true);
          },
        ),
        _ServicesTab(
          member: _member,
          locale: locale,
          onMemberUpdated: (fresh) => setState(() => _member = fresh),
          onPaymentMade: () => setState(() => _showPaymentSuccess = true),
        ),
        _ProfileTab(
          member: _member,
          locale: locale,
          onLogout: handleLogout,
          onMemberUpdated: (fresh) => setState(() => _member = fresh),
        ),
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
          isPendingStatus: isPendingStatus,
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
        body: Column(
          children: [
            if (!isActive && member['reason'] == 'Did not pay membership share')
              _PendingMembershipBanner(
                text: () {
                  final paid = double.tryParse(member['membershipSharesPaid']?.toString() ?? '') ?? 0.0;
                  if (paid > 0) {
                    final remaining = (50.0 - paid).clamp(0.0, 50.0);
                    return s('pendingMembershipShareRemaining')
                        .replaceAll('{amount}', '\$${remaining.toStringAsFixed(2)}');
                  }
                  return s('pendingMembershipShareWarning');
                }(),
                memberId: member['memberId'] as String? ?? '',
                memberName: name,
                onMemberUpdated: (fresh) => setState(() => _member = fresh),
              ),
            if (_showPaymentSuccess)
              _PaymentSuccessBanner(
                locale: locale,
                onSeeReceipt: () {
                  setState(() => _showPaymentSuccess = false);
                  _dashboardTabKey.currentState?.scrollToPayments();
                },
                onDismiss: () => setState(() => _showPaymentSuccess = false),
              ),
            Expanded(child: IndexedStack(index: _tab, children: tabs)),
          ],
        ),
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
    } catch (e) {
      // If build fails, clear session and return to login
      debugPrint('Dashboard build error: $e');
      final locale = context.read<LanguageProvider>().locale;
      String s(String key) => AppStrings.get(key, locale);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          SessionService.clearSession().then((_) {
            if (mounted && context.mounted) {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const MemberLoginScreen()),
                (_) => false,
              );
            }
          });
        }
      });
      return Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(s('errorOccurredRedirecting')),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const MemberLoginScreen()),
                  (_) => false,
                ),
                child: Text(s('goToLogin')),
              ),
            ],
          ),
        ),
      );
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Pending membership share banner
// ─────────────────────────────────────────────────────────────────────────────

class _PendingMembershipBanner extends StatelessWidget {
  final String text;
  final String memberId;
  final String memberName;
  final void Function(Map<String, dynamic>) onMemberUpdated;

  const _PendingMembershipBanner({
    required this.text,
    required this.memberId,
    required this.memberName,
    required this.onMemberUpdated,
  });

  Future<void> _payShare(BuildContext context) async {
    final paid = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => SharesScreen(
          memberId: memberId,
          memberName: memberName,
          isPending: true,
        ),
      ),
    );
    if (paid != true) return;
    try {
      final uri = Uri.parse(
          '$kApiBaseUrl/members?memberId=${Uri.encodeComponent(memberId)}&companyId=KAFA-001');
      final response = await http.get(uri);
      if (response.statusCode != 200) return;
      final fresh = json.decode(response.body) as Map<String, dynamic>;
      fresh.remove('credentials');
      await SessionService.saveSession(fresh);
      onMemberUpdated(fresh);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.orange.shade50,
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: Colors.orange.shade900, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: () => _payShare(context),
            style: TextButton.styleFrom(
              backgroundColor: Colors.orange.shade800,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(s('payNow'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
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
  final bool isPendingStatus;
  final bool hasPolicy;
  final VoidCallback onLogout;
  final void Function(String) onLocaleChange;
  final Map<String, dynamic> member;

  const _KafaAppBar({
    required this.name,
    required this.locale,
    required this.isActive,
    required this.isPendingStatus,
    required this.hasPolicy,
    required this.onLogout,
    required this.onLocaleChange,
    required this.member,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

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
                  color: isActive
                      ? Colors.green.shade100
                      : isPendingStatus
                          ? Colors.amber.shade100
                          : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.circle,
                      size: 8,
                      color: isActive
                          ? Colors.green.shade700
                          : isPendingStatus
                              ? Colors.amber.shade700
                              : Colors.grey.shade500),
                  const SizedBox(width: 6),
                  Text(
                    isActive
                        ? s('activeMember')
                        : isPendingStatus
                            ? s('pendingMember')
                            : s('inactiveMember'),
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isActive
                            ? Colors.green.shade700
                            : isPendingStatus
                                ? Colors.amber.shade700
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

class _AlertsBellButton extends StatefulWidget {
  final Map<String, dynamic> member;
  final String locale;

  const _AlertsBellButton({required this.member, required this.locale});

  @override
  State<_AlertsBellButton> createState() => _AlertsBellButtonState();
}

class _AlertsBellButtonState extends State<_AlertsBellButton> {
  static const _baseUrl = kApiBaseUrl;
  bool _paymentDismissed = false;

  Map<String, dynamic>? get _paymentNotif {
    if (_paymentDismissed) return null;
    final notif =
        widget.member['payment_notification'] as Map<String, dynamic>?;
    if (notif == null) return null;
    final seen = notif['seen'] == true || notif['seen'] == 'true';
    return seen ? null : notif;
  }

  Future<void> _acknowledgePayment() async {
    setState(() => _paymentDismissed = true);
    try {
      final memberId = widget.member['memberId'] as String? ?? '';
      await http.post(
        Uri.parse('$_baseUrl/member/acknowledge-payment'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'memberId': memberId, 'companyId': 'KAFA-001'}),
      );
    } catch (_) {}
  }

  List<Map<String, dynamic>> _buildAlerts(String Function(String) s) {
    final isActive = widget.member['status'] == 'Active';
    final alerts = <Map<String, dynamic>>[];

    // Payment notification at the top
    final notif = _paymentNotif;
    if (notif != null) {
      alerts.add({'type': 'payment', 'data': notif});
    }

    if (!isActive) {
      alerts.add({
        'type': 'generic',
        'icon': Icons.warning_amber_rounded,
        'color': Colors.orange,
        'text': s('alertInactive'),
      });
    }
    alerts.add({
      'type': 'generic',
      'icon': Icons.info_outline,
      'color': const Color(0xFF1565C0),
      'text': s('alertContactInfo'),
    });
    return alerts;
  }

  void _show(BuildContext context) {
    String s(String k) => AppStrings.get(k, widget.locale);
    final alerts = _buildAlerts(s);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(Icons.notifications_outlined, color: _green, size: 22),
              const SizedBox(width: 10),
              Text(s('alertsReminders'),
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold)),
            ]),
            const SizedBox(height: 16),
            ...alerts.map((a) {
              if (a['type'] == 'payment') {
                final notif = a['data'] as Map<String, dynamic>;
                final rawAmount = notif['amountPaid']?.toString() ?? '—';
                final isUsd = (notif['currency'] as String? ?? 'usd').toLowerCase() == 'usd';
                final amount = rawAmount == '—' ? rawAmount : (isUsd ? 'US\$$rawAmount' : 'HTG $rawAmount');
                final rawDate = notif['paymentDate'] as String? ?? '—';
                final date = AppStrings.formatDateTime(rawDate, widget.locale);
                final policyNo = notif['policyNo'] as String? ?? '—';
                final method = notif['paymentMethod'] as String? ?? '—';
                final period = notif['paymentPeriod'] as String? ?? '';
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.green.shade300),
                  ),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.check_circle,
                              color: Colors.green.shade600, size: 20),
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
                        ]),
                        const SizedBox(height: 6),
                        Text(
                          s('paymentReceivedDesc').replaceAll('{amount}', amount),
                          style: TextStyle(
                              fontSize: 13, color: Colors.green.shade800),
                        ),
                        const SizedBox(height: 8),
                        if (period.isNotEmpty) _NotifRow(s('periodLabel'), period),
                        _NotifRow(s('collectedOnLabel'), date),
                        _NotifRow(s('paymentTypeLabel'), policyNo),
                        _NotifRow(s('methodLabel'), method),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: () {
                              _acknowledgePayment();
                              setSheetState(() {});
                              Navigator.pop(ctx);
                            },
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
              // Generic alert
              return Padding(
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
              );
            }),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, widget.locale);
    final alerts = _buildAlerts(s);
    final hasPayment = _paymentNotif != null;
    final hasWarn = widget.member['status'] != true &&
        widget.member['status'] != 'true';

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
              color: hasPayment
                  ? Colors.green.shade500
                  : hasWarn
                      ? Colors.orange
                      : Colors.green.shade600,
              shape: BoxShape.circle,
              border: Border.all(color: _green, width: 1.5),
            ),
            child: Center(
              child: Text('${alerts.length}',
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
  final VoidCallback? onPaymentMade;

  const _DashboardTab({
    super.key,
    required this.member,
    required this.onGoPolicies,
    required this.onOpenChat,
    this.onPaymentMade,
  });

  @override
  State<_DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<_DashboardTab>
    with SingleTickerProviderStateMixin {
  List<Map<String, dynamic>> _policies = [];
  bool _loadingPolicies = true;
  List<Map<String, dynamic>> _shares = [];
  bool _loadingShares = true;
  bool _quickActExpanded = true;
  bool _optionsOpen = false;
  Timer? _refreshTimer;

  final _shareService = ShareService();
  final _scrollCtrl = ScrollController();
  final _payHistoryKey = GlobalKey();

  late final AnimationController _qaCtrl;
  late final Animation<double> _qaAnim;

  static const String _baseUrl = kApiBaseUrl;

  int _paymentEntryCount() {
    var count = 0;
    for (final entry in _policies) {
      count += (entry['paymentHistory'] as List<dynamic>? ?? []).length;
    }
    count += _shares.where((s) => s['status'] != 'FAILED').length;
    return count;
  }

  /// Called by sibling tabs (e.g. after a premium payment or share purchase
  /// made from the Policies tab) so the Payments Overview card reflects it
  /// immediately instead of waiting for the 20s background poll. Polls for a
  /// while since a successful client-side payment can resolve before the
  /// Stripe webhook has actually recorded it server-side (webhook delivery
  /// latency varies, e.g. several seconds via the `stripe listen` CLI
  /// forwarder in local dev).
  Future<void> refresh() async {
    final before = _paymentEntryCount();
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future.wait([_fetchPolicies(), _fetchShares()]);
      if (_paymentEntryCount() > before) break;
      if (attempt < 19) await Future.delayed(const Duration(seconds: 1));
    }
  }

  @override
  void initState() {
    super.initState();
    _qaCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: 1.0, // starts expanded
    );
    _qaAnim = CurvedAnimation(parent: _qaCtrl, curve: Curves.easeInOut);
    final memberId = widget.member['memberId'] as String? ?? '';
    if (memberId.isNotEmpty) {
      _fetchPolicies();
      _fetchShares();
      // Silently re-fetch so payments/policy changes made elsewhere (e.g. by
      // an admin) show up here without the member needing to reload.
      _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        _fetchPolicies();
        _fetchShares();
      });
    } else {
      setState(() {
        _loadingPolicies = false;
        _loadingShares = false;
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _scrollCtrl.dispose();
    _qaCtrl.dispose();
    super.dispose();
  }

  void scrollToPayments() {
    final ctx = _payHistoryKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
    }
  }

  void _openChat() => widget.onOpenChat();

  String _safeContactText(String Function(String) s) {
    try {
      final text = s('contactKafaForAuth');
      if (text.isEmpty) return 'Contact KAFA for authorization.';
      final parts = text.split('.');
      return '${parts.isNotEmpty ? parts.first : text}.';
    } catch (_) {
      return 'Contact KAFA for authorization.';
    }
  }

  Future<void> _handleDashboardPayNow(BuildContext ctx) async {
    if (_policies.isEmpty) return;
    final locale = context.read<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);
    if (_policies.length > 1) {
      await _showDashboardPolicyPicker(ctx, s);
    } else {
      await _navigateDashboardPayment(ctx, s, _policies.first);
    }
  }

  Future<void> _showDashboardPolicyPicker(
      BuildContext ctx, String Function(String) s) async {
    await showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(s('selectPolicyToPay'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 12),
            ..._policies.map((entry) {
              final pol = entry['policy'] as Map<String, dynamic>? ?? {};
              final policyNo = pol['policyNo'] as String? ?? '—';
              final productCode = pol['productCode'] as String? ?? '—';
              final premium = pol['premiumAmount']?.toString() ?? '—';
              return ListTile(
                leading: const Icon(Icons.policy_outlined, color: _green),
                title: Text(policyNo,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('$productCode  ·  US\$$premium'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _navigateDashboardPayment(ctx, s, entry);
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _navigateDashboardPayment(BuildContext ctx,
      String Function(String) s, Map<String, dynamic> entry) async {
    final pol = entry['policy'] as Map<String, dynamic>? ?? {};
    final memberId = widget.member['memberId'] as String? ?? '';
    final memberName =
        (widget.member['full_name'] as String?)?.trim() ?? s('memberFallback');
    final policyId = pol['policyNo'] as String? ?? '';
    final premiumRaw = pol['premiumAmount']?.toString() ?? '0';
    final nextDueDate = pol['nextDueDate'] as String? ?? '';
    final amountCents = ((double.tryParse(premiumRaw) ?? 0) * 100).round();
    final paid = await Navigator.push<bool>(
      ctx,
      MaterialPageRoute(
        builder: (_) => PaymentScreen(
          args: PaymentArgs(
            memberId: memberId,
            policyId: policyId,
            memberName: memberName,
            amountCents: amountCents,
            periodStart: '',
            periodEnd: nextDueDate,
            currency: 'usd',
            productCode: pol['productCode'] as String?,
          ),
        ),
      ),
    );
    if (paid == true) {
      widget.onPaymentMade?.call();
      refresh();
    }
  }

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
          '$_baseUrl${devPath('/member/policy')}?memberId=${Uri.encodeComponent(memberId)}');
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

  Future<void> _fetchShares() async {
    final memberId = widget.member['memberId'] as String? ?? '';
    try {
      final shares = await _shareService.getShares(memberId);
      if (mounted) {
        setState(() {
          _shares = shares;
          _loadingShares = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingShares = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    try {
      final locale = context.watch<LanguageProvider>().locale;
      String s(String key) => AppStrings.get(key, locale);

      final member = widget.member;
      final name = (member['full_name'] as String?)?.trim() ?? s('memberFallback');
      final memberId = (member['memberId'] as String?)?.trim() ?? '';
      final isActive = member['status'] == 'Active';
      final isPendingStatus = member['status'] == 'Pending';
      final totalPolicies = _policies.length;
      final activePolicies = _policies.where((p) {
        try {
          final pol = p['policy'] as Map<String, dynamic>? ?? {};
          return (pol['policyStatus'] as String? ?? '').toUpperCase() == 'ACTIVE';
        } catch (_) {
          return false;
        }
      }).length;

      // Derive next premium from first active policy if available
      final firstPolicyMap = _policies.isNotEmpty
          ? _policies.first['policy'] as Map<String, dynamic>?
          : null;
      final premiumAmount = firstPolicyMap?['premiumAmount']?.toString() ?? '—';
      final nextPayDate = firstPolicyMap?['nextDueDate'] as String? ?? '—';
      final deathReportPolicyNo = firstPolicyMap?['policyNo'] as String? ?? '';

      final firstName = name.contains(' ') ? name.split(' ').first : name;

      // ── Payments overview: premium installments (per policy) + share purchases ──
      double premiumsPaid = 0;
      int premiumCount = 0;
      for (final entry in _policies) {
        final history = entry['paymentHistory'] as List<dynamic>? ?? [];
        for (final p in history) {
          premiumsPaid += (p['amountPaid'] as num? ?? 0).toDouble();
          premiumCount++;
        }
      }
      double sharesPaid = 0;
      int shareCount = 0;
      for (final share in _shares) {
        if (share['status'] == 'SUCCEEDED') {
          sharesPaid += (share['amount'] as num? ?? 0).toDouble();
          shareCount++;
        }
      }
      final loadingPayments = _loadingPolicies || _loadingShares;

      return Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => Future.wait([_fetchPolicies(), _fetchShares()]),
              color: _green,
              child: SingleChildScrollView(
                controller: _scrollCtrl,
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
                            : isPendingStatus
                                ? s('membershipPending')
                                : s('membershipInactive'),
                        style: TextStyle(
                            fontSize: 13,
                            color: isActive
                                ? Colors.green.shade700
                                : isPendingStatus
                                    ? Colors.amber.shade700
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
                            const Icon(Icons.info_outline,
                                size: 18, color: Colors.orange),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _safeContactText(s),
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

                    // ── Payments overview ─────────────────────────────────────────────
                    _PaymentsOverviewCard(
                      loading: loadingPayments,
                      totalPaid: premiumsPaid + sharesPaid,
                      transactionCount: premiumCount + shareCount,
                      premiumsPaid: premiumsPaid,
                      premiumCount: premiumCount,
                      sharesPaid: sharesPaid,
                      shareCount: shareCount,
                    ),
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
                                onPayNow: () => _handleDashboardPayNow(context),
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
                                onTap: scrollToPayments,
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
                              icon: Icons.savings_outlined,
                              label: s('buySharesTitle'),
                              subtitle: isActive
                                  ? s('buySharesServiceSub')
                                  : s('payShareToActivateSub'),
                              color: const Color(0xFF8B6914),
                              isFirst: false,
                              isLast: false,
                              onTap: () async {
                                final purchased = await Navigator.push<bool>(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => SharesScreen(
                                      memberId: memberId,
                                      memberName: name,
                                      isPending: !isActive,
                                    ),
                                  ),
                                );
                                if (purchased == true) {
                                  widget.onPaymentMade?.call();
                                  refresh();
                                }
                              },
                            ),
                            _QuickAction(
                              icon: Icons.crisis_alert,
                              label: s('deathEmergency'),
                              subtitle: s('deathEmergencySub'),
                              color: const Color(0xFFB71C1C),
                              isFirst: false,
                              isLast: false,
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
                            _QuickAction(
                              icon: Icons.language,
                              label: s('visitWebsite'),
                              subtitle: s('visitWebsiteSub'),
                              color: const Color(0xFF1A5C2A),
                              isFirst: false,
                              isLast: true,
                              onTap: () => launchUrl(
                                Uri.parse('https://kafayiti.com'),
                                mode: LaunchMode.externalApplication,
                              ),
                            ),
                          ]),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 20),

                    // ── Payment History ───────────────────────────────────────
                    SizedBox(
                      key: _payHistoryKey,
                      width: double.infinity,
                      child: _SectionCard(
                        title: s('paymentHistory'),
                        icon: Icons.history,
                        child: _buildPaymentHistoryList(context, locale, s),
                      ),
                    ),
                  ]),
            ),
          ),
        ),
      ],
    );
    } catch (e) {
      debugPrint('Dashboard tab build error: $e');
      final locale = context.read<LanguageProvider>().locale;
      String s(String key) => AppStrings.get(key, locale);
      return Scaffold(
        backgroundColor: _green,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.white),
              const SizedBox(height: 16),
              Text(s('errorOccurred'),
                  style: const TextStyle(fontSize: 16, color: Colors.white)),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _fetchPolicies,
                child: Text(s('retry')),
              ),
            ],
          ),
        ),
      );
    }
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
              icon: Icons.phone,
              label: s('callUs'),
              value: '(509) 3500-0326\n(509) 4439-8595\n(850) 321-4670'),
          const Divider(),
          _SupportTile(
              icon: Icons.email, label: s('email'), value: 'kontak@kafayiti.com'),
          const Divider(),
          _SupportTile(
              icon: Icons.access_time,
              label: s('hours'),
              value: s('hoursValue')),
        ]),
      ),
    );
  }

  Widget _buildPaymentHistoryList(
      BuildContext context, String locale, String Function(String) s) {
    final entries = <Map<String, dynamic>>[];

    for (final entry in _policies) {
      final pol = entry['policy'] as Map<String, dynamic>? ?? {};
      final policyNo = pol['policyNo'] as String? ?? '';
      final history = entry['paymentHistory'] as List<dynamic>? ?? [];
      for (final p in history) {
        final pm = p as Map<String, dynamic>;
        entries.add({
          'type': 'premium',
          'label': policyNo.isNotEmpty
              ? '${s('payPremium')} · $policyNo'
              : s('payPremium'),
          'date': pm['paymentDate'] as String? ?? '',
          'amount': (pm['amountPaid'] as num? ?? 0).toDouble(),
          'policyNo': policyNo,
          'period': pm['paymentPeriod'] as String? ?? '',
          'reference': pm['referenceNo'] as String? ?? '',
          'status': 'PAID',
        });
      }
    }

    for (final share in _shares) {
      final rawType = (share['shareType'] as String? ?? '').toLowerCase();
      entries.add({
        'type': 'share',
        'label': rawType == 'preferred'
            ? s('preferredShare')
            : s('membershipShare'),
        'date': share['datetime'] as String? ?? '',
        'amount': (share['amount'] as num? ?? 0).toDouble(),
        'shareType': rawType,
        'shareId': share['shareId'] as String? ?? '',
        'apr': (share['apr'] as num? ?? 0).toDouble(),
        'status': share['status'] as String? ?? '',
      });
    }

    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(s('noPaymentRecords'),
            style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
      );
    }

    entries.sort((a, b) =>
        (b['date'] as String).compareTo(a['date'] as String));

    return Column(
      children: entries.map((e) {
        final isPremium = e['type'] == 'premium';
        final amount = e['amount'] as double;
        final date = e['date'] as String;
        final label = e['label'] as String;
        final displayDate = date.length >= 10 ? date.substring(0, 10) : date;

        return InkWell(
          onTap: () => _showPaymentReceipt(context, e, locale, s),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isPremium
                      ? Colors.green.shade50
                      : const Color(0xFFF5F0E8),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isPremium ? Icons.shield_outlined : Icons.savings_outlined,
                  color: isPremium ? _green : const Color(0xFF8B6914),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A1A))),
                  if (displayDate.isNotEmpty)
                    Text(AppStrings.formatDate(displayDate, locale),
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500)),
                ]),
              ),
              Row(children: [
                Text('US\$${amount.toStringAsFixed(2)}',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: _green)),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right,
                    size: 16, color: Colors.grey.shade400),
              ]),
            ]),
          ),
        );
      }).toList(),
    );
  }

  void _showPaymentReceipt(BuildContext context, Map<String, dynamic> e,
      String locale, String Function(String) s) {
    final isPremium = e['type'] == 'premium';
    final amount = e['amount'] as double;
    final date = e['date'] as String;
    final status = e['status'] as String? ?? '';
    final displayDate =
        AppStrings.formatDate(date.length >= 10 ? date.substring(0, 10) : date, locale);

    final Color accentColor = isPremium ? _green : const Color(0xFF8B6914);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 36),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Drag handle
          Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 20),

          // Icon + title
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.1),
                shape: BoxShape.circle),
            child: Icon(
              isPremium ? Icons.shield_outlined : Icons.savings_outlined,
              color: accentColor,
              size: 28,
            ),
          ),
          const SizedBox(height: 12),
          Text(s('receiptTitle'),
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A1A))),
          const SizedBox(height: 4),
          Text('US\$${amount.toStringAsFixed(2)}',
              style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: accentColor)),
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 12),

          // Detail rows
          _ReceiptRow(label: s('paymentTypeLabel'), value: e['label'] as String),
          _ReceiptRow(label: s('dateLabel'), value: displayDate),
          if (isPremium) ...[
            if ((e['policyNo'] as String).isNotEmpty)
              _ReceiptRow(
                  label: s('policyPrefix'),
                  value: e['policyNo'] as String),
            if ((e['period'] as String).isNotEmpty)
              _ReceiptRow(
                  label: s('periodLabel'),
                  value: e['period'] as String),
            if ((e['reference'] as String).isNotEmpty)
              _ReceiptRow(
                  label: s('referenceLabel'),
                  value: e['reference'] as String),
          ] else ...[
            if ((e['shareId'] as String).isNotEmpty)
              _ReceiptRow(
                  label: s('referenceLabel'),
                  value: e['shareId'] as String),
            if ((e['apr'] as double) > 0)
              _ReceiptRow(
                  label: 'APR',
                  value: '${(e['apr'] as double).toStringAsFixed(2)}%'),
          ],
          if (status.isNotEmpty)
            _ReceiptRow(
                label: s('statusLabel'),
                value: status,
                valueColor: (status == 'PAID' || status == 'SUCCEEDED')
                    ? Colors.green.shade700
                    : Colors.orange.shade700),
          const SizedBox(height: 8),
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
  static const _chatUrl = String.fromEnvironment(
    'ASSISTANT_URL',
    defaultValue: 'https://4fnzfkwkn8.execute-api.us-east-1.amazonaws.com/default/kafa-assistant',
  );

  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<Map<String, String>> _history = [];
  final List<_ChatMsg> _messages = [];

  bool _expanded = false;
  bool _thinking = false;
  String? _sessionId;

  late final AnimationController _animCtrl;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _initSession();
  }

  Future<void> _initSession() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('member_chat_session');
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString('member_chat_session', id);
    }
    if (mounted) setState(() => _sessionId = id);
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
              'sessionId': _sessionId ?? 'member-anonymous',
              'conversationType': 'member_chat',
              'memberName': widget.member['full_name'] ?? '',
              'memberId': widget.member['memberId'] ?? '',
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
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
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
                Text(
                  s('chatHeader'),
                  style: const TextStyle(
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
  static const String _baseUrl = kApiBaseUrl;

  bool _loading = true;
  List<Map<String, dynamic>> _policies = [];
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _fetchPolicies();
    // Silently re-fetch so new payments/policies show up without a manual reload.
    _refreshTimer = Timer.periodic(
        const Duration(seconds: 20), (_) => _fetchPolicies(silent: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  /// [silent] is true for background polling refreshes, so the tab doesn't
  /// flash a full-screen loading spinner every time the timer fires.
  Future<void> _fetchPolicies({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final memberId = widget.member['memberId'] as String? ?? '';
    try {
      final uri = Uri.parse(
          '$_baseUrl${devPath('/member/policy')}?memberId=${Uri.encodeComponent(memberId)}');
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
                  sub: premiumAmount != '—' ? 'US\$$premiumAmount' : '',
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
                  sub: premiumAmount != '—' ? 'US\$$premiumAmount' : '',
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
                              text: 'US\$$premiumAmount',
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: _green)),
                        ]),
                      ),
                      const SizedBox(height: 16),
                    ],
                    ElevatedButton.icon(
                      icon: const Icon(Icons.payment),
                      label: Text(s('payNow')),
                      style: ElevatedButton.styleFrom(
                          backgroundColor:
                              paymentAccess ? _green : Colors.grey.shade400,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 52),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12))),
                      onPressed: !paymentAccess
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

  void _handlePayNow(BuildContext context, String Function(String) s) {
    if (_policies.length > 1) {
      _showPolicyPicker(context, s);
    } else {
      _navigateToPayment(context, s, _policies.first);
    }
  }

  void _showPolicyPicker(BuildContext context, String Function(String) s) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
                width: 36, height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(s('selectPolicyToPay'),
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 12),
            ..._policies.map((entry) {
              final pol = entry['policy'] as Map<String, dynamic>? ?? {};
              final policyNo = pol['policyNo'] as String? ?? '—';
              final productCode = pol['productCode'] as String? ?? '—';
              final premium = pol['premiumAmount']?.toString() ?? '—';
              return ListTile(
                leading: const Icon(Icons.policy_outlined, color: _green),
                title: Text(policyNo,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text('$productCode  ·  US\$$premium'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  _navigateToPayment(context, s, entry);
                },
              );
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _navigateToPayment(BuildContext context, String Function(String) s,
      Map<String, dynamic> entry) {
    final pol = entry['policy'] as Map<String, dynamic>? ?? {};
    final policyId = pol['policyNo'] as String? ?? '';
    final premiumRaw = pol['premiumAmount']?.toString() ?? '0';
    final nextDueDate = pol['nextDueDate'] as String? ?? '';
    final memberId = widget.member['memberId'] as String? ?? '';
    final memberName =
        (widget.member['full_name'] as String?)?.trim() ?? s('memberFallback');
    final amountCents = ((double.tryParse(premiumRaw) ?? 0) * 100).round();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PaymentScreen(
          args: PaymentArgs(
            memberId: memberId,
            policyId: policyId,
            memberName: memberName,
            amountCents: amountCents,
            periodStart: '',
            periodEnd: nextDueDate,
            currency: 'usd',
            productCode: pol['productCode'] as String?,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Reusable small widgets
// ─────────────────────────────────────────────────────────────────────────────

// ── Payments overview: premiums + share purchases, combined ──────────────────

class _PaymentsOverviewCard extends StatelessWidget {
  final bool loading;
  final double totalPaid;
  final int transactionCount;
  final double premiumsPaid;
  final int premiumCount;
  final double sharesPaid;
  final int shareCount;

  const _PaymentsOverviewCard({
    required this.loading,
    required this.totalPaid,
    required this.transactionCount,
    required this.premiumsPaid,
    required this.premiumCount,
    required this.sharesPaid,
    required this.shareCount,
  });

  String _money(double v) => '\$${v.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
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
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: const BoxDecoration(
                  color: Color(0xFFFFF8E1), shape: BoxShape.circle),
              child: const Icon(Icons.receipt_long_outlined,
                  color: Color(0xFF8B6914), size: 20),
            ),
            const SizedBox(width: 10),
            Text(s('paymentsOverview'),
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A1A1A))),
          ]),
          const SizedBox(height: 14),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: SizedBox(
                height: 18, width: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: _green),
              ),
            )
          else ...[
            Row(children: [
              Expanded(
                child: _PaymentStat(
                    label: s('totalPaid'), value: _money(totalPaid))),
              Expanded(
                child: _PaymentStat(
                    label: s('transactions'), value: '$transactionCount')),
            ]),
            if (transactionCount > 0) ...[
              const Divider(height: 24),
              Row(children: [
                Expanded(
                  child: _PaymentStat(
                    label: s('premiums'),
                    value: '${_money(premiumsPaid)} ($premiumCount)',
                    small: true,
                  ),
                ),
                Expanded(
                  child: _PaymentStat(
                    label: s('sharesTitle'),
                    value: '${_money(sharesPaid)} ($shareCount)',
                    small: true,
                  ),
                ),
              ]),
            ],
          ],
        ],
      ),
    );
  }
}

class _PaymentStat extends StatelessWidget {
  final String label;
  final String value;
  final bool small;

  const _PaymentStat({
    required this.label,
    required this.value,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: small ? 11 : 12, color: Colors.grey.shade500)),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontSize: small ? 13 : 18,
                fontWeight: FontWeight.bold,
                color: const Color(0xFF1A1A1A))),
      ],
    );
  }
}

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

  /// If the stored due date is today or in the past, advance to the 1st of
  /// the next month so the card always shows a future date.
  String get _effectiveDueDate {
    if (nextPayDate == '—' || nextPayDate.isEmpty) return nextPayDate;
    try {
      final due = DateTime.parse(nextPayDate);
      final today = DateTime.now();
      final todayDate = DateTime(today.year, today.month, today.day);
      if (!due.isAfter(todayDate)) {
        // Advance to 1st of next month
        final next = DateTime(today.year, today.month + 1, 1);
        return '${next.year}-${next.month.toString().padLeft(2, '0')}-01';
      }
      return nextPayDate;
    } catch (_) {
      return nextPayDate;
    }
  }

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);
    final displayDate = _effectiveDueDate;
    final hasDate   = displayDate   != '—' && displayDate.isNotEmpty;
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
          hasDate ? AppStrings.formatDate(displayDate, locale) : '—',
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1A1A1A)),
        ),
        const Spacer(),
        // Price + Pay Now button on the same row
        Row(children: [
          Text(
            hasAmount ? 'US\$$premiumAmount' : '—',
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
  final Widget? trailing;

  const _SectionCard(
      {required this.title, required this.icon, required this.child, this.trailing});

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
          if (trailing != null) ...[const Spacer(), trailing!],
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
//  Payment Success Banner (shown after Stripe Checkout redirect)
// ─────────────────────────────────────────────────────────────────────────────

class _PaymentSuccessBanner extends StatelessWidget {
  final String locale;
  final VoidCallback onSeeReceipt;
  final VoidCallback onDismiss;

  const _PaymentSuccessBanner({
    required this.locale,
    required this.onSeeReceipt,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    String s(String key) => AppStrings.get(key, locale);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: const Color(0xFF1A5C2A),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s('paymentSuccessTitle'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13),
                ),
                Text(
                  s('paymentSuccessSubtitle'),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onSeeReceipt,
            style: TextButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF1A5C2A),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6)),
            ),
            child: Text(s('seeReceipt'),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onDismiss,
            child: const Icon(Icons.close, color: Colors.white70, size: 18),
          ),
        ],
      ),
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
  static const _baseUrl = kApiBaseUrl;

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

    final rawAmount = notif['amountPaid']?.toString() ?? '—';
    final isUsd = (notif['currency'] as String? ?? 'usd').toLowerCase() == 'usd';
    final amount = rawAmount == '—' ? rawAmount : (isUsd ? 'US\$$rawAmount' : 'HTG $rawAmount');
    final rawDate = notif['paymentDate'] as String? ?? '—';
    final date = AppStrings.formatDateTime(rawDate, widget.locale);
    final policyNo = notif['policyNo'] as String? ?? '—';
    final method = notif['paymentMethod'] as String? ?? '—';
    final paymentPeriod = notif['paymentPeriod'] as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(top: 14, bottom: 4),
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
        _NotifRow(s('paymentTypeLabel'), policyNo),
        _NotifRow(s('methodLabel'), method),
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
  final void Function(Map<String, dynamic>) onMemberUpdated;
  final VoidCallback? onPaymentMade;

  const _ServicesTab({
    required this.member,
    required this.locale,
    required this.onMemberUpdated,
    this.onPaymentMade,
  });

  /// Re-fetches the member record after a share purchase.
  ///
  /// For a full membership payment the webhook activates the member
  /// (status → true). For a partial payment the webhook records
  /// membershipSharesPaid. Either way the webhook fires asynchronously
  /// after the Stripe confirmation resolves client-side, so we poll until
  /// one of those fields reflects the webhook result.
  Future<void> _refreshAfterSharePurchase() async {
    final memberId = member['memberId'] as String? ?? '';
    final companyId = member['companyId'] as String? ?? 'KAFA-001';
    if (memberId.isEmpty) return;
    // Snapshot the paid amount before the payment so we can detect a change.
    final previousPaid = double.tryParse(
            member['membershipSharesPaid']?.toString() ?? '') ??
        0.0;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        final uri = Uri.parse(
            '$kApiBaseUrl${devPath('/member/profile')}?memberId=${Uri.encodeComponent(memberId)}'
            '&companyId=${Uri.encodeComponent(companyId)}');
        final response = await http.get(uri);
        if (response.statusCode != 200) return;
        final data = json.decode(response.body) as Map<String, dynamic>;
        final fresh = data['member'] as Map<String, dynamic>?;
        if (fresh == null) return;
        fresh.remove('credentials');
        await SessionService.saveSession(fresh);
        onMemberUpdated(fresh);
        // Full payment: member activated.
        if (fresh['status'] == 'Active') break;
        // Partial payment: break when the webhook has updated the running total.
        final freshPaid = double.tryParse(
                fresh['membershipSharesPaid']?.toString() ?? '') ??
            0.0;
        if (freshPaid > previousPaid) break;
      } catch (_) {
        break;
      }
      if (attempt < 19) await Future.delayed(const Duration(seconds: 1));
    }
  }

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
              icon: Icons.phone,
              label: s('callUs'),
              value: '(509) 3500-0326\n(509) 4439-8595\n(850) 321-4670'),
          const Divider(),
          _SupportTile(
              icon: Icons.email, label: s('email'), value: 'kontak@kafayiti.com'),
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

        // Buy Shares card
        _ServiceCard(
          icon: Icons.savings_outlined,
          iconColor: const Color(0xFF8B6914),
          accentColor: const Color(0xFFFFF8E1),
          title: s('buySharesTitle'),
          subtitle: member['status'] != 'Active'
              ? s('payShareToActivateSub')
              : s('buySharesServiceSub'),
          onTap: () async {
            final purchased = await Navigator.push<bool>(
              context,
              MaterialPageRoute(
                builder: (_) => SharesScreen(
                  memberId: memberId,
                  memberName: member['full_name'] as String? ?? '',
                  isPending: member['status'] == 'Pending' &&
                      member['reason'] == 'Did not pay membership share',
                ),
              ),
            );
            if (purchased == true) {
              onPaymentMade?.call();
              _refreshAfterSharePurchase();
            }
          },
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

class _ProfileTab extends StatefulWidget {
  final Map<String, dynamic> member;
  final String locale;
  final Future<void> Function() onLogout;
  final void Function(Map<String, dynamic>) onMemberUpdated;

  const _ProfileTab({
    required this.member,
    required this.locale,
    required this.onLogout,
    required this.onMemberUpdated,
  });

  @override
  State<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<_ProfileTab> {
  static const String _baseUrl = kApiBaseUrl;

  bool _isEditing = false;
  bool _isSaving = false;
  String? _error;

  late TextEditingController _phoneCtrl;
  late TextEditingController _emailCtrl;
  late TextEditingController _addressCtrl;
  late TextEditingController _dobCtrl;
  late TextEditingController _idTypeCtrl;
  late TextEditingController _idNumberCtrl;

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  void _initControllers() {
    _phoneCtrl = TextEditingController(text: widget.member['phone'] as String? ?? '');
    _emailCtrl = TextEditingController(text: widget.member['email'] as String? ?? '');
    _addressCtrl = TextEditingController(text: widget.member['address'] as String? ?? '');
    _dobCtrl = TextEditingController(
        text: widget.member['date_of_birth'] as String? ??
            widget.member['dateOfBirth'] as String? ??
            '');
    _idTypeCtrl = TextEditingController(
        text: widget.member['identification_type'] as String? ??
            widget.member['identificationType'] as String? ??
            '');
    _idNumberCtrl = TextEditingController(
        text: widget.member['identification_number'] as String? ??
            widget.member['identificationNumber'] as String? ??
            '');
  }

  @override
  void didUpdateWidget(_ProfileTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isEditing && oldWidget.member != widget.member) {
      _initControllers();
    }
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _addressCtrl.dispose();
    _dobCtrl.dispose();
    _idTypeCtrl.dispose();
    _idNumberCtrl.dispose();
    super.dispose();
  }

  void _startEdit() {
    setState(() {
      _isEditing = true;
      _error = null;
    });
  }

  void _cancelEdit() {
    setState(() {
      _isEditing = false;
      _error = null;
      _initControllers();
    });
  }

  Future<void> _saveEdit() async {
    setState(() { _isSaving = true; _error = null; });
    try {
      final memberId = widget.member['memberId'] as String? ?? '';
      final companyId = widget.member['companyId'] as String? ?? 'KAFA-001';
      final uri = Uri.parse('$_baseUrl${devPath('/member/profile/update')}');
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'memberId': memberId,
          'companyId': companyId,
          'phone': _phoneCtrl.text.trim(),
          'email': _emailCtrl.text.trim(),
          'address': _addressCtrl.text.trim(),
          'date_of_birth': _dobCtrl.text.trim(),
          'identification_type': _idTypeCtrl.text.trim(),
          'identification_number': _idNumberCtrl.text.trim(),
        }),
      );
      final data = json.decode(response.body) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw Exception(data['error'] as String? ?? 'Failed to update profile');
      }
      final fresh = data['member'] as Map<String, dynamic>?;
      if (fresh != null) {
        await SessionService.saveSession(fresh);
        widget.onMemberUpdated(fresh);
      }
      if (mounted) setState(() { _isEditing = false; _isSaving = false; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          debugPrint('[MemberDashboard] save error: $e');
          _error = 'Something went wrong. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);
    final member = widget.member;

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
    final isActive = member['status'] == 'Active';
    final isPendingStatus = member['status'] == 'Pending';

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
                color: isActive
                    ? Colors.green.shade100
                    : isPendingStatus
                        ? Colors.amber.shade100
                        : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.circle,
                    size: 8,
                    color: isActive
                        ? Colors.green.shade700
                        : isPendingStatus
                            ? Colors.amber.shade700
                            : Colors.grey.shade500),
                const SizedBox(width: 6),
                Text(
                  isActive
                      ? s('activeMember')
                      : isPendingStatus
                          ? s('pendingMember')
                          : s('inactiveMember'),
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: isActive
                          ? Colors.green.shade700
                          : isPendingStatus
                              ? Colors.amber.shade700
                              : Colors.grey.shade600),
                ),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 24),

        if (_error != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 16),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(_error!,
                      style: const TextStyle(color: Colors.red, fontSize: 13))),
            ]),
          ),
        ],

        // Personal info
        _SectionCard(
          title: s('profileInfo'),
          icon: Icons.person_outline,
          trailing: _isEditing
              ? null
              : IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18, color: _green),
                  tooltip: s('editProfile'),
                  onPressed: _startEdit,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
          child: Column(children: [
            _OverviewRow(
                icon: Icons.badge_outlined,
                label: s('memberId'),
                value: memberId),
            _OverviewRow(
                icon: Icons.location_on_outlined,
                label: s('commune'),
                value: commune),
            if (_isEditing) ...[
              _ProfileEditField(
                  controller: _addressCtrl, label: s('address'), icon: Icons.home_outlined),
              const SizedBox(height: 10),
              _ProfileEditField(
                  controller: _phoneCtrl,
                  label: s('phone'),
                  icon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone),
              const SizedBox(height: 10),
              _ProfileEditField(
                  controller: _emailCtrl,
                  label: s('email'),
                  icon: Icons.email_outlined,
                  keyboardType: TextInputType.emailAddress),
              const SizedBox(height: 10),
              _ProfileEditField(
                  controller: _dobCtrl,
                  label: s('dateOfBirth'),
                  icon: Icons.cake_outlined,
                  hint: 'YYYY-MM-DD'),
            ] else ...[
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
            ],
          ]),
        ),
        const SizedBox(height: 16),

        // Identification
        _SectionCard(
          title: s('identification'),
          icon: Icons.fingerprint,
          trailing: _isEditing
              ? null
              : IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18, color: _green),
                  tooltip: s('editProfile'),
                  onPressed: _startEdit,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
          child: _isEditing
              ? Column(children: [
                  _ProfileEditField(
                      controller: _idTypeCtrl, label: s('idType'), icon: Icons.credit_card),
                  const SizedBox(height: 10),
                  _ProfileEditField(
                      controller: _idNumberCtrl, label: s('idNumber'), icon: Icons.numbers),
                ])
              : Column(children: [
                  _OverviewRow(
                      icon: Icons.credit_card, label: s('idType'), value: idType),
                  _OverviewRow(
                      icon: Icons.numbers, label: s('idNumber'), value: idNumber),
                ]),
        ),

        if (_isEditing) ...[
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _isSaving ? null : _cancelEdit,
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12)),
                child: Text(s('cancel')),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _isSaving ? null : _saveEdit,
                style: ElevatedButton.styleFrom(
                    backgroundColor: _green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12)),
                child: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : Text(s('save')),
              ),
            ),
          ]),
        ],

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
            onPressed: widget.onLogout,
          ),
        ),
      ]),
    );
  }
}

class _ProfileEditField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? hint;
  final TextInputType? keyboardType;

  const _ProfileEditField({
    required this.controller,
    required this.label,
    required this.icon,
    this.hint,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 20),
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
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

class _ReceiptRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _ReceiptRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: valueColor ?? const Color(0xFF1A1A1A))),
          ),
        ],
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
