import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../models/member.dart';
import 'login_screen.dart';
import 'member_detail_screen.dart';
import 'create_member_screen.dart';
import 'prospects_screen.dart';
import 'chats_screen.dart';
import 'reports_screen.dart' show ReportsScreen, MonthlyDashboard;
// ignore: avoid_web_libraries_in_flutter

const _green = Color(0xFF1A5C2A);
const _gold  = Color(0xFFC8A96E);
const _bg    = Color(0xFFF2F4F7);

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  int _tab = 0;
  String? _deepLinkProspectId;
  String _memberFilter = 'All';

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      final uri = Uri.base;
      final id = uri.queryParameters['prospect'];
      if (id != null && id.isNotEmpty) {
        _deepLinkProspectId = id;
        _tab = 2;
        // Remove the query parameter so refreshing doesn't re-trigger the deep link
        // Deep link consumed — no history manipulation needed on mobile
      }
    }
  }

  void _logout() async {
    await context.read<AuthProvider>().logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    final currentLang = LanguageProvider.supportedLanguages
        .firstWhere((l) => l['code'] == locale,
            orElse: () => LanguageProvider.supportedLanguages.first);

    final tabs = [
      _OverviewTab(
        locale: locale,
        onGoMembers: () => setState(() { _memberFilter = 'All'; _tab = 1; }),
        onGoActiveMembers: () => setState(() { _memberFilter = 'Active'; _tab = 1; }),
        onGoInactiveMembers: () => setState(() { _memberFilter = 'Inactive'; _tab = 1; }),
        onGoProspects: () => setState(() => _tab = 2),
      ),
      _MembersTab(locale: locale, initialFilter: _memberFilter),
      ProspectsScreen(embedded: true, locale: locale, deepLinkId: _deepLinkProspectId),
      ChatsScreen(embedded: true, locale: locale),
      const ReportsScreen(embedded: true),
    ];

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _green,
        automaticallyImplyLeading: false,
        title: Row(children: [
          Image.asset('assets/images/kafa_logo.png', height: 32),
          const SizedBox(width: 10),
          const Text('KAFA Admin',
              style: TextStyle(
                  color: _gold, fontSize: 18, fontWeight: FontWeight.bold)),
        ]),
        actions: [
          // Language toggle
          PopupMenuButton<String>(
            offset: const Offset(0, 48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            tooltip: AppStrings.get('languageTooltip', locale),
            onSelected: (code) =>
                context.read<LanguageProvider>().setLocale(code),
            itemBuilder: (_) => [
              PopupMenuItem<String>(
                enabled: false,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Row(children: [
                  const Icon(Icons.language, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Text(currentLang['label'] ?? '',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ]),
              ),
              ...LanguageProvider.supportedLanguages.map((lang) =>
                  PopupMenuItem<String>(
                    value: lang['code'],
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
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
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.language, color: Colors.white, size: 20),
                const SizedBox(width: 4),
                Text(
                  (currentLang['code'] ?? 'EN').toUpperCase(),
                  style: const TextStyle(
                      color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ]),
            ),
          ),
          // Logout
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white),
            tooltip: AppStrings.get('logout', locale),
            onPressed: _logout,
          ),
        ],
      ),
      body: IndexedStack(index: _tab, children: tabs),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _tab,
        onTap: (i) => setState(() => _tab = i),
        selectedItemColor: _green,
        unselectedItemColor: Colors.grey.shade500,
        backgroundColor: Colors.white,
        elevation: 12,
        type: BottomNavigationBarType.fixed,
        selectedFontSize: 11,
        unselectedFontSize: 11,
        items: [
          BottomNavigationBarItem(
              icon: const Icon(Icons.dashboard_outlined),
              activeIcon: const Icon(Icons.dashboard),
              label: AppStrings.get('adminDashboard', locale)),
          BottomNavigationBarItem(
              icon: const Icon(Icons.people_outline),
              activeIcon: const Icon(Icons.people),
              label: AppStrings.get('adminMembers', locale)),
          BottomNavigationBarItem(
              icon: const Icon(Icons.person_search_outlined),
              activeIcon: const Icon(Icons.person_search),
              label: AppStrings.get('adminProspects', locale)),
          BottomNavigationBarItem(
              icon: const Icon(Icons.chat_bubble_outline),
              activeIcon: const Icon(Icons.chat_bubble),
              label: AppStrings.get('chats', locale)),
          BottomNavigationBarItem(
              icon: const Icon(Icons.bar_chart_outlined),
              activeIcon: const Icon(Icons.bar_chart),
              label: AppStrings.get('reportsNav', locale)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Overview tab
// ─────────────────────────────────────────────────────────────────────────────

class _OverviewTab extends StatefulWidget {
  final String locale;
  final VoidCallback onGoMembers;
  final VoidCallback onGoActiveMembers;
  final VoidCallback onGoInactiveMembers;
  final VoidCallback onGoProspects;
  const _OverviewTab({
    required this.locale,
    required this.onGoMembers,
    required this.onGoActiveMembers,
    required this.onGoInactiveMembers,
    required this.onGoProspects,
  });

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
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
    final locale = widget.locale;
    String s(String k) => AppStrings.get(k, locale);
    final activeCount   = _members.where((m) => m.status == 'Active').length;
    final inactiveCount = _members.length - activeCount;

    return RefreshIndicator(
      color: _green,
      onRefresh: _load,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s('adminOverview'),
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: _green)),
          const SizedBox(height: 16),

          if (_loading)
            const Center(child: Padding(
              padding: EdgeInsets.all(32),
              child: CircularProgressIndicator(color: _green),
            ))
          else ...[
            Row(children: [
              Expanded(child: _StatCard(label: s('adminTotalMembers'), value: '${_members.length}', icon: Icons.people, color: _green, onTap: widget.onGoMembers)),
              const SizedBox(width: 12),
              Expanded(child: _StatCard(label: s('active'), value: '$activeCount', icon: Icons.check_circle_outline, color: Colors.green.shade600, onTap: widget.onGoActiveMembers)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _StatCard(label: s('inactive'), value: '$inactiveCount', icon: Icons.remove_circle_outline, color: Colors.orange, onTap: widget.onGoInactiveMembers)),
              const SizedBox(width: 12),
              Expanded(child: _StatCard(label: s('adminProspects'), value: '${_prospects.length}', icon: Icons.person_search, color: _gold, onTap: widget.onGoProspects)),
            ]),
            const SizedBox(height: 28),

            MonthlyDashboard(members: _members, prospects: _prospects),
            const SizedBox(height: 28),

            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(s('adminRecentProspects'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              TextButton(onPressed: widget.onGoProspects, child: Text(s('adminSeeAll'), style: const TextStyle(color: _green, fontSize: 12))),
            ]),
            const SizedBox(height: 8),
            if (_prospects.isEmpty)
              Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(s('adminNoProspects'), style: TextStyle(color: Colors.grey.shade500))))
            else
              ...(_prospects.take(5).map((p) => _RecentProspectRow(prospect: p))),

            const SizedBox(height: 28),

            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(s('adminRecentMembers'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              TextButton(onPressed: widget.onGoMembers, child: Text(s('adminSeeAll'), style: const TextStyle(color: _green, fontSize: 12))),
            ]),
            const SizedBox(height: 8),
            if (_members.isEmpty)
              Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(s('noMembersFound'), style: TextStyle(color: Colors.grey.shade500))))
            else
              ...(_members.take(5).map((m) => _RecentMemberRow(member: m, locale: locale))),
          ],
        ]),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.04),
                blurRadius: 8,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Row(children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value,
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.bold, color: color)),
            Text(label,
                style:
                    TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ]),
        ]),
      ),
    );
  }
}

