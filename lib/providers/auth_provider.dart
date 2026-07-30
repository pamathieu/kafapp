import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  bool        _isLoggedIn    = false;
  bool        _isLoading     = false;
  String      _adminUsername = '';
  String      _errorMessage  = '';
  ApiService? _apiService;

  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod',
  );
  static const String _loginUrl = '$_baseUrl/auth/login';
  static const String _sessionKey = 'kafa_admin_session';

  bool        get isLoggedIn    => _isLoggedIn;
  bool        get isLoading     => _isLoading;
  String      get adminUsername => _adminUsername;
  String      get errorMessage  => _errorMessage;
  ApiService? get apiService    => _apiService;

  /// Called once in main() before runApp. Restores session from storage if valid.
  ///
  /// AWS STS credentials expire after ~1 hour. Sessions older than that are
  /// cleared so the admin sees the login screen rather than a dashboard that
  /// silently returns empty data.
  static const int _sessionTtlSeconds = 3600;

  Future<bool> tryRestoreSession() async {
    try {
      final prefs  = await SharedPreferences.getInstance();
      final stored = prefs.getString(_sessionKey);
      if (stored == null) return false;

      final data    = json.decode(stored) as Map<String, dynamic>;
      final savedAt = data['savedAt'] as int? ?? 0;
      final ageMs   = DateTime.now().millisecondsSinceEpoch - savedAt;

      if (ageMs > _sessionTtlSeconds * 1000) {
        await prefs.remove(_sessionKey);
        return false;
      }

      _isLoggedIn    = true;
      _adminUsername = data['username'] as String;
      _apiService    = ApiService(
        accessKeyId:     data['accessKeyId']     as String,
        secretAccessKey: data['secretAccessKey'] as String,
        sessionToken:    data['sessionToken']    as String?,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> login(String username, String password) async {
    _isLoading    = true;
    _errorMessage = '';
    notifyListeners();

    try {
      final response = await http.post(
        Uri.parse(_loginUrl),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'username': username, 'password': password}),
      );

      if (response.statusCode == 200) {
        final body = json.decode(response.body);

        final accessKeyId     = body['accessKeyId']     as String;
        final secretAccessKey = body['secretAccessKey'] as String;
        final sessionToken    = body['sessionToken']    as String?;

        _isLoggedIn    = true;
        _adminUsername = username;
        _apiService    = ApiService(
          accessKeyId:     accessKeyId,
          secretAccessKey: secretAccessKey,
          sessionToken:    sessionToken,
        );

        // Persist session
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_sessionKey, json.encode({
          'accessKeyId':     accessKeyId,
          'secretAccessKey': secretAccessKey,
          'sessionToken':    sessionToken,
          'username':        username,
          'savedAt':         DateTime.now().millisecondsSinceEpoch,
        }));

        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        final body    = json.decode(response.body);
        _errorMessage = body['error'] ?? 'Invalid username or password.';
        _isLoading    = false;
        notifyListeners();
        return false;
      }
    } catch (e) {
      _errorMessage = 'Connection error. Please try again.';
      _isLoading    = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    _isLoggedIn    = false;
    _adminUsername = '';
    _apiService    = null;
    _errorMessage  = '';
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
    notifyListeners();
  }
}
