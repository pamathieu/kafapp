import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../services/session_service.dart';
import 'member_login_screen.dart';
import 'chatbot_widget.dart';

class MemberDashboardScreen extends StatefulWidget {
  final Map<String, dynamic> member;
  const MemberDashboardScreen({super.key, required this.member});

  @override
  State<MemberDashboardScreen> createState() => _MemberDashboardScreenState();
}

class _MemberDashboardScreenState extends State<MemberDashboardScreen>
    with SingleTickerProviderStateMixin {
  bool _showChatbot = true;
  late final AnimationController _fadeCtrl;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 250));
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeInOut);
    _fadeCtrl.forward();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    super.dispose();
  }

  void _toggle() {
    _fadeCtrl.reverse().then((_) {
      setState(() => _showChatbot = !_showChatbot);
      _fadeCtrl.forward();
    });
  }

  @override
  Widget build(BuildContext context) {
    final langProvider = context.watch<LanguageProvider>();
    final locale = langProvider.locale;
    String s(String key) => AppStrings.get(key, locale);

    final member   = widget.member;
    final name     = member['full_name']              as String? ?? '';
    final memberId = member['memberId']               as String? ?? '';
    final phone    = member['phone']                  as String? ?? '';
    final email    = member['email']                  as String? ?? '';
    final address  = member['address']                as String? ?? '';
    final dob      = member['date_of_birth']          as String? ?? '';
    final idNumber = member['identification_number']  as String? ?? '';
    final idType   = member['identification_type']    as String? ?? '';
    final notes    = member['notes']                  as String? ?? '';
    final status   = member['status'];
    final isActive = status == true || status == 'true';
    final locality = member['locality'] as Map<String, dynamic>?;
    final commune  = locality?['commune'] as String? ?? '';
    final firstName = name.split(' ').first;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: _KafaAppBar(
        name: name,
        isActive: isActive,
        locale: locale,
        showChatbot: _showChatbot,
        activeMemberLabel: s('activeMember'),
        inactiveMemberLabel: s('inactiveMember'),
        viewProfileLabel: s('chatbotToggleDashboard'),
        chatLabel: s('chatbotToggleChat'),
        logoutLabel: s('logout'),
        langToggleLabel: locale == 'fr' ? '🇺🇸 EN' : '🇫🇷 FR',
        onToggleView: _toggle,
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
      body: FadeTransition(
        opacity: _fade,
        child: _showChatbot
            ? ChatbotWidget(member: member, locale: locale)
            : _ProfileView(
                name: name, memberId: memberId, phone: phone,
                email: email, address: address, dob: dob,
                idNumber: idNumber, idType: idType, notes: notes,
                commune: commune, s: s,
              ),
      ),
    );
  }
}

// ── AppBar ────────────────────────────────────────────────────────────────────

