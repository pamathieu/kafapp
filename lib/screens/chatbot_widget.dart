import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../misc/app_strings.dart';
import '../providers/language_provider.dart';

// ── Data model ────────────────────────────────────────────────────────────────

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;
  const ChatMessage({
    required this.text,
    required this.isUser,
    required this.timestamp,
  });
}

// ── Mode enum ─────────────────────────────────────────────────────────────────

enum _Mode { landing, chat }

// ── Widget ────────────────────────────────────────────────────────────────────

class ChatbotWidget extends StatefulWidget {
  final Map<String, dynamic> member;

  const ChatbotWidget({
    super.key,
    required this.member,
  });

  @override
  State<ChatbotWidget> createState() => _ChatbotWidgetState();
}

class _ChatbotWidgetState extends State<ChatbotWidget> {
  static const String _chatUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod/member/chat';

  final _textCtrl   = TextEditingController();
  final _scrollCtrl = ScrollController();

  final List<Map<String, String>> _history  = [];
  final List<ChatMessage>         _messages = [];

  _Mode _mode          = _Mode.landing;
  bool  _isBotThinking = false;

  late stt.SpeechToText _speech;
  bool _speechAvailable = false;
  bool _isListening     = false;

  // Reads live locale from LanguageProvider — updates whenever language is toggled
  String get _locale => context.read<LanguageProvider>().locale;
  String s(String key) => AppStrings.get(key, _locale);
  String get _firstName =>
      (widget.member['full_name'] as String? ?? '').split(' ').first;

  /// Pick the right string for the current locale.
  /// Falls back to French for ht (Haitian Creole uses French base strings).
  String _t({
    required String fr,
    required String en,
    String? ht,
    String? es,
    String? pt,
  }) {
    switch (_locale) {
      case 'en': return en;
      case 'ht': return ht ?? fr;
      case 'es': return es ?? en;
      case 'pt': return pt ?? en;
      default:   return fr; // 'fr' and fallback
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    final available = await _speech.initialize(
      onStatus: (status) {
        if (status == stt.SpeechToText.doneStatus ||
            status == stt.SpeechToText.notListeningStatus) {
          if (mounted) setState(() => _isListening = false);
        }
      },
      onError: (_) {
        if (mounted) setState(() => _isListening = false);
      },
    );
    if (mounted) setState(() => _speechAvailable = available);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _speech.stop();
    super.dispose();
  }

  // ── Landing button actions ─────────────────────────────────────────────────

  void _startConversation() {
    final greeting = _t(
      fr: 'Bonjour $_firstName ! Je suis votre assistant KAFA. Comment puis-je vous aider ?',
      en: 'Hello $_firstName! I\'m your KAFA assistant. How can I help you today?',
      ht: 'Bonjou $_firstName! Mwen se asistan KAFA ou. Kijan mwen ka ede ou jodi a?',
      es: '¡Hola $_firstName! Soy tu asistente KAFA. ¿En qué puedo ayudarte hoy?',
      pt: 'Olá $_firstName! Sou o seu assistente KAFA. Como posso ajudá-lo hoje?',
    );
    setState(() {
      _mode = _Mode.chat;
      _history.clear();
      _messages.clear();
      _messages.add(ChatMessage(
          text: greeting, isUser: false, timestamp: DateTime.now()));
    });
  }

  void _viewInformation() {
    setState(() {
      _mode = _Mode.chat;
      _history.clear();
      _messages.clear();
    });
    final prompt = _t(
      fr: 'Fournis-moi toutes mes informations de profil membre KAFA.',
      en: 'Please provide me with all my KAFA member profile information.',
      ht: 'Ban mwen tout enfòmasyon pwofil manm KAFA mwen.',
      es: 'Proporcioname toda mi información de perfil de miembro KAFA.',
      pt: 'Forneça-me todas as informações do meu perfil de membro KAFA.',
    );
    _sendSilentPrompt(prompt);
  }

  void _viewPolicies() {
    setState(() {
      _mode = _Mode.chat;
      _history.clear();
      _messages.clear();
    });
    final prompt = _t(
      fr: 'Résume mes polices d\'assurance KAFA, les paiements récents et les prochaines échéances.',
      en: 'Summarize my KAFA insurance policies, recent payments, and upcoming due dates.',
      ht: 'Rezime polis asirans KAFA mwen yo, peman resan yo ak dat ki ap vini yo.',
      es: 'Resume mis pólizas de seguro KAFA, pagos recientes y próximas fechas de vencimiento.',
      pt: 'Resuma as minhas apólices de seguro KAFA, pagamentos recentes e próximas datas de vencimento.',
    );
    _sendSilentPrompt(prompt);
  }

  void _backToLanding() {
    setState(() {
      _mode = _Mode.landing;
      _history.clear();
      _messages.clear();
    });
  }

  // ── Messaging ──────────────────────────────────────────────────────────────

  /// Sends a prompt without showing it as a user bubble — used for the
  /// "View information" and "View policies" auto-prompts.
  Future<void> _sendSilentPrompt(String prompt) async {
    setState(() => _isBotThinking = true);
    _history.add({'role': 'user', 'content': prompt});

    try {
      final response = await http.post(
        Uri.parse(_chatUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'messages': _history,
          'member':   widget.member,
          'locale':   _locale,
        }),
      ).timeout(const Duration(seconds: 35));

      if (!mounted) return;
      final data  = jsonDecode(response.body) as Map<String, dynamic>;
      final raw   = data['reply'] as String? ?? s('chatbotDefaultReply');
      final reply = _parseLangTag(raw) ?? raw;
      _history.add({'role': 'assistant', 'content': reply});
      setState(() {
        _isBotThinking = false;
        _messages.add(ChatMessage(
            text: reply, isUser: false, timestamp: DateTime.now()));
      });
    } catch (_) {
      if (!mounted) return;
      _history.removeLast();
      setState(() {
        _isBotThinking = false;
        _messages.add(ChatMessage(
            text: s('chatbotDefaultReply'),
            isUser: false,
            timestamp: DateTime.now()));
      });
    }
    _scrollToBottom();
  }

