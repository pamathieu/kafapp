import 'package:flutter/material.dart';

class LanguageProvider extends ChangeNotifier {
  String _locale = 'fr';

  String get locale => _locale;

  void toggle() {
    _locale = _locale == 'fr' ? 'en' : 'fr';
    notifyListeners();
  }
}
