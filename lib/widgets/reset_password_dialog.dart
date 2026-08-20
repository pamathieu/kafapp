import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/language_provider.dart';
import '../misc/app_strings.dart';
import '../services/dev_env.dart';

String get _resetUrl => '$kApiBaseUrl${devPath('/member/request-password-reset')}';

/// Shows the "request a new setup link" dialog. When [fromExpiredLink] is
/// true (i.e. this was reached from an expired setup/reset link), the
/// entered email or phone is verified against [scopedMemberId] — the
/// member that link was resolved to belong to at page-load time — on the
/// backend. It won't accept a different member's email or phone, even if
/// valid for someone else, and won't fall back to an open lookup if
/// [scopedMemberId] is null (the link's owner couldn't be resolved at all).
void showRequestNewPasswordDialog(
  BuildContext context, {
  bool fromExpiredLink = false,
  String? scopedMemberId,
}) {
  final locale = context.read<LanguageProvider>().locale;
  String s(String key) => AppStrings.get(key, locale);
  final identifierCtrl = TextEditingController();
  // Which button is currently loading: null | 'email' | 'whatsapp'
  String? sending;
  String? dialogError;
  bool emailSent = false;

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {

        Future<void> submit(String delivery) async {
          final id = identifierCtrl.text.trim();
          if (id.isEmpty) return;
          setDialogState(() { sending = delivery; dialogError = null; });
          try {
            final res = await http.post(
              Uri.parse(_resetUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'identifier': id,
                'delivery': delivery,
                if (fromExpiredLink) 'fromExpiredLink': true,
                if (scopedMemberId != null && scopedMemberId.isNotEmpty)
                  'memberId': scopedMemberId,
              }),
            );
            final data = jsonDecode(res.body) as Map<String, dynamic>;
            if (res.statusCode != 200) {
              setDialogState(() {
                sending = null;
                dialogError = data['error'] as String? ?? s('somethingWentWrong');
              });
              return;
            }
            if (delivery == 'whatsapp') {
              final link  = data['setupLink'] as String? ?? '';
              final phone = data['phone']     as String? ?? '';
              setDialogState(() => sending = null);
              if (!ctx.mounted) return;
              Navigator.pop(ctx);
              final msg = Uri.encodeComponent(
                "Here's the link to setup your password to the KAFA member portal: $link",
              );
              final waBase = phone.isNotEmpty ? 'https://wa.me/$phone' : 'https://wa.me/';
              await launchUrl(
                Uri.parse('$waBase?text=$msg'),
                mode: LaunchMode.externalApplication,
              );
            } else {
              setDialogState(() { sending = null; emailSent = true; });
            }
          } catch (_) {
            setDialogState(() {
              sending = null;
              dialogError = s('connectionError');
            });
          }
        }

        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text(s('setupYourPassword')),
          content: emailSent
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.mark_email_read_outlined, size: 48, color: Color(0xFF1A5C2A)),
                    const SizedBox(height: 12),
                    Text(
                      s('checkEmailSetupLink'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s('enterIdToReceiveLink'),
                      style: const TextStyle(fontSize: 13, color: Colors.grey),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: identifierCtrl,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: s('memberIdEmailPhone'),
                        prefixIcon: const Icon(Icons.person_outline),
                      ),
                    ),
                    if (dialogError != null) ...[
                      const SizedBox(height: 8),
                      Text(dialogError!, style: const TextStyle(color: Colors.red, fontSize: 13)),
                    ],
                  ],
                ),
          actions: emailSent
              ? [
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(s('done')),
                  ),
                ]
              : [
                  TextButton(
                    onPressed: sending != null ? null : () => Navigator.pop(ctx),
                    child: Text(s('cancel')),
                  ),
                  // WhatsApp button
                  OutlinedButton.icon(
                    onPressed: sending != null ? null : () => submit('whatsapp'),
                    icon: sending == 'whatsapp'
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.chat, size: 16, color: Color(0xFF25D366)),
                    label: const Text('WhatsApp',
                        style: TextStyle(color: Color(0xFF25D366))),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF25D366)),
                    ),
                  ),
                  // Email button
                  FilledButton.icon(
                    onPressed: sending != null ? null : () => submit('email'),
                    icon: sending == 'email'
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.email_outlined, size: 16),
                    label: Text(s('sendLinkBtn')),
                  ),
                ],
        );
      },
    ),
  );
}