class _KafaAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String name;
  final bool isActive;
  final bool showChatbot;
  final String locale;
  final String activeMemberLabel;
  final String inactiveMemberLabel;
  final String viewProfileLabel;
  final String chatLabel;
  final String logoutLabel;
  final String langToggleLabel;
  final VoidCallback onToggleView;
  final VoidCallback onLogout;
  final VoidCallback onLangToggle;

  const _KafaAppBar({
    required this.name,
    required this.isActive,
    required this.showChatbot,
    required this.locale,
    required this.activeMemberLabel,
    required this.inactiveMemberLabel,
    required this.viewProfileLabel,
    required this.chatLabel,
    required this.logoutLabel,
    required this.langToggleLabel,
    required this.onToggleView,
    required this.onLogout,
    required this.onLangToggle,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final initials = name.isNotEmpty ? name[0].toUpperCase() : '?';

    return AppBar(
      backgroundColor: const Color(0xFF1A5C2A),
      elevation: 0,
      automaticallyImplyLeading: false,
      titleSpacing: 16,

      // ── Left: logo + KAFA ─────────────────────────────────────────────────
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
                  color: const Color(0xFFC8A96E),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.shield, color: Colors.white, size: 20),
              ),
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'KAFA',
            style: TextStyle(
              color: Color(0xFFC8A96E),
              fontSize: 20,
              fontWeight: FontWeight.bold,
              letterSpacing: 3,
            ),
          ),
        ],
      ),

      // ── Right: toggle button + name + profile dropdown ────────────────────
      actions: [
        // Toggle view button
        TextButton.icon(
          onPressed: onToggleView,
          icon: Icon(
            showChatbot ? Icons.person_outline : Icons.chat_bubble_outline,
            color: Colors.white70,
            size: 18,
          ),
          label: Text(
            showChatbot ? viewProfileLabel : chatLabel,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 10),
          ),
        ),
        const SizedBox(width: 4),

        // Name + avatar with dropdown
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: PopupMenuButton<String>(
            offset: const Offset(0, 48),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
            onSelected: (value) {
              if (value == 'toggle') onToggleView();
              if (value == 'logout') onLogout();
              if (value == 'lang')   onLangToggle();
            },
            itemBuilder: (_) => [
              // Status chip
              PopupMenuItem<String>(
                enabled: false,
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 6),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: isActive
                          ? Colors.green.shade100
                          : Colors.grey.shade200,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.circle, size: 8,
                          color: isActive
                              ? Colors.green.shade700
                              : Colors.grey.shade500),
                      const SizedBox(width: 6),
                      Text(
                        isActive ? activeMemberLabel : inactiveMemberLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isActive
                              ? Colors.green.shade700
                              : Colors.grey.shade600,
                        ),
                      ),
                    ]),
                  ),
                ]),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'toggle',
                child: Row(children: [
                  Icon(
                    showChatbot ? Icons.person_outline : Icons.chat_bubble_outline,
                    size: 18, color: const Color(0xFF1A5C2A)),
                  const SizedBox(width: 12),
                  Text(showChatbot ? viewProfileLabel : chatLabel),
                ]),
              ),
              PopupMenuItem<String>(
                value: 'lang',
                child: Row(children: [
                  const Icon(Icons.language,
                      size: 18, color: Color(0xFF1A5C2A)),
                  const SizedBox(width: 12),
                  Text(langToggleLabel),
                ]),
              ),
              const PopupMenuDivider(),
              PopupMenuItem<String>(
                value: 'logout',
                child: Row(children: [
                  Icon(Icons.logout, size: 18, color: Colors.red.shade400),
                  const SizedBox(width: 12),
                  Text(logoutLabel,
                      style: TextStyle(color: Colors.red.shade400)),
                ]),
              ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Full name
                Text(
                  name,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500),
                ),
                const SizedBox(width: 8),
                // Avatar
                CircleAvatar(
                  radius: 18,
                  backgroundColor: const Color(0xFFC8A96E),
                  child: Text(
                    initials,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Profile view ─────────────────────────────────────────────────────────────

class _ProfileView extends StatelessWidget {
  final String name, memberId, phone, email, address, dob,
      idNumber, idType, notes, commune;
  final String Function(String) s;

  const _ProfileView({
    required this.name, required this.memberId, required this.phone,
    required this.email, required this.address, required this.dob,
    required this.idNumber, required this.idType, required this.notes,
    required this.commune, required this.s,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
      child: Column(children: [

        // Profile header card
        Card(
          elevation: 3,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: const LinearGradient(
                colors: [Color(0xFFFFF8EE), Color(0xFFFFF3DC)],
              ),
            ),
            padding: const EdgeInsets.all(20),
            child: Row(children: [
              CircleAvatar(
                radius: 30,
                backgroundColor: const Color(0xFF1A5C2A),
                child: Text(
                  name.isNotEmpty ? name[0].toUpperCase() : '?',
                  style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A1A1A))),
                    if (memberId.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(memberId,
                          style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: Color(0xFF1A5C2A),
                              fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),

        _InfoCard(title: s('memberSectionPersonal'), icon: Icons.person, rows: [
          if (name.isNotEmpty)    _InfoRow(s('fullName'),    name,    Icons.badge),
          if (dob.isNotEmpty)     _InfoRow(s('dateOfBirth'), dob,     Icons.cake),
          if (address.isNotEmpty) _InfoRow(s('address'),     address, Icons.home),
          if (commune.isNotEmpty) _InfoRow(s('commune'),     commune, Icons.location_on),
        ]),
        const SizedBox(height: 16),

        _InfoCard(title: s('memberSectionContact'), icon: Icons.contact_phone, rows: [
          if (phone.isNotEmpty) _InfoRow(s('phone'), phone, Icons.phone),
          if (email.isNotEmpty) _InfoRow(s('email'), email, Icons.email),
        ]),

        if (idNumber.isNotEmpty || idType.isNotEmpty) ...[
          const SizedBox(height: 16),
          _InfoCard(title: s('memberSectionId'), icon: Icons.credit_card, rows: [
            if (memberId.isNotEmpty) _InfoRow(s('memberId'), memberId, Icons.tag),
            if (idType.isNotEmpty)   _InfoRow(s('idType'),   idType,   Icons.article),
            if (idNumber.isNotEmpty) _InfoRow(s('idNumber'), idNumber, Icons.numbers),
          ]),
        ],

        if (notes.isNotEmpty) ...[
          const SizedBox(height: 16),
          _InfoCard(title: s('memberSectionNotes'), icon: Icons.notes,
              rows: [_InfoRow('', notes, Icons.notes)]),
        ],
      ]),
    );
  }
}

// ── Shared card widgets ───────────────────────────────────────────────────────

class _InfoRow {
  final String label, value;
  final IconData icon;
  const _InfoRow(this.label, this.value, this.icon);
}

class _InfoCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<_InfoRow> rows;
  const _InfoCard({required this.title, required this.icon, required this.rows});

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
        if (row.label.isNotEmpty)
          SizedBox(
            width: 110,
            child: Text(row.label,
                style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500)),
          ),
        Expanded(
          child: Text(row.value,
              style:
                  const TextStyle(fontSize: 13, color: Color(0xFF1A1A1A))),
        ),
      ]),
    );
  }
}