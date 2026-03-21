import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the member session locally so the member doesn't have
/// to log in again on the next visit.
/// Only the server-returned member profile is stored — never the password.
class SessionService {
  static const _kMemberKey = 'kafa_member_session';

  /// Save member data after a successful login.
  static Future<void> saveSession(Map<String, dynamic> member) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kMemberKey, jsonEncode(member));
  }

  /// Load a previously saved member session. Returns null if none exists.
  static Future<Map<String, dynamic>?> loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kMemberKey);
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Clear the session on logout.
  static Future<void> clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kMemberKey);
  }
}