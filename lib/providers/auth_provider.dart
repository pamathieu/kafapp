import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  bool        _isLoggedIn    = false;
  bool        _isLoading     = false;
  String      _adminUsername = '';
  String      _errorMessage  = '';
  ApiService? _apiService;

  static const String _loginUrl =
      'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod/auth/login';

  bool        get isLoggedIn    => _isLoggedIn;
  bool        get isLoading     => _isLoading;
  String      get adminUsername => _adminUsername;
  String      get errorMessage  => _errorMessage;
  ApiService? get apiService    => _apiService;

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

        // AWS credentials are returned by the Lambda and held in memory only.
        // They are never written to disk or included in source code.
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

  void logout() {
    _isLoggedIn    = false;
    _adminUsername = '';
    _apiService    = null;
    _errorMessage  = '';
    notifyListeners();
  }
}