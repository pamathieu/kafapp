import 'package:flutter/material.dart';

class LanguageProvider extends ChangeNotifier {
  String _locale = 'fr';

  String get locale => _locale;

  static const List<Map<String, String>> supportedLanguages = [
    {'code': 'fr',  'label': '🇫🇷 Français'},
    {'code': 'en',  'label': '🇺🇸 English'},
    {'code': 'ht',  'label': '🇭🇹 Kreyol'},
    {'code': 'es',  'label': '🇪🇸 Español'},
    {'code': 'pt',  'label': '🇧🇷 Português'},
  ];

  void setLocale(String locale) {
    if (_locale == locale) return;
    _locale = locale;
    notifyListeners();
  }

  void toggle() {
    final codes = supportedLanguages.map((l) => l['code']!).toList();
    final idx = codes.indexOf(_locale);
    _locale = codes[(idx + 1) % codes.length];
    notifyListeners();
  }
}
