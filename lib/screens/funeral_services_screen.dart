import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Funeral Services screen — partner directory
//  GET /member/partners → {partners: [{name, phone, email, address, city}]}
//  Falls back to hardcoded list if API unavailable.
// ─────────────────────────────────────────────────────────────────────────────

const _green = Color(0xFF1A5C2A);
const _bg    = Color(0xFFF2F4F7);

const _fallbackPartners = [
  {
    'name': 'Pompes Funèbres Nationale',
    'phone': '+509 2940-0000',
    'email': 'contact@pfn.ht',
    'address': 'Route de Delmas 75',
    'city': 'Port-au-Prince',
  },
  {
    'name': 'Services Funéraires Caraïbes',
    'phone': '+509 3700-1111',
    'email': 'info@sfcaraibes.ht',
    'address': 'Blvd 15 Octobre',
    'city': 'Cap-Haïtien',
  },
  {
    'name': 'Maison du Dernier Repos',
    'phone': '+509 2810-2222',
    'email': 'mdr@funeraires.ht',
    'address': 'Rue des Capois 12',
    'city': 'Port-au-Prince',
  },
];

class FuneralServicesScreen extends StatefulWidget {
  const FuneralServicesScreen({super.key});

  @override
  State<FuneralServicesScreen> createState() => _FuneralServicesScreenState();
}

class _FuneralServicesScreenState extends State<FuneralServicesScreen> {
  static const _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  List<Map<String, dynamic>> _partners = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/member/partners'))
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final list = List<Map<String, dynamic>>.from(data['partners'] ?? []);
        setState(() {
          _partners = list.isNotEmpty ? list : _fallbackPartners.cast();
          _loading = false;
        });
      } else {
        setState(() { _partners = _fallbackPartners.cast(); _loading = false; });
      }
    } catch (_) {
      if (mounted) setState(() { _partners = _fallbackPartners.cast(); _loading = false; });
    }
  }

  Future<void> _call(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone.replaceAll(' ', ''));
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  Future<void> _email(String email) async {
    final uri = Uri(scheme: 'mailto', path: email);
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Text(s('funeralServicesTitle'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _green,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _green))
          : RefreshIndicator(
              onRefresh: _load,
              color: _green,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                children: [
                  // Header banner
                  Container(
                    padding: const EdgeInsets.all(16),
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: _green.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: _green.withValues(alpha: 0.2)),
                    ),
                    child: Row(children: [
                      const Icon(Icons.local_florist, color: _green, size: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          s('funeralServicesSubtitle'),
                          style: TextStyle(
                              color: _green,
                              fontWeight: FontWeight.w600,
                              fontSize: 14),
                        ),
                      ),
                    ]),
                  ),
                  if (_partners.isEmpty)
                    Center(
                      child: Text(s('noPartners'),
                          style: TextStyle(
                              color: Colors.grey.shade600, fontSize: 15)),
                    )
                  else
                    ..._partners.map((p) => _PartnerCard(
                          data: p,
                          locale: locale,
                          onCall: () => _call(p['phone'] as String? ?? ''),
                          onEmail: () => _email(p['email'] as String? ?? ''),
                        )),
                ],
              ),
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _PartnerCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final String locale;
  final VoidCallback onCall;
  final VoidCallback onEmail;

  const _PartnerCard({
    required this.data,
    required this.locale,
    required this.onCall,
    required this.onEmail,
  });

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);
    final name    = data['name']    as String? ?? '—';
    final phone   = data['phone']   as String? ?? '';
    final email   = data['email']   as String? ?? '';
    final address = data['address'] as String? ?? '';
    final city    = data['city']    as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Name + city
        Row(children: [
          const CircleAvatar(
            radius: 22,
            backgroundColor: Color(0x26C8A96E),
            child: Icon(Icons.business, color: Color(0xFF8B6914), size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              if (city.isNotEmpty)
                Text(city,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade500)),
            ]),
          ),
        ]),

        if (address.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.location_on_outlined,
                size: 14, color: Colors.grey.shade400),
            const SizedBox(width: 4),
            Expanded(
              child: Text(address,
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade600)),
            ),
          ]),
        ],

        const SizedBox(height: 12),
        const Divider(height: 1),
        const SizedBox(height: 12),

        // Action buttons
        Row(children: [
          if (phone.isNotEmpty)
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onCall,
                icon: const Icon(Icons.phone, size: 16),
                label: Text(s('partnerPhone'), overflow: TextOverflow.ellipsis),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _green,
                  side: BorderSide(color: _green),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          if (phone.isNotEmpty && email.isNotEmpty) const SizedBox(width: 10),
          if (email.isNotEmpty)
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onEmail,
                icon: const Icon(Icons.email_outlined, size: 16),
                label: Text(s('partnerEmail'), overflow: TextOverflow.ellipsis),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.blueGrey.shade700,
                  side: BorderSide(color: Colors.blueGrey.shade300),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
        ]),
      ]),
    );
  }
}