  Future<void> _sendUserMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _isBotThinking) return;
    _textCtrl.clear();

    // Detect language from user's message immediately so the toggle switches
    // before the API call. _parseLangTag will override this if the LLM
    // responds with a [lang:xx] tag.
    final detected = _detectLocale(trimmed);
    if (detected.isNotEmpty && detected != _locale) {
      context.read<LanguageProvider>().setLocale(detected);
    }

    setState(() {
      _messages.add(ChatMessage(
          text: trimmed, isUser: true, timestamp: DateTime.now()));
      _isBotThinking = true;
    });
    _scrollToBottom();
    _history.add({'role': 'user', 'content': trimmed});

    try {
      final response = await http.post(
        Uri.parse(_chatUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'messages': _history,
          'member':   widget.member,
          'locale':   _locale,
        }),
      ).timeout(const Duration(seconds: 35));

      if (!mounted) return;
      final data   = jsonDecode(response.body) as Map<String, dynamic>;
      final raw    = data['reply'] as String? ??
          data['error'] as String? ??
          s('chatbotDefaultReply');
      final reply  = _parseLangTag(raw) ?? raw;
      _history.add({'role': 'assistant', 'content': reply});
      setState(() {
        _isBotThinking = false;
        _messages.add(ChatMessage(
            text: reply, isUser: false, timestamp: DateTime.now()));
      });
    } catch (_) {
      if (!mounted) return;
      _history.removeLast();
      setState(() {
        _isBotThinking = false;
        _messages.add(ChatMessage(
            text: s('chatbotDefaultReply'),
            isUser: false,
            timestamp: DateTime.now()));
      });
    }
    _scrollToBottom();
  }

  /// Extracts a [lang:xx] tag from the LLM reply, switches the locale if
  /// the code is recognised, and returns the reply with the tag removed.
  /// Returns null if no tag was found so the caller can fall back.
  String? _parseLangTag(String reply) {
    final match = RegExp(r'\[lang:([a-z]{2})\]', caseSensitive: false)
        .firstMatch(reply);
    if (match == null) return null;
    final code = match.group(1)!;
    const supported = {'fr', 'en', 'ht', 'es', 'pt'};
    if (supported.contains(code) && code != _locale) {
      context.read<LanguageProvider>().setLocale(code);
    }
    return reply.replaceFirst(match.group(0)!, '').trim();
  }

  /// Keyword-based fallback detector used when the LLM response has no tag.
  /// Returns a locale code, or '' if undetermined.
  String _detectLocale(String text) {
    final normalized = text
        .toLowerCase()
        // Strip diacritics so "cuánto"→"cuanto", "não"→"nao", etc.
        .replaceAll(RegExp(r'[àáâãä]'), 'a')
        .replaceAll(RegExp(r'[èéêë]'), 'e')
        .replaceAll(RegExp(r'[ìíîï]'), 'i')
        .replaceAll(RegExp(r'[òóôõö]'), 'o')
        .replaceAll(RegExp(r'[ùúûü]'), 'u')
        .replaceAll('ñ', 'n')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r"['''\-]"), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final t = ' $normalized ';
    bool has(String w) => t.contains(' $w ') || t.contains(' $w,') ||
        t.contains(' $w.') || t.contains(' $w?') || t.contains(' $w!');

    // Keywords are all diacritic-free to match the normalised input.
    const htWords = ['mwen', 'bonjou', 'bonswa', 'koman', 'kisa', 'mesi',
        'konnen', 'tanpri', 'ki jan', 'ou ye', 'pou mwen', 'pou', 'nan', 'pa'];
    const esWords = ['hola', 'gracias', 'tengo', 'necesito', 'quiero',
        'puedo', 'hablar', 'ayuda', 'buenos', 'por favor', 'estoy', 'usted',
        'del', 'muy', 'los', 'las', 'con', 'pero', 'cuando', 'donde', 'cuanto'];
    const ptWords = ['ola', 'obrigado', 'obrigada', 'preciso', 'posso',
        'voce', 'bom dia', 'boa tarde', 'ajuda', 'minha', 'meu',
        'nao', 'tambem', 'pagamento'];
    const frWords = ['bonjour', 'merci', 'bonsoir', 'pouvez', 'voulez',
        'aide', 'nous', 'vous', 'je', 'pour', 'avec', 'dans', 'une',
        'sont', 'du', 'des', 'pas', 'mais', 'les', 'est',
        'police', 'paiement', 'assurance'];
    const enWords = ['hello', 'please', 'thank you', 'how do', 'what is',
        'can you', 'i need', 'i want', 'show me', 'tell me', 'help me',
        'i have', 'i am', 'the', 'my', 'payment', 'policy'];

    int score(List<String> words) =>
        words.fold(0, (sum, w) => sum + (has(w) ? 1 : 0));
    final scores = {
      'ht': score(htWords), 'es': score(esWords), 'pt': score(ptWords),
      'fr': score(frWords), 'en': score(enWords),
    };
    final best = scores.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return best.value > 0 ? best.key : '';
  }


  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _toggleListening() async {
    if (!_speechAvailable) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(s('chatbotSpeechUnavailable'))));
      return;
    }
    if (_isListening) {
      await _speech.stop();
      setState(() => _isListening = false);
      return;
    }
    final granted = await _speech.hasPermission;
    if (!granted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(s('chatbotMicPermissionDenied'))));
      }
      return;
    }
    setState(() => _isListening = true);
    await _speech.listen(
      onResult: (result) {
        if (result.finalResult) {
          final recognized = result.recognizedWords.trim();
          if (recognized.isNotEmpty) {
            _textCtrl.text = recognized;
            _sendUserMessage(recognized);
          }
          setState(() => _isListening = false);
        } else {
          setState(() => _textCtrl.text = result.recognizedWords);
        }
      },
      listenFor: const Duration(seconds: 30),
      pauseFor:  const Duration(seconds: 4),
      localeId: {
        'fr': 'fr_FR',
        'ht': 'fr_FR', // Haitian Creole — closest available STT locale
        'es': 'es_ES',
        'pt': 'pt_BR',
      }[_locale] ?? 'en_US',
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Watch LanguageProvider so the widget rebuilds when language is toggled
    context.watch<LanguageProvider>();
    return _mode == _Mode.landing ? _buildLanding() : _buildChat();
  }

  // ── Landing screen ─────────────────────────────────────────────────────────

  Widget _buildLanding() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // KAFA bot avatar
            CircleAvatar(
              radius: 40,
              backgroundColor: const Color(0xFF1A5C2A),
              child: const Icon(Icons.support_agent,
                  color: Colors.white, size: 40),
            ),
            const SizedBox(height: 20),
            Text(
              _t(
                fr: 'Bonjour $_firstName, comment puis-je vous aider ?',
                en: 'Hello $_firstName, how can I help you?',
                ht: 'Bonjou $_firstName, kijan mwen ka ede ou?',
                es: '¡Hola $_firstName, cómo puedo ayudarte?',
                pt: 'Olá $_firstName, como posso ajudá-lo?',
              ),
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A1A1A)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _t(
                fr: 'Choisissez une option pour commencer.',
                en: 'Choose an option to get started.',
                ht: 'Chwazi yon opsyon pou kòmanse.',
                es: 'Elige una opción para comenzar.',
                pt: 'Escolha uma opção para começar.',
              ),
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),

            // ── Option buttons ───────────────────────────────────────────────
            _LandingButton(
              icon: Icons.chat_bubble_outline,
              label: _t(
                fr: 'Démarrer une conversation',
                en: 'Start a conversation',
                ht: 'Kòmanse yon konvèsasyon',
                es: 'Iniciar una conversación',
                pt: 'Iniciar uma conversa',
              ),
              subtitle: _t(
                fr: 'Posez une question à votre assistant',
                en: 'Ask your assistant anything',
                ht: 'Poze asistan ou yon kesyon',
                es: 'Hazle una pregunta a tu asistente',
                pt: 'Faça uma pergunta ao seu assistente',
              ),
              onTap: _startConversation,
            ),
            const SizedBox(height: 14),
            _LandingButton(
              icon: Icons.person_outline,
              label: _t(
                fr: 'Voir mes informations',
                en: 'View my information',
                ht: 'Wè enfòmasyon mwen',
                es: 'Ver mi información',
                pt: 'Ver as minhas informações',
              ),
              subtitle: _t(
                fr: 'Profil, contact et identification',
                en: 'Profile, contact and identification',
                ht: 'Pwofil, kontak ak idantifikasyon',
                es: 'Perfil, contacto e identificación',
                pt: 'Perfil, contacto e identificação',
              ),
              onTap: _viewInformation,
            ),
            const SizedBox(height: 14),
            _LandingButton(
              icon: Icons.policy_outlined,
              label: _t(
                fr: 'Voir mes polices',
                en: 'View my policies',
                ht: 'Wè polis mwen yo',
                es: 'Ver mis pólizas',
                pt: 'Ver as minhas apólices',
              ),
              subtitle: _t(
                fr: 'Polices, paiements et réclamations',
                en: 'Policies, payments and claims',
                ht: 'Polis, peman ak reklamasyon',
                es: 'Pólizas, pagos y reclamaciones',
                pt: 'Apólices, pagamentos e sinistros',
              ),
              onTap: _viewPolicies,
            ),
          ],
        ),
      ),
    );
  }

  // ── Chat screen ────────────────────────────────────────────────────────────

  Widget _buildChat() {
    return Column(
      children: [
        // Back to landing banner
        GestureDetector(
            onTap: _backToLanding,
            child: Container(
              width: double.infinity,
              color: const Color(0xFF1A5C2A).withOpacity(0.06),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                const Icon(Icons.arrow_back_ios,
                    size: 14, color: Color(0xFF1A5C2A)),
                const SizedBox(width: 6),
                Text(
                  _t(
                    fr: 'Retour au menu',
                    en: 'Back to menu',
                    ht: 'Retounen nan meni',
                    es: 'Volver al menú',
                    pt: 'Voltar ao menu',
                  ),
                  style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF1A5C2A),
                      fontWeight: FontWeight.w500),
                ),
              ]),
            ),
          ),

        // Message list
        Expanded(
          child: ListView.builder(
            controller: _scrollCtrl,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: _messages.length + (_isBotThinking ? 1 : 0),
            itemBuilder: (context, index) {
              if (_isBotThinking && index == _messages.length) {
                return _ThinkingBubble(label: s('chatbotThinking'));
              }
              return _MessageBubble(message: _messages[index]);
            },
          ),
        ),

        // Input row
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.07),
                blurRadius: 8,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isListening
                        ? Colors.red.shade400
                        : const Color(0xFF1A5C2A).withOpacity(0.1),
                  ),
                  child: IconButton(
                    icon: Icon(
                      _isListening ? Icons.mic : Icons.mic_none,
                      color: _isListening
                          ? Colors.white
                          : const Color(0xFF1A5C2A),
                    ),
                    onPressed: _toggleListening,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _textCtrl,
                    textInputAction: TextInputAction.send,
                    onSubmitted: _sendUserMessage,
                    enabled: !_isBotThinking,
                    decoration: InputDecoration(
                      hintText: _isListening
                          ? s('chatbotListening')
                          : s('chatbotInputHint'),
                      hintStyle: TextStyle(
                        color: _isListening
                            ? Colors.red.shade400
                            : Colors.grey.shade400,
                        fontSize: 14,
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade100,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(
                            color: Color(0xFFC8A96E), width: 1.5),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isBotThinking
                        ? Colors.grey.shade300
                        : const Color(0xFFC8A96E),
                  ),
                  child: IconButton(
                    icon:
                        const Icon(Icons.send_rounded, color: Colors.white),
                    onPressed: _isBotThinking
                        ? null
                        : () => _sendUserMessage(_textCtrl.text),
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

// ── Landing button widget ─────────────────────────────────────────────────────

class _LandingButton extends StatelessWidget {
  final IconData icon;
  final String   label;
  final String   subtitle;
  final VoidCallback onTap;

  const _LandingButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: const Color(0xFF1A5C2A).withOpacity(0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: const Color(0xFF1A5C2A), size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1A1A1A))),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right,
                color: Colors.grey, size: 20),
          ]),
        ),
      ),
    );
  }
}

