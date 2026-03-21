import 'dart:convert';
import 'package:flutter/material.dart';
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

class _ChatbotWidgetState extends State<ChatbotWidget> {
  static const String _chatUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod/member/chat';

  final _textCtrl   = TextEditingController();
  final _scrollCtrl = ScrollController();

  // Full conversation history sent to Claude each turn
  final List<Map<String, String>> _history = [];
  // Display messages (includes bot greeting)
  final List<ChatMessage> _messages = [];

  late stt.SpeechToText _speech;
  bool _speechAvailable = false;
  bool _isListening    = false;
  bool _isBotThinking  = false;

  String get _locale => widget.locale;
  String s(String key) => AppStrings.get(key, _locale);

  String get _firstName =>
      (widget.member['full_name'] as String? ?? '').split(' ').first;

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _initSpeech();
    _addBotGreeting();
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
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
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
                color: isUser ? const Color(0xFFC8A96E) : Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(isUser ? 18 : 4),
                  bottomRight: Radius.circular(isUser ? 4 : 18),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                message.text,
                style: TextStyle(
                  fontSize: 14,
                  color:
                      isUser ? Colors.white : const Color(0xFF1A1A1A),
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
                  const Color(0xFFC8A96E).withValues(alpha: 0.3),
              child: const Icon(Icons.person,
                  color: Color(0xFFC8A96E), size: 16),
            ),
          ],
        ],
      ),
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