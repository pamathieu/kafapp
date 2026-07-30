import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../stripe_confirmer.dart'
    if (dart.library.html) '../stripe_confirmer_web.dart';
import 'dev_env.dart';

/// Preferred share APR bracket table — mirrors
/// lambda/create_share_intent.py's _calculate_preferred_apr exactly, used
/// here only to preview the rate before the member confirms payment. The
/// backend recomputes and stores the authoritative value.
double previewPreferredApr(int amountCents) {
  final dollars = amountCents / 100;
  if (dollars >= 11000) return 12.0;
  if (dollars >= 5001) return 10.0;
  if (dollars >= 3001) return 7.0;
  if (dollars >= 2001) return 6.0;
  if (dollars >= 1001) return 5.0;
  return 4.0;
}

class ShareResult {
  final bool success;
  final String? shareId;
  final double? apr;
  final String? errorMessage;

  const ShareResult({
    required this.success,
    this.shareId,
    this.apr,
    this.errorMessage,
  });
}

/// Handles the full Stripe share-purchase flow:
///   1. POST to KAFA Lambda → get client_secret
///   2. Confirm payment via Stripe Flutter SDK
///   3. Return result to caller
class ShareService {
  static const String _baseUrl = kApiBaseUrl;

  Future<ShareResult> purchaseShare({
    required String memberId,
    required String shareType, // 'membership' | 'preferred'
    required int amountCents,
  }) async {
    try {
      final intentResponse = await _createShareIntent(
        memberId: memberId,
        shareType: shareType,
        amountCents: amountCents,
      );

      final clientSecret = intentResponse['client_secret'] as String;
      final shareId = intentResponse['share_id'] as String;
      final apr = (intentResponse['apr'] as num).toDouble();

      await confirmStripePayment(clientSecret);

      return ShareResult(success: true, shareId: shareId, apr: apr);
    } on ShareServiceException catch (e) {
      return ShareResult(success: false, errorMessage: e.message);
    } catch (e) {
      debugPrint('[ShareService] Unexpected error: $e');
      return ShareResult(
        success: false,
        errorMessage: 'Unable to process payment.',
      );
    }
  }

  Future<Map<String, dynamic>> _createShareIntent({
    required String memberId,
    required String shareType,
    required int amountCents,
  }) async {
    final response = await http.post(
      Uri.parse('$_baseUrl${devPath('/member/shares/create-intent')}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'member_id': memberId,
        'share_type': shareType,
        'amount_cents': amountCents,
      }),
    );

    if (response.statusCode != 200) {
      String message = 'Failed to start share purchase (${response.statusCode}).';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        message = body['error'] as String? ?? message;
      } catch (_) {}
      throw ShareServiceException(message);
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> getShares(String memberId) async {
    final uri = Uri.parse('$_baseUrl${devPath('/member/shares')}?memberId=${Uri.encodeComponent(memberId)}');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Failed to load shares: ${response.statusCode}');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(data['shares'] ?? []);
  }
}

class ShareServiceException implements Exception {
  final String message;
  const ShareServiceException(this.message);
}
