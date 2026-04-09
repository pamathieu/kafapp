import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Documents & Wishes screen
//  GET  /member/documents?memberId=X  → {documents: [{documentId, name, type, uploadedAt, url}]}
//  POST /member/documents/upload      → {uploadUrl, documentId}  (presigned PUT)
//  Download: open presigned GET url in browser
// ─────────────────────────────────────────────────────────────────────────────

const _green = Color(0xFF1A5C2A);
const _bg    = Color(0xFFF2F4F7);

const _docTypes = [
  'Testament',
  'Acte de naissance',
  'Acte de mariage',
  'Carte d\'identité',
  'Contrat d\'assurance',
  'Autre',
];

class DocumentsScreen extends StatefulWidget {
  final String memberId;

  const DocumentsScreen({super.key, required this.memberId});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  static const _baseUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod';

  List<Map<String, dynamic>> _documents = [];
  bool _loading = true;
  String? _error;
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final uri = Uri.parse(
          '$_baseUrl/member/documents?memberId=${Uri.encodeComponent(widget.memberId)}');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        setState(() {
          _documents = List<Map<String, dynamic>>.from(data['documents'] ?? []);
          _loading = false;
        });
      } else {
        setState(() { _error = 'HTTP ${response.statusCode}'; _loading = false; });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  // ── Upload flow ───────────────────────────────────────────────────────────

  Future<void> _showUploadDialog() async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    final nameCtrl = TextEditingController();
    String selectedType = _docTypes.first;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Padding(
          padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 24,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.upload_file, color: _green),
                const SizedBox(width: 10),
                Text(s('uploadDocument'),
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 20),
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                  labelText: s('beneficiaryName'),
                  hintText: 'ex: Testament 2025',
                  prefixIcon: const Icon(Icons.description_outlined),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: selectedType,
                decoration: InputDecoration(
                  labelText: s('documentType'),
                  prefixIcon: const Icon(Icons.category_outlined),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                items: _docTypes
                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                    .toList(),
                onChanged: (v) => setModal(() => selectedType = v ?? selectedType),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(
                  'Note: Vous serez redirigé vers un lien sécurisé pour téléverser votre fichier.',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ),
              const SizedBox(height: 20),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(s('cancel')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _green,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 48),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      if (nameCtrl.text.trim().isEmpty) return;
                      Navigator.pop(ctx, true);
                    },
                    child: const Text('Continuer'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );

    if (confirmed != true) return;
    final name = nameCtrl.text.trim();
    await _requestUploadUrl(name: name, docType: selectedType);
  }

  Future<void> _requestUploadUrl({
    required String name,
    required String docType,
  }) async {
    final locale = context.read<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    setState(() => _uploading = true);
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/member/documents/upload'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'memberId': widget.memberId,
          'name': name,
          'docType': docType,
        }),
      );
      if (!mounted) return;
      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final uploadUrl = data['uploadUrl'] as String?;
        if (uploadUrl != null) {
          final uri = Uri.parse(uploadUrl);
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri, mode: LaunchMode.externalApplication);
          }
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(s('uploadSuccess')),
              backgroundColor: Colors.green.shade700));
          _load();
        }
      } else {
        throw Exception('HTTP ${response.statusCode}');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${s('uploadError')}: $e'),
          backgroundColor: Colors.red.shade700));
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _download(Map<String, dynamic> doc) async {
    final url = doc['url'] as String?;
    if (url == null || url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final locale = context.watch<LanguageProvider>().locale;
    String s(String k) => AppStrings.get(k, locale);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        title: Text(s('documentsTitle'),
            style: const TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _green,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _uploading ? null : _showUploadDialog,
        backgroundColor: _green,
        foregroundColor: Colors.white,
        icon: _uploading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2))
            : const Icon(Icons.upload_file),
        label: Text(_uploading ? s('uploadInProgress') : s('uploadDocument')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: _green))
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  color: _green,
                  child: _documents.isEmpty
                      ? _EmptyView(locale: locale)
                      : ListView.builder(
                          padding:
                              const EdgeInsets.fromLTRB(16, 20, 16, 100),
                          itemCount: _documents.length,
                          itemBuilder: (_, i) => _DocumentCard(
                                data: _documents[i],
                                locale: locale,
                                onDownload: () => _download(_documents[i]),
                              ),
                        ),
                ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _DocumentCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final String locale;
  final VoidCallback onDownload;

  const _DocumentCard({
    required this.data,
    required this.locale,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);
    final name       = data['name']        as String? ?? '—';
    final docType    = data['docType']     as String? ?? data['type'] as String? ?? '';
    final uploadedAt = data['uploadedAt']  as String? ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: _green.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.insert_drive_file_outlined,
              color: _green, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14)),
            if (docType.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(docType,
                  style: TextStyle(
                      fontSize: 12, color: Colors.grey.shade500)),
            ],
            if (uploadedAt.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(AppStrings.formatDate(uploadedAt, locale),
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade400)),
            ],
          ]),
        ),
        IconButton(
          icon: const Icon(Icons.download_outlined, color: _green),
          tooltip: s('downloadDocument'),
          onPressed: onDownload,
        ),
      ]),
    );
  }
}

class _EmptyView extends StatelessWidget {
  final String locale;
  const _EmptyView({required this.locale});

  @override
  Widget build(BuildContext context) {
    String s(String k) => AppStrings.get(k, locale);
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.folder_open, size: 64, color: Colors.grey.shade400),
        const SizedBox(height: 16),
        Text(s('noDocuments'),
            style: TextStyle(color: Colors.grey.shade600, fontSize: 15)),
        const SizedBox(height: 8),
        Text(s('uploadDocument'),
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
      ]),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline, color: Colors.red.shade400, size: 48),
          const SizedBox(height: 12),
          Text(error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                  backgroundColor: _green, foregroundColor: Colors.white),
              child: const Text('Retry')),
        ]),
      );
}
