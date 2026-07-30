import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../models/member.dart';

const _green = Color(0xFF1A5C2A);
const _gold  = Color(0xFFC8A96E);
const _bg    = Color(0xFFF2F4F7);

/// Reports tab — implements the report sections from the KAFA reporting spec.
/// Section 1 (registrations) and the Monthly Dashboard (section 6) are computed
/// from real member/prospect data. Sections 2-5 require infrastructure this app
/// doesn't have yet (payments, web analytics, support tickets, auth logs), so
/// they render with "Not yet tracked" placeholders.
class ReportsScreen extends StatefulWidget {
  final bool embedded;
  const ReportsScreen({super.key, this.embedded = false});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  List<Member> _members = [];
  List<Map<String, dynamic>> _prospects = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final api = context.read<AuthProvider>().apiService!;
      final results = await Future.wait([
        api.listMembers(),
        api.getProspects(),
      ]);
      setState(() {
        _members   = results[0] as List<Member>;
        _prospects = results[1] as List<Map<String, dynamic>>;
        _loading   = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    final body = _loading
        ? const Center(child: CircularProgressIndicator(color: _green))
        : RefreshIndicator(
            color: _green,
            onRefresh: _load,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s('reportsTitle'),
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _green)),
                const SizedBox(height: 16),
                _RegistrationReport(members: _members, prospects: _prospects),
                const SizedBox(height: 24),
                _PlaceholderReport(
                  title: s('section2Title'),
                  subtitle: s('section2Subtitle'),
                  rows: [
                    s('paymentsReceived'),
                    s('totalAmountCollected'),
                    s('pendingPayments'),
                    s('declinedPayments'),
                    s('availableBalance'),
                  ],
                ),
                const SizedBox(height: 24),
                _PlaceholderReport(
                  title: s('section3Title'),
                  subtitle: s('section3Subtitle'),
                  rows: [
                    s('numberOfVisitors'),
                    s('avgTimeOnSite'),
                    s('visitorOrigin'),
                    s('devicesUsed'),
                    s('startedRegistration'),
                    s('completedRegistration'),
                  ],
                ),
                const SizedBox(height: 24),
                _PlaceholderReport(
                  title: s('section4Title'),
                  rows: [
                    s('requestsReceived'),
                    s('numberOfComplaints'),
                    s('avgResponseTime'),
                    s('issuesResolved'),
                  ],
                ),
                const SizedBox(height: 24),
                _PlaceholderReport(
                  title: s('section5Title'),
                  rows: [
                    s('suspiciousLogins'),
                    s('blockedAccounts'),
                    s('backupsPerformed'),
                    s('systemErrors'),
                    s('siteAvailability'),
                  ],
                ),
              ]),
            ),
          );

    if (widget.embedded) return Container(color: _bg, child: body);
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(backgroundColor: _green, title: Text(s('reportsTitle'))),
      body: body,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  1. Member Registration Report — computed from real data
// ─────────────────────────────────────────────────────────────────────────────

