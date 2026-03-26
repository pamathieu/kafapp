import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:http/http.dart' as http;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../misc/app_strings.dart';

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

class ChatbotWidget extends StatefulWidget {
  final Map<String, dynamic> member;
  final String locale;

  const ChatbotWidget({
    super.key,
    required this.member,
    required this.locale,
  });

  @override
  State<ChatbotWidget> createState() => _ChatbotWidgetState();
}

enum _ChatMode { landing, chat }

class _ChatbotWidgetState extends State<ChatbotWidget>
    with SingleTickerProviderStateMixin {
  static const String _chatUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod/member/chat';

  final _textCtrl   = TextEditingController();
  final _scrollCtrl = ScrollController();

  // Full conversation history sent to Claude each turn
  final List<Map<String, String>> _history = [];
  // Display messages (includes bot greeting)
  final List<ChatMessage> _messages = [];

  late stt.SpeechToText _speech;
  late AnimationController _fadeCtrl;
  late Animation<double> _fade;
  bool _speechAvailable = false;
  bool _isListening    = false;
  bool _isBotThinking  = false;
  _ChatMode _mode      = _ChatMode.landing;

  String get _locale => widget.locale;
  String s(String key) => AppStrings.get(key, _locale);

  String get _firstName =>
      (widget.member['full_name'] as String? ?? '').split(' ').first;

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _initSpeech();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 220));
    _fade = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeInOut);
    _fadeCtrl.value = 1.0;
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

  void _addBotGreeting() {
    final greeting = s('chatbotGreeting').replaceAll('{name}', _firstName);
    setState(() {
      _messages.add(ChatMessage(
          text: greeting, isUser: false, timestamp: DateTime.now()));
    });
    // Don't add greeting to history — it's part of the system prompt context
  }

  Future<void> _transitionTo(_ChatMode next, VoidCallback onSwitch) async {
    await _fadeCtrl.reverse();
    if (!mounted) return;
    onSwitch();
    _fadeCtrl.forward();
  }

  void _startConversation() {
    _transitionTo(_ChatMode.chat, () {
      setState(() => _mode = _ChatMode.chat);
      _addBotGreeting();
    });
  }

  Future<void> _sendAutoPrompt(String prompt) async {
    await _fadeCtrl.reverse();
    if (!mounted) return;
    setState(() {
      _mode = _ChatMode.chat;
      _isBotThinking = true;
    });
    _fadeCtrl.forward();

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
      final reply = data['reply'] as String? ??
          data['error'] as String? ??
          s('chatbotDefaultReply');

      _history.add({'role': 'assistant', 'content': reply});

      setState(() {
        _isBotThinking = false;
        _messages.add(ChatMessage(
            text: reply, isUser: false, timestamp: DateTime.now()));
      });
    } catch (e) {
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

    // Add to display
    setState(() {
      _messages.add(ChatMessage(
          text: trimmed, isUser: true, timestamp: DateTime.now()));
      _isBotThinking = true;
    });
    _scrollToBottom();

    // Add to conversation history
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

      final data  = jsonDecode(response.body) as Map<String, dynamic>;
      final reply = data['reply'] as String? ??
          data['error'] as String? ??
          s('chatbotDefaultReply');

      // Add assistant reply to history so Claude has full context next turn
      _history.add({'role': 'assistant', 'content': reply});

      setState(() {
        _isBotThinking = false;
        _messages.add(ChatMessage(
            text: reply, isUser: false, timestamp: DateTime.now()));
      });
    } catch (e) {
      if (!mounted) return;
      final errMsg = s('chatbotDefaultReply');
      _history.removeLast(); // remove the failed user message from history
      setState(() {
        _isBotThinking = false;
        _messages.add(ChatMessage(
            text: errMsg, isUser: false, timestamp: DateTime.now()));
      });
    }

    _scrollToBottom();
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
        SnackBar(content: Text(s('chatbotSpeechUnavailable'))),
      );
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
          SnackBar(content: Text(s('chatbotMicPermissionDenied'))),
        );
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
      localeId:  _locale == 'fr' ? 'fr_FR' : 'en_US',
    );
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: _mode == _ChatMode.landing
          ? _LandingOptions(
              firstName: _firstName,
              s: s,
              onStartConversation: _startConversation,
              onViewInformation: () => _sendAutoPrompt(s('chatAutoPromptInfo')),
              onViewPolicies: () => _sendAutoPrompt(s('chatAutoPromptPolicies')),
            )
          : _buildChat(),
    );
  }

  Widget _buildChat() {
    return Column(
      children: [
        // ── Back arrow ───────────────────────────────────────────────────────
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Color(0xFF1A5C2A)),
              tooltip: 'Back',
              onPressed: () => _transitionTo(_ChatMode.landing, () {
                setState(() {
                  _mode = _ChatMode.landing;
                  _messages.clear();
                  _history.clear();
                });
              }),
            ),
          ),
        ),

        // ── Message list ─────────────────────────────────────────────────────
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

        // ── Input row ────────────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.07),
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
                // Mic button
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isListening
                        ? Colors.red.shade400
                        : const Color(0xFF1A5C2A).withValues(alpha: 0.1),
                  ),
                  child: IconButton(
                    icon: Icon(
                      _isListening ? Icons.mic : Icons.mic_none,
                      color: _isListening
                          ? Colors.white
                          : const Color(0xFF1A5C2A),
                    ),
                    tooltip: _isListening
                        ? s('chatbotListening')
                        : 'Voice input',
                    onPressed: _toggleListening,
                  ),
                ),
                const SizedBox(width: 8),

                // Text field
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

                // Send button
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isBotThinking
                        ? Colors.grey.shade300
                        : const Color(0xFFC8A96E),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.send_rounded, color: Colors.white),
                    tooltip: s('chatbotSend'),
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

