import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';

/// Persists the member session locally so the member doesn't have
/// to log in again on the next visit.
/// Only the server-returned member profile is stored — never the password.
class SessionService {
  static const _kMemberKey = 'kafa_member_session';

  /// Save member data after a successful login.
  static Future<void> saveSession(Map<String, dynamic> member) async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('SharedPreferences timeout'),
      );
      await prefs.setString(_kMemberKey, jsonEncode(member));
    } catch (e) {
      debugPrint('Error saving session: $e');
      rethrow;
    }
  }

  /// Load a previously saved member session. Returns null if none exists.
  static Future<Map<String, dynamic>?> loadSession() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('SharedPreferences timeout'),
      );
      final raw = prefs.getString(_kMemberKey);
      if (raw == null || raw.isEmpty) return null;
      
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      
      // Validate that decoded data has required fields
      if ((decoded['memberId'] as String?)?.isEmpty ?? true) return null;
      if ((decoded['full_name'] as String?)?.isEmpty ?? true) return null;
      
      return decoded;
    } catch (e) {
      debugPrint('Error loading session: $e');
      // Clear corrupted session
      try {
        await clearSession();
      } catch (_) {}
      return null;
    }
  }

  /// Clear the session on logout.
  static Future<void> clearSession() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('SharedPreferences timeout'),
      );
      await prefs.remove(_kMemberKey);
    } catch (e) {
      debugPrint('Error clearing session: $e');
    }
  }
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);
  
  @override
  String toString() => message;
}