class _RegistrationReport extends StatelessWidget {
  final List<Member> members;
  final List<Map<String, dynamic>> prospects;
  const _RegistrationReport({required this.members, required this.prospects});

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);
    final total = prospects.length;
    int countStatus(String s) => prospects
        .where((p) => (p['status'] as String? ?? 'pending').toLowerCase() == s)
        .length;
    final validated = countStatus('accepted');
    final pending    = prospects
        .where((p) {
          final s = (p['status'] as String? ?? '').toLowerCase();
          return s.isEmpty || s == 'new' || s == 'pending';
        })
        .length;
    final rejected = countStatus('rejected');

    final male   = members.where((m) => m.sex.toLowerCase() == 'm' || m.sex.toLowerCase() == 'male').length;
    final female = members.where((m) => m.sex.toLowerCase() == 'f' || m.sex.toLowerCase() == 'female').length;
    final unspecifiedSex = members.length - male - female;

    final under18 = s('under18');
    final age51Plus = s('age51Plus');
    final unknownLabel = s('unknownLabel');
    final ageBuckets = <String, int>{under18: 0, '18-30': 0, '31-50': 0, age51Plus: 0, unknownLabel: 0};
    for (final m in members) {
      final age = _ageFromDob(m.dateOfBirth);
      if (age == null) {
        ageBuckets[unknownLabel] = ageBuckets[unknownLabel]! + 1;
      } else if (age < 18) {
        ageBuckets[under18] = ageBuckets[under18]! + 1;
      } else if (age <= 30) {
        ageBuckets['18-30'] = ageBuckets['18-30']! + 1;
      } else if (age <= 50) {
        ageBuckets['31-50'] = ageBuckets['31-50']! + 1;
      } else {
        ageBuckets[age51Plus] = ageBuckets[age51Plus]! + 1;
      }
    }

    final communeCounts = <String, int>{};
    for (final m in members) {
      final commune = m.communeName.isNotEmpty ? m.communeName : unknownLabel;
      communeCounts[commune] = (communeCounts[commune] ?? 0) + 1;
    }
    final sortedCommunes = communeCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final monthlyTrend = <String, int>{};
    for (final p in prospects) {
      final raw = p['createdAt'] as String? ?? '';
      if (raw.length < 7) continue;
      final month = raw.substring(0, 7); // YYYY-MM
      monthlyTrend[month] = (monthlyTrend[month] ?? 0) + 1;
    }
    final sortedMonths = monthlyTrend.keys.toList()..sort();

    return ReportCard(
      title: s('section1Title'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _kv(s('totalRegistrations'), '$total'),
        _kv(s('validatedRegistrations'), '$validated'),
        _kv(s('pendingRegistrations'), '$pending'),
        _kv(s('rejectedRegistrations'), '$rejected'),
        const Divider(height: 20),
        Text(s('breakdownByGender'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        _kv(s('male'), '$male'),
        _kv(s('female'), '$female'),
        _kv(s('unspecified'), '$unspecifiedSex'),
        const Divider(height: 20),
        Text(s('breakdownByAge'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        ...ageBuckets.entries.map((e) => _kv(e.key, '${e.value}')),
        const Divider(height: 20),
        Text(s('breakdownByCommune'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        if (sortedCommunes.isEmpty)
          Text(s('noData'), style: TextStyle(fontSize: 12, color: Colors.grey.shade500))
        else
          ...sortedCommunes.take(8).map((e) => _kv(e.key, '${e.value}')),
        const Divider(height: 20),
        Text(s('monthlyTrendRegistrations'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        if (sortedMonths.isEmpty)
          Text(s('noData'), style: TextStyle(fontSize: 12, color: Colors.grey.shade500))
        else
          ...sortedMonths.map((m) => _kv(m, '${monthlyTrend[m]}')),
      ]),
    );
  }

  static int? _ageFromDob(String dob) {
    if (dob.isEmpty) return null;
    final parsed = DateTime.tryParse(dob);
    if (parsed == null) return null;
    final now = DateTime.now();
    int age = now.year - parsed.year;
    if (now.month < parsed.month || (now.month == parsed.month && now.day < parsed.day)) {
      age--;
    }
    return age;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  6. Monthly Dashboard — derived from members/prospects where possible
// ─────────────────────────────────────────────────────────────────────────────

class MonthlyDashboard extends StatelessWidget {
  final List<Member> members;
  final List<Map<String, dynamic>> prospects;
  const MonthlyDashboard({super.key, required this.members, required this.prospects});

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String tr(String key) => AppStrings.get(key, locale);
    final now = DateTime.now();
    final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';

    final newMembersThisMonth = prospects.where((p) {
      final raw = p['createdAt'] as String? ?? '';
      return raw.startsWith(monthKey);
    }).length;

    final validatedMembers = prospects
        .where((p) => (p['status'] as String? ?? '').toLowerCase() == 'accepted')
        .length;
    final pendingMembers = prospects.where((p) {
      final st = (p['status'] as String? ?? '').toLowerCase();
      return st.isEmpty || st == 'new' || st == 'pending';
    }).length;

    final notYetTracked = tr('notYetTracked');
    return ReportCard(
      title: tr('section6Title'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _kv(tr('newMembersRegistered'), '$newMembersThisMonth'),
        _kv(tr('validatedMembersCount'), '$validatedMembers'),
        _kv(tr('pendingMembersCount'), '$pendingMembers'),
        _kv(tr('siteVisitors'), notYetTracked),
        _kv(tr('contributionsCollected'), notYetTracked),
        _kv(tr('policiesTakenOut'), notYetTracked),
        _kv(tr('claimsReceived'), notYetTracked),
        _kv(tr('claimsProcessed'), notYetTracked),
        _kv(tr('numberOfComplaints'), notYetTracked),
        _kv(tr('systemSecurityStatus'), notYetTracked),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Shared widgets
// ─────────────────────────────────────────────────────────────────────────────

class _PlaceholderReport extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<String> rows;
  const _PlaceholderReport({required this.title, this.subtitle, required this.rows});

  @override
  Widget build(BuildContext context) {
    final notYetTracked = AppStrings.get('notYetTracked', context.watch<LanguageProvider>().locale);
    return ReportCard(
      title: title,
      subtitle: subtitle,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start,
          children: rows.map((r) => _kv(r, notYetTracked)).toList()),
    );
  }
}

class ReportCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const ReportCard({super.key, required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _green)),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(subtitle!, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        ],
        const SizedBox(height: 12),
        child,
      ]),
    );
  }
}

Widget _kv(String label, String value) {
  final isPlaceholder = value == 'Not yet tracked';
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
      const SizedBox(width: 8),
      Text(value,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: isPlaceholder ? Colors.grey.shade400 : _gold,
              fontStyle: isPlaceholder ? FontStyle.italic : FontStyle.normal)),
    ]),
  );
}