class _RecentProspectRow extends StatelessWidget {
  final Map<String, dynamic> prospect;
  const _RecentProspectRow({required this.prospect});

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    final first = prospect['firstName'] as String? ?? '';
    final last  = prospect['lastName']  as String? ?? '';
    final name  = '$first $last'.trim();
    final phone = prospect['phone'] as String? ?? '—';
    final raw   = prospect['createdAt'] as String? ?? '';
    final date  = raw.length >= 10 ? raw.substring(0, 10) : raw;
    final init  = '${first.isNotEmpty ? first[0] : ''}${last.isNotEmpty ? last[0] : ''}'.toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: _gold.withValues(alpha: 0.12),
          child: Text(init.isEmpty ? '?' : init,
              style: const TextStyle(
                  color: _gold, fontWeight: FontWeight.bold, fontSize: 12)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.isEmpty ? AppStrings.get('noName', locale) : name,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
            Text(phone,
                style:
                    TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ]),
        ),
        Text(date, style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
      ]),
    );
  }
}

class _RecentMemberRow extends StatelessWidget {
  final Member member;
  final String locale;
  const _RecentMemberRow({required this.member, required this.locale});

  @override
  Widget build(BuildContext context) {
    final parts = member.fullName.trim().split(' ');
    final init  = parts.map((p) => p.isNotEmpty ? p[0] : '').take(2).join().toUpperCase();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: _green.withValues(alpha: 0.1),
          child: Text(init.isEmpty ? '?' : init,
              style: const TextStyle(
                  color: _green, fontWeight: FontWeight.bold, fontSize: 12)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(member.fullName,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
            Text(member.memberId,
                style:
                    TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ]),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: member.status == 'Active'
                ? Colors.green.shade50
                : Colors.orange.shade50,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            member.status == 'Active' ? AppStrings.get('active', locale) : AppStrings.get('inactive', locale),
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: member.status == 'Active'
                  ? Colors.green.shade700
                  : Colors.orange.shade700,
            ),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Members tab — lifted from MembersScreen, embedded without its own AppBar
// ─────────────────────────────────────────────────────────────────────────────

class _MembersTab extends StatefulWidget {
  final String locale;
  final String initialFilter;
  const _MembersTab({required this.locale, this.initialFilter = 'All'});

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  List<Member> _all = [];
  List<Member> _filtered = [];
  bool _loading = true;
  String? _error;
  final _searchCtrl = TextEditingController();
  late String _statusFilter;

  @override
  void initState() {
    super.initState();
    _statusFilter = widget.initialFilter;
    _load();
    _searchCtrl.addListener(_filter);
  }

  @override
  void didUpdateWidget(_MembersTab old) {
    super.didUpdateWidget(old);
    if (widget.initialFilter != old.initialFilter) {
      setState(() => _statusFilter = widget.initialFilter);
      _filter();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = context.read<AuthProvider>().apiService!;
      final members = await api.listMembers();
      members.sort((a, b) =>
          a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
      setState(() { _all = members; _loading = false; });
      _filter();
    } catch (e) {
      debugPrint('[AdminDashboard] load error: $e');
      setState(() { _error = 'Something went wrong. Please try again.'; _loading = false; });
    }
  }

  void _filter() {
    final q = _searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = _all.where((m) {
        final matchesQ = q.isEmpty ||
            m.fullName.toLowerCase().contains(q) ||
            m.memberId.toLowerCase().contains(q) ||
            m.phone.toLowerCase().contains(q);
        final matchesS = _statusFilter == 'All' ||
            (_statusFilter == 'Active' && m.status == 'Active') ||
            (_statusFilter == 'Inactive' && m.status != 'Active');
        return matchesQ && matchesS;
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final locale = widget.locale;
    String s(String k) => AppStrings.get(k, locale);
    return Container(
      color: _bg,
      child: Column(children: [
        // Search + filter bar
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(children: [
            TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: s('adminSearchMembers'),
                hintStyle:
                    TextStyle(fontSize: 14, color: Colors.grey.shade400),
                prefixIcon:
                    const Icon(Icons.search, color: _green, size: 20),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => _searchCtrl.clear(),
                      )
                    : null,
                filled: true,
                fillColor: _bg,
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              _filterChip('All', s('all')),
              const SizedBox(width: 8),
              _filterChip('Active', s('active')),
              const SizedBox(width: 8),
              _filterChip('Inactive', s('inactive')),
              const Spacer(),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: _green,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8)),
                onPressed: _openCreate,
                icon: const Icon(Icons.add, size: 16),
                label: Text(s('adminAdd'), style: const TextStyle(fontSize: 13)),
              ),
            ]),
          ]),
        ),
        Expanded(child: _buildList()),
      ]),
    );
  }

  Widget _filterChip(String key, String displayLabel) {
    final active = _statusFilter == key;
    return GestureDetector(
      onTap: () {
        setState(() => _statusFilter = key);
        _filter();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: active ? _green : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(displayLabel,
            style: TextStyle(
                fontSize: 12,
                color: active ? Colors.white : Colors.grey.shade600,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      ),
    );
  }

  Widget _buildList() {
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
        child: Text(
          _searchCtrl.text.isEmpty ? s('noMembersFound') : s('noMembersFound'),
          style: TextStyle(color: Colors.grey.shade500),
        ),
      );
    }
    return RefreshIndicator(
      color: _green,
      onRefresh: _load,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: _filtered.length,
        itemBuilder: (_, i) {
          final m = _filtered[i];
          final parts = m.fullName.trim().split(' ');
          final init  = parts
              .map((p) => p.isNotEmpty ? p[0] : '')
              .take(2)
              .join()
              .toUpperCase();
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            elevation: 0,
            color: Colors.white,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => MemberDetailScreen(
                            member: m,
                            allMembers: _all,
                          )),
                );
                _load();
              },
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: _green.withValues(alpha: 0.1),
                    child: Text(init.isEmpty ? '?' : init,
                        style: const TextStyle(
                            color: _green,
                            fontWeight: FontWeight.bold,
                            fontSize: 14)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          Text(m.fullName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14)),
                          const SizedBox(height: 2),
                          Text(m.memberId,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade500)),
                          if (m.phone.isNotEmpty)
                            Text(m.phone,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.grey.shade500)),
                        ]),
                  ),
                  Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: m.status == 'Active'
                                ? Colors.green.shade50
                                : Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            m.status == 'Active' ? AppStrings.get('active', widget.locale) : AppStrings.get('inactive', widget.locale),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: m.status == 'Active'
                                  ? Colors.green.shade700
                                  : Colors.orange.shade700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Icon(Icons.chevron_right,
                            color: _green, size: 18),
                      ]),
                ]),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openCreate() async {
    final created = await Navigator.of(context).push<Member>(
      MaterialPageRoute(builder: (_) => const CreateMemberScreen()),
    );
    if (created != null) {
      setState(() => _all.add(created));
      _filter();
    }
  }
}