// ── Bubble widgets ────────────────────────────────────────────────────────────

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  const _MessageBubble({required this.message});

  String get _timeStr {
    final t = message.timestamp;
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    final maxWidth = MediaQuery.of(context).size.width * 0.72;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Bot avatar
          if (!isUser) ...[
            Container(
              margin: const EdgeInsets.only(top: 2),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFF1A5C2A), Color(0xFF2E7D40)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Color(0x331A5C2A),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: const CircleAvatar(
                radius: 18,
                backgroundColor: Colors.transparent,
                child: Icon(Icons.support_agent, color: Colors.white, size: 18),
              ),
            ),
            const SizedBox(width: 10),
          ],

          // Bubble + label + timestamp
          Flexible(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: Column(
                crossAxisAlignment:
                    isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  // "KAFA Assistant" label for bot
                  if (!isUser)
                    Padding(
                      padding: const EdgeInsets.only(left: 6, bottom: 4),
                      child: Text(
                        'KAFA Assistant',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF1A5C2A).withValues(alpha: 0.65),
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),

                  // Bubble
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      gradient: isUser
                          ? const LinearGradient(
                              colors: [Color(0xFFD4A96E), Color(0xFFB8904E)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            )
                          : const LinearGradient(
                              colors: [Colors.white, Color(0xFFF8F8F8)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(18),
                        topRight: const Radius.circular(18),
                        bottomLeft: Radius.circular(isUser ? 18 : 4),
                        bottomRight: Radius.circular(isUser ? 4 : 18),
                      ),
                      border: isUser
                          ? null
                          : Border.all(
                              color: Colors.grey.shade200, width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: isUser
                              ? const Color(0xFFC8A96E).withValues(alpha: 0.35)
                              : Colors.black.withValues(alpha: 0.07),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: _buildBody(isUser),
                  ),

                  // Timestamp
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 4, right: 4),
                    child: Text(
                      _timeStr,
                      style: TextStyle(
                          fontSize: 10, color: Colors.grey.shade400),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // User avatar
          if (isUser) ...[
            const SizedBox(width: 10),
            Container(
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFC8A96E).withValues(alpha: 0.18),
                border: Border.all(
                    color: const Color(0xFFC8A96E).withValues(alpha: 0.5),
                    width: 1.5),
              ),
              child: const CircleAvatar(
                radius: 18,
                backgroundColor: Colors.transparent,
                child: Icon(Icons.person, color: Color(0xFFC8A96E), size: 18),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(bool isUser) {
    if (isUser) {
      return Text(
        message.text,
        style: const TextStyle(
          fontSize: 14,
          color: Colors.white,
          height: 1.55,
        ),
      );
    }

    return MarkdownBody(
      data: message.text,
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(
          fontSize: 14,
          color: Color(0xFF1A1A1A),
          height: 1.6,
        ),
        strong: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: Color(0xFF1A5C2A),
        ),
        em: const TextStyle(
          fontSize: 14,
          fontStyle: FontStyle.italic,
          color: Color(0xFF1A1A1A),
        ),
        listBullet: const TextStyle(
          fontSize: 14,
          color: Color(0xFF1A5C2A),
        ),
        h1: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.bold,
          color: Color(0xFF1A5C2A),
        ),
        h2: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: Color(0xFF1A5C2A),
        ),
        h3: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Color(0xFF1A5C2A),
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: Colors.grey.shade300, width: 1),
          ),
        ),
        blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        blockquoteDecoration: BoxDecoration(
          color: const Color(0xFFF0F7F2),
          borderRadius: BorderRadius.circular(4),
          border: const Border(
            left: BorderSide(color: Color(0xFF1A5C2A), width: 3),
          ),
        ),
        pPadding: const EdgeInsets.only(bottom: 4),
      ),
      shrinkWrap: true,
    );
  }
}

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
      child: Row(
        children: [
          const CircleAvatar(
            radius: 16,
            backgroundColor: Color(0xFF1A5C2A),
            child: Icon(Icons.support_agent,
                color: Colors.white, size: 16),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 12),
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
                  color: Colors.black.withValues(alpha: 0.06),
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
        ],
      ),
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