// ── Message bubble ────────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            const CircleAvatar(
              radius: 16,
              backgroundColor: Color(0xFF1A5C2A),
              child: Icon(Icons.support_agent,
                  color: Colors.white, size: 16),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color:
                    isUser ? const Color(0xFFC8A96E) : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(isUser ? 18 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 18),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                message.text,
                style: TextStyle(
                  fontSize: 14,
                  color: isUser
                      ? Colors.white
                      : const Color(0xFF1A1A1A),
                  height: 1.4,
                ),
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 16,
              backgroundColor:
                  const Color(0xFFC8A96E).withOpacity(0.3),
              child: const Icon(Icons.person,
                  color: Color(0xFFC8A96E), size: 16),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Thinking bubble ───────────────────────────────────────────────────────────

class _ThinkingBubble extends StatefulWidget {
  final String label;
  const _ThinkingBubble({required this.label});

  @override
  State<_ThinkingBubble> createState() => _ThinkingBubbleState();
}

class _ThinkingBubbleState extends State<_ThinkingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _dot1, _dot2, _dot3;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1200))
      ..repeat();
    _dot1 = _makeAnim(0.0);
    _dot2 = _makeAnim(0.2);
    _dot3 = _makeAnim(0.4);
  }

  Animation<double> _makeAnim(double begin) => TweenSequence([
        TweenSequenceItem(
            tween: Tween(begin: 0.0, end: -6.0), weight: 30),
        TweenSequenceItem(
            tween: Tween(begin: -6.0, end: 0.0), weight: 30),
        TweenSequenceItem(tween: ConstantTween(0.0), weight: 40),
      ]).animate(CurvedAnimation(
        parent: _ctrl,
        curve: Interval(begin, begin + 0.6, curve: Curves.easeInOut),
      ));

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        const CircleAvatar(
          radius: 16,
          backgroundColor: Color(0xFF1A5C2A),
          child: Icon(Icons.support_agent,
              color: Colors.white, size: 16),
        ),
        const SizedBox(width: 8),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(18),
              topRight: Radius.circular(18),
              bottomRight: Radius.circular(18),
              bottomLeft: Radius.circular(4),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Dot(offset: _dot1.value),
                const SizedBox(width: 4),
                _Dot(offset: _dot2.value),
                const SizedBox(width: 4),
                _Dot(offset: _dot3.value),
              ],
            ),
          ),
        ),
      ]),
    );
  }
}

class _Dot extends StatelessWidget {
  final double offset;
  const _Dot({required this.offset});

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: Offset(0, offset),
      child: Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: Color(0xFF1A5C2A),
        ),
      ),
    );
  }
}