import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../models/member.dart';

const _green = Color(0xFF1A5C2A);
const _gold  = Color(0xFFC8A96E);
const _bg    = Color(0xFFF2F4F7);

class ChatsScreen extends StatefulWidget {
  final bool embedded;
  final String locale;
  const ChatsScreen({super.key, this.embedded = false, this.locale = 'fr'});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  List<Map<String, dynamic>> _prospectSessions = [];
  List<Map<String, dynamic>> _memberSessions   = [];
  Timer? _timer;
  Map<String, String> _memberNames = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = context.read<AuthProvider>().apiService!;
      final prospectSessions = await api.getChats(type: 'prospect_chat');
      final memberSessions   = await api.getChats(type: 'member_chat,member_portal');
      final members          = await api.listMembers();
      setState(() {
        _prospectSessions = prospectSessions;
        _memberSessions   = memberSessions;
        _memberNames      = { for (final m in members) m.memberId: m.fullName };
        _loading          = false;
      });
    } catch (e) {
      debugPrint('[ChatsScreen] load error: $e');
      setState(() { _error = 'Something went wrong. Please try again.'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        Container(
          color: _green,
          child: TabBar(
            controller: _tabCtrl,
            indicatorColor: _gold,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white60,
            tabs: [
              Tab(text: '${AppStrings.get('adminProspects', widget.locale)} (${_prospectSessions.length})'),
              Tab(text: '${AppStrings.get('adminMembers', widget.locale)} (${_memberSessions.length})'),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator(color: _green))
              : _error != null
                  ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
                  : TabBarView(
                      controller: _tabCtrl,
                      children: [
                        _SessionList(sessions: _prospectSessions, memberNames: _memberNames, onRefresh: _load),
                        _SessionList(sessions: _memberSessions,   memberNames: _memberNames, onRefresh: _load),
                      ],
                    ),
        ),
      ],
    );

    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _green,
        title: Text(AppStrings.get('chatHistory', widget.locale), style: const TextStyle(color: Colors.white)),
      ),
      body: body,
    );
  }
}

// ── Session list ──────────────────────────────────────────────────────────────

class _SessionList extends StatelessWidget {
  final List<Map<String, dynamic>> sessions;
  final Map<String, String> memberNames;
  final VoidCallback onRefresh;
  const _SessionList({required this.sessions, required this.memberNames, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return Center(
        child: Text(AppStrings.get('noConversationsYet', context.watch<LanguageProvider>().locale),
            style: const TextStyle(color: Colors.grey)),
      );
    }
    return RefreshIndicator(
      color: _green,
      onRefresh: () async => onRefresh(),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: sessions.length,
        itemBuilder: (_, i) => _SessionCard(session: sessions[i], memberNames: memberNames),
      ),
    );
  }
}

// ── Session card ──────────────────────────────────────────────────────────────

class _SessionCard extends StatefulWidget {
  final Map<String, dynamic> session;
  final Map<String, String> memberNames;
  const _SessionCard({required this.session, required this.memberNames});

  @override
  State<_SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<_SessionCard> {
  bool _expanded = false;

  bool _isMemberChat(Map<String, dynamic> s) {
    final type = s['conversationType'] as String? ?? '';
    return type == 'member_chat' || type == 'member_portal';
  }

  String _displayName(Map<String, dynamic> s) {
    if (_isMemberChat(s)) {
      // Resolve member ID to full name via the members lookup map
      final mid = _resolveMemberId(s);
      if (mid.isNotEmpty) {
        final name = widget.memberNames[mid];
        if (name != null && name.isNotEmpty) return name;
        return mid; // fallback to ID if name not found
      }
      return 'Unknown Member';
    }
    // Prospects: browser · OS
    final browser = s['browser'] as String? ?? '';
    final os      = s['os'] as String? ?? '';
    if (browser.isNotEmpty || os.isNotEmpty) return '$browser · $os'.trim().replaceAll(RegExp(r'^·|·$'), '').trim();
    return 'Unknown';
  }

  String _resolveMemberId(Map<String, dynamic> s) {
    // Try explicit memberId field first
    final mid = s['memberId'] as String? ?? '';
    if (mid.isNotEmpty) return mid;
    // Extract from sessionId (format: "ID#date")
    final sid = s['sessionId'] as String? ?? '';
    if (sid.contains('#')) return sid.split('#').first;
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final s        = widget.session;
    final messages = (s['messages'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();
    final lastMsg  = messages.isNotEmpty ? messages.first : null;
    final ts       = (s['lastTimestamp'] as String? ?? '').replaceFirst('T', ' ').split('.').first;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Column(
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: _green.withAlpha(20),
              child: Icon(
                _isMemberChat(s) ? Icons.person : Icons.person_search,
                color: _green,
                size: 20,
              ),
            ),
            title: Text(
              _displayName(s),
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_isMemberChat(s) && (s['memberId'] as String? ?? '').isNotEmpty)
                  Text(s['memberId'] as String, style: const TextStyle(fontSize: 12, color: Colors.grey))
                else if ((s['location'] as String? ?? '').isNotEmpty)
                  Text(s['location'] as String, style: const TextStyle(fontSize: 12)),
                Text(ts, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                if (lastMsg != null)
                  Text(
                    lastMsg['userMessage'] as String? ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.black54),
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _green.withAlpha(20),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${messages.length} msg${messages.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 11, color: _green),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more, color: Colors.grey),
              ],
            ),
            onTap: () => setState(() => _expanded = !_expanded),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                children: messages.map((m) => _MessageBubbles(message: m)).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Message bubbles ───────────────────────────────────────────────────────────

class _MessageBubbles extends StatelessWidget {
  final Map<String, dynamic> message;
  const _MessageBubbles({required this.message});

  @override
  Widget build(BuildContext context) {
    final ts = (message['timestamp'] as String? ?? '')
        .replaceFirst('T', ' ').split('.').first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(ts, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
          const SizedBox(height: 6),
          // User message
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 280),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _green,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12), topRight: Radius.circular(12),
                  bottomLeft: Radius.circular(12),
                ),
              ),
              child: Text(message['userMessage'] as String? ?? '',
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),
          const SizedBox(height: 6),
          // Assistant response
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 280),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12), topRight: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message['assistantResponse'] as String? ?? '',
                      style: const TextStyle(fontSize: 13)),
                  if (message['fromCache'] == true)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(AppStrings.get('cached', context.watch<LanguageProvider>().locale),
                          style: const TextStyle(fontSize: 10, color: _gold)),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