// ── Landing options screen ─────────────────────────────────────────────────────

class _LandingOptions extends StatelessWidget {
  final String firstName;
  final String Function(String) s;
  final VoidCallback onStartConversation;
  final VoidCallback onViewInformation;
  final VoidCallback onViewPolicies;

  const _LandingOptions({
    required this.firstName,
    required this.s,
    required this.onStartConversation,
    required this.onViewInformation,
    required this.onViewPolicies,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Bot avatar
            const CircleAvatar(
              radius: 36,
              backgroundColor: Color(0xFF1A5C2A),
              child: Icon(Icons.support_agent, color: Colors.white, size: 36),
            ),
            const SizedBox(height: 20),

            // Greeting
            Text(
              '${s('helloGreeting')}, $firstName!',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Color(0xFF1A1A1A),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              s('chatLandingSubtitle'),
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 40),

            _LandingButton(
              icon: Icons.chat_bubble_outline,
              label: s('chatStartConversation'),
              color: const Color(0xFF1A5C2A),
              onTap: onStartConversation,
            ),
            const SizedBox(height: 10),
            _LandingButton(
              icon: Icons.person_outline,
              label: s('chatViewInformation'),
              color: const Color(0xFF1A5C2A),
              onTap: onViewInformation,
            ),
            const SizedBox(height: 10),
            _LandingButton(
              icon: Icons.policy_outlined,
              label: s('chatViewPolicies'),
              color: const Color(0xFFC8A96E),
              onTap: onViewPolicies,
            ),
          ],
        ),
      ),
    );
  }
}

class _LandingButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _LandingButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, color: color),
        label: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          side: BorderSide(color: color, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}