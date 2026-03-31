import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../models/member.dart';
import 'member_detail_screen.dart';
import 'create_member_screen.dart';
import 'login_screen.dart';

class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key});

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  List<Member> _allMembers = [];
  List<Member> _filteredMembers = [];
  bool _isLoading = true;
  String? _error;
  final _searchController = TextEditingController();
  String _filterStatus = 'All'; // All, Active, Inactive (internal English keys)

  @override
  void initState() {
    super.initState();
    _loadMembers();
    _searchController.addListener(_filterMembers);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadMembers() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final api = context.read<AuthProvider>().apiService!;
      final members = await api.listMembers();
      members.sort((a, b) =>
          a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase()));
      setState(() {
        _allMembers = members;
        _isLoading = false;
      });
      _filterMembers();
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _filterMembers() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredMembers = _allMembers.where((m) {
        final matchesQuery = query.isEmpty ||
            m.fullName.toLowerCase().contains(query) ||
            m.memberId.toLowerCase().contains(query) ||
            m.phone.toLowerCase().contains(query) ||
            m.email.toLowerCase().contains(query) ||
            m.address.toLowerCase().contains(query);

        final matchesStatus = _filterStatus == 'All' ||
            (_filterStatus == 'Active' && m.status) ||
            (_filterStatus == 'Inactive' && !m.status);

        return matchesQuery && matchesStatus;
      }).toList();
    });
  }

  void _setFilter(String filter) {
    setState(() => _filterStatus = filter);
    _filterMembers();
  }

  void _logout() {
    context.read<AuthProvider>().logout();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  Future<void> _openCreateMember() async {
    final created = await Navigator.of(context).push<Member>(
      MaterialPageRoute(builder: (_) => const CreateMemberScreen()),
    );
    if (created != null) {
      setState(() => _allMembers.add(created));
      _filterMembers();
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);

    final activeCount = _allMembers.where((m) => m.status).length;
    final inactiveCount = _allMembers.where((m) => !m.status).length;

    // Filter display labels (translated) mapped to internal keys
    final filters = <String, String>{
      'All': s('all'),
      'Active': s('active'),
      'Inactive': s('inactive'),
    };

    return Scaffold(
      appBar: AppBar(
        title: Text(s('appBarTitle')),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                const Icon(Icons.person, size: 16, color: Colors.white70),
                const SizedBox(width: 4),
                Text(auth.adminUsername,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 13)),
              ],
            ),
          ),
          TextButton(
            onPressed: () => context.read<LanguageProvider>().toggle(),
            child: Text(
              locale == 'fr' ? '🇺🇸 EN' : '🇫🇷 FR',
              style: const TextStyle(
                color: Colors.white70,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: s('logout'),
            onPressed: _logout,
          ),
        ],
      ),
      body: Column(
        children: [
          // Stats banner
          Container(
            color: const Color(0xFF1A5C2A),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Row(
              children: [
                _StatChip(
                    label: s('total'),
                    value: _allMembers.length,
                    color: const Color(0xFFC8A96E)),
                const SizedBox(width: 12),
                _StatChip(
                    label: s('active'), value: activeCount, color: Colors.green),
                const SizedBox(width: 12),
                _StatChip(
                    label: s('inactive'),
                    value: inactiveCount,
                    color: Colors.red.shade400),
              ],
            ),
          ),

          // Search + filter bar
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.grey.shade100,
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: s('searchHint'),
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    suffixIcon: _searchController.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              _filterMembers();
                            },
                          )
                        : null,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: filters.entries.map((entry) {
                    final isSelected = _filterStatus == entry.key;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(entry.value),
                        selected: isSelected,
                        onSelected: (_) => _setFilter(entry.key),
                        selectedColor: const Color(0xFFC8A96E),
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.white : Colors.black87,
                          fontWeight: isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        checkmarkColor: Colors.white,
                      ),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

          // Results count
          if (!_isLoading && _error == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${_filteredMembers.length} ${s('membersFound')}',
                  style: TextStyle(
                      color: Colors.grey.shade600, fontSize: 13),
                ),
              ),
            ),

          // Member list
          Expanded(child: _buildBody(s)),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'refresh',
            onPressed: _loadMembers,
            backgroundColor: const Color(0xFFC8A96E),
            tooltip: s('refresh'),
            child: const Icon(Icons.refresh, color: Colors.white),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'create',
            onPressed: _openCreateMember,
            backgroundColor: const Color(0xFF1A5C2A),
            icon: const Icon(Icons.person_add, color: Colors.white),
            label: Text(s('newMember'),
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(String Function(String) s) {
    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(color: Color(0xFFC8A96E)),
            const SizedBox(height: 16),
            Text(s('loadingMembers'), style: const TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(s('errorLoadingMembers'),
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _loadMembers,
                icon: const Icon(Icons.refresh),
                label: Text(s('retry')),
              ),
            ],
          ),
        ),
      );
    }

    if (_filteredMembers.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_outline, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(s('noMembersFound'),
                style: TextStyle(
                    color: Colors.grey.shade500, fontSize: 16)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _filteredMembers.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final member = _filteredMembers[index];
        return _MemberCard(
          member: member,
          onTap: () async {
            final updated = await Navigator.of(context).push<Member>(
              MaterialPageRoute(
                builder: (_) => MemberDetailScreen(member: member, allMembers: _allMembers),
              ),
            );
            if (updated != null) {
              setState(() {
                final idx =
                    _allMembers.indexWhere((m) => m.memberId == updated.memberId);
                if (idx != -1) _allMembers[idx] = updated;
              });
              _filterMembers();
            }
          },
        );
      },
    );
  }
}

// ── Member Card ───────────────────────────────────────────────────────────────

class _MemberCard extends StatelessWidget {
  final Member member;
  final VoidCallback onTap;

  const _MemberCard({required this.member, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Avatar
              CircleAvatar(
                radius: 24,
                backgroundColor: member.status
                    ? const Color(0xFFC8A96E).withOpacity(0.15)
                    : Colors.grey.shade200,
                child: Text(
                  member.fullName.isNotEmpty
                      ? member.fullName[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    color: member.status
                        ? const Color(0xFFC8A96E)
                        : Colors.grey,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
              const SizedBox(width: 16),

              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      member.fullName,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      member.memberId,
                      style: TextStyle(
                          color: Colors.grey.shade500, fontSize: 12),
                    ),
                    if (member.phone.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(Icons.phone,
                              size: 12, color: Colors.grey.shade400),
                          const SizedBox(width: 4),
                          Text(member.phone,
                              style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 12)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),

              // Status badge
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: member.status
                          ? Colors.green.shade50
                          : Colors.red.shade50,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: member.status
                            ? Colors.green.shade300
                            : Colors.red.shade300,
                      ),
                    ),
                    child: Text(
                      member.status ? s('active') : s('inactive'),
                      style: TextStyle(
                        color: member.status
                            ? Colors.green.shade700
                            : Colors.red.shade700,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Icon(Icons.chevron_right,
                      color: Colors.grey, size: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Stat Chip ─────────────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final String label;
  final int value;
  final Color color;

  const _StatChip(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        children: [
          Text(
            '$value',
            style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 16),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  color: color.withOpacity(0.8), fontSize: 12)),
        ],
      ),
    );
  }
}
