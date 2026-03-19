import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import 'landing_screen.dart';
import 'chatbot_widget.dart';

class MemberDashboardScreen extends StatefulWidget {
  final Map<String, dynamic> member;
  const MemberDashboardScreen({super.key, required this.member});

  @override
  State<MemberDashboardScreen> createState() => _MemberDashboardScreenState();
}

class _MemberDashboardScreenState extends State<MemberDashboardScreen>
    with SingleTickerProviderStateMixin {
  // Default to chatbot view on login
  bool _showChatbot = true;
  late final AnimationController _toggleAnim;
  late final Animation<double> _fadeAnim;

  @override
  void initState() {
    super.initState();
    _toggleAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: 1.0,
    );
    _fadeAnim = CurvedAnimation(parent: _toggleAnim, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _toggleAnim.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    await _toggleAnim.reverse();
    setState(() => _showChatbot = !_showChatbot);
    _toggleAnim.forward();
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String key) => AppStrings.get(key, locale);

    final name = widget.member['full_name'] ?? '';
    final status = widget.member['status'];
    final isActive = status == true || status == 'true';

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: CustomScrollView(
        slivers: [
          // ── Header ────────────────────────────────────────────────────────
          SliverAppBar(
            expandedHeight: 72,
            toolbarHeight: 72,
            pinned: true,
            automaticallyImplyLeading: false,
            backgroundColor: const Color(0xFF1A5C2A),
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF1A5C2A), Color(0xFF2E7D45)],
                  ),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // ── Left: KAFA logo + wordmark ────────────────────────
                        Image.asset(
                          'assets/images/kafa_logo.png',
                          width: 26,
                          height: 26,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.shield,
                            color: Color(0xFFC8A96E),
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'KAFA',
                          style: TextStyle(
                            color: Color(0xFFC8A96E),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 2.5,
                          ),
                        ),

                        const Spacer(),

                        // ── Right: Profile dropdown ───────────────────────────
                        PopupMenuButton<String>(
                          onSelected: (value) {
                            if (value == 'profile') {
                              _toggle();
                            } else if (value == 'language') {
                              context.read<LanguageProvider>().toggle();
                            } else if (value == 'logout') {
                              Navigator.of(context).pushAndRemoveUntil(
                                MaterialPageRoute(
                                    builder: (_) => const LandingScreen()),
                                (_) => false,
                              );
                            }
                          },
                          color: Colors.white,
                          elevation: 8,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          offset: const Offset(0, 52),
                          itemBuilder: (_) => [
                            // ── Status (non-interactive) ──────────────────────
                            PopupMenuItem<String>(
                              enabled: false,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              child: Row(children: [
                                Container(
                                  width: 9,
                                  height: 9,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: isActive
                                        ? Colors.green.shade600
                                        : Colors.grey.shade500,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  isActive
                                      ? s('activeMember')
                                      : s('inactiveMember'),
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: isActive
                                        ? Colors.green.shade700
                                        : Colors.grey.shade600,
                                  ),
                                ),
                              ]),
                            ),
                            const PopupMenuDivider(),
                            // ── View profile / Open assistant ─────────────────
                            PopupMenuItem<String>(
                              value: 'profile',
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              child: Row(children: [
                                Icon(
                                  _showChatbot
                                      ? Icons.dashboard_rounded
                                      : Icons.chat_bubble_outline_rounded,
                                  size: 18,
                                  color: const Color(0xFF1A5C2A),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  _showChatbot
                                      ? s('chatbotToggleDashboard')
                                      : s('chatbotToggleChat'),
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF1A1A1A)),
                                ),
                              ]),
                            ),
                            // ── Language toggle ───────────────────────────────
                            PopupMenuItem<String>(
                              value: 'language',
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              child: Row(children: [
                                Text(
                                  locale == 'fr' ? '🇺🇸' : '🇫🇷',
                                  style: const TextStyle(fontSize: 16),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  locale == 'fr' ? 'English' : 'Français',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: Color(0xFF1A1A1A)),
                                ),
                              ]),
                            ),
                            const PopupMenuDivider(),
                            // ── Logout ────────────────────────────────────────
                            PopupMenuItem<String>(
                              value: 'logout',
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              child: Row(children: [
                                Icon(Icons.logout,
                                    size: 18, color: Colors.red.shade400),
                                const SizedBox(width: 10),
                                Text(
                                  s('logout'),
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.red.shade400),
                                ),
                              ]),
                            ),
                          ],
                          // ── Trigger: avatar + name + chevron ─────────────────
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 12),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircleAvatar(
                                  radius: 18,
                                  backgroundColor: const Color(0xFFC8A96E),
                                  child: Text(
                                    name.isNotEmpty
                                        ? name[0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(maxWidth: 150),
                                  child: Text(
                                    name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                const Icon(Icons.keyboard_arrow_down,
                                    color: Colors.white70, size: 18),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── Body (animated fade between chatbot and dashboard) ─────────────
          SliverFillRemaining(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: _showChatbot
                  ? ChatbotWidget(
                      member: widget.member,
                      locale: locale,
                    )
                  : _DashboardBody(member: widget.member, locale: locale),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Dashboard info body ───────────────────────────────────────────────────────

class _DashboardBody extends StatelessWidget {
  final Map<String, dynamic> member;
  final String locale;
  const _DashboardBody({required this.member, required this.locale});

  @override
  Widget build(BuildContext context) {
    String s(String key) => AppStrings.get(key, locale);

    final name     = member['full_name']   ?? '';
    final memberId = member['memberId']    ?? '';
    final phone    = member['phone']       ?? '';
    final email    = member['email']       ?? '';
    final address  = member['address']     ?? '';
    final dob      = member['date_of_birth'] ?? '';
    final idNumber = member['identification_number'] ?? '';
    final idType   = member['identification_type']   ?? '';
    final notes    = member['notes']       ?? '';
    final locality = member['locality'] as Map<String, dynamic>?;
    final commune  = locality?['commune'] ?? '';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          _WelcomeCard(
            name: name,
            memberId: memberId,
            commune: commune,
            greeting: '${s('helloGreeting')}, $name!',
            welcomeText: s('memberPortalWelcomeText'),
          ),
          const SizedBox(height: 16),
          _InfoCard(
            title: s('memberSectionPersonal'),
            icon: Icons.person,
            rows: [
              if (name.isNotEmpty)    _InfoRow(s('fullName'),    name,    Icons.badge),
              if (dob.isNotEmpty)     _InfoRow(s('dateOfBirth'), dob,     Icons.cake),
              if (address.isNotEmpty) _InfoRow(s('address'),     address, Icons.home),
              if (commune.isNotEmpty) _InfoRow(s('commune'),     commune, Icons.location_on),
            ],
          ),
          const SizedBox(height: 16),
          _InfoCard(
            title: s('memberSectionContact'),
            icon: Icons.contact_phone,
            rows: [
              if (phone.isNotEmpty) _InfoRow(s('phone'), phone, Icons.phone),
              if (email.isNotEmpty) _InfoRow(s('email'), email, Icons.email),
            ],
          ),
          const SizedBox(height: 16),
          if (idNumber.isNotEmpty || idType.isNotEmpty)
            _InfoCard(
              title: s('memberSectionId'),
              icon: Icons.credit_card,
              rows: [
                if (memberId.isNotEmpty) _InfoRow(s('memberId'), memberId, Icons.tag),
                if (idType.isNotEmpty)   _InfoRow(s('idType'),   idType,   Icons.article),
                if (idNumber.isNotEmpty) _InfoRow(s('idNumber'), idNumber, Icons.numbers),
              ],
            ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 16),
            _InfoCard(
              title: s('memberSectionNotes'),
              icon: Icons.notes,
              rows: [_InfoRow('', notes, Icons.notes)],
            ),
          ],
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _WelcomeCard extends StatelessWidget {
  final String name;
  final String memberId;
  final String commune;
  final String greeting;
  final String welcomeText;
  const _WelcomeCard({
    required this.name,
    required this.memberId,
    required this.commune,
    required this.greeting,
    required this.welcomeText,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: const LinearGradient(
            colors: [Color(0xFFFFF8EE), Color(0xFFFFF3DC)],
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.waving_hand, color: Color(0xFFC8A96E), size: 22),
            const SizedBox(width: 8),
            Text(greeting,
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A5C2A))),
          ]),
          const SizedBox(height: 8),
          Text(
            welcomeText,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
          ),
          if (memberId.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1A5C2A).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('ID: $memberId',
                  style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A5C2A))),
            ),
          ],
        ]),
      ),
    );
  }
}

class _InfoRow {
  final String label;
  final String value;
  final IconData icon;
  const _InfoRow(this.label, this.value, this.icon);
}

class _InfoCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<_InfoRow> rows;
  const _InfoCard(
      {required this.title, required this.icon, required this.rows});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: const Color(0xFF1A5C2A), size: 18),
            const SizedBox(width: 8),
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Color(0xFF1A5C2A))),
          ]),
          const Divider(height: 16),
          ...rows.map((r) => _RowTile(row: r)),
        ]),
      ),
    );
  }
}

class _RowTile extends StatelessWidget {
  final _InfoRow row;
  const _RowTile({required this.row});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(row.icon, size: 16, color: Colors.grey.shade500),
        const SizedBox(width: 10),
        if (row.label.isNotEmpty) ...[
          SizedBox(
            width: 110,
            child: Text(row.label,
                style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500)),
          ),
        ],
        Expanded(
          child: Text(row.value,
              style: const TextStyle(fontSize: 13, color: Color(0xFF1A1A1A))),
        ),
      ]),
    );
  }
}
