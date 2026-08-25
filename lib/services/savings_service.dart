import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../stripe_confirmer.dart'
    if (dart.library.html) '../stripe_confirmer_web.dart';
import 'dev_env.dart';

class SavingsResult {
  final bool success;
  final String? depositId;
  final String? errorMessage;

  const SavingsResult({
    required this.success,
    this.depositId,
    this.errorMessage,
  });
}

/// Handles the full Stripe savings-deposit flow:
///   1. POST to KAFA Lambda → get client_secret
///   2. Confirm payment via Stripe Flutter SDK
///   3. Return result to caller
class SavingsService {
  static const String _baseUrl = kApiBaseUrl;

  Future<SavingsResult> deposit({
    required String memberId,
    required int amountCents,
  }) async {
    try {
      final intentResponse = await _createSavingsIntent(
        memberId: memberId,
        amountCents: amountCents,
      );

      final clientSecret = intentResponse['client_secret'] as String;
      final depositId = intentResponse['deposit_id'] as String;

      await confirmStripePayment(clientSecret);

      return SavingsResult(success: true, depositId: depositId);
    } on SavingsServiceException catch (e) {
      return SavingsResult(success: false, errorMessage: e.message);
    } catch (e) {
      debugPrint('[SavingsService] Unexpected error: $e');
      return SavingsResult(
        success: false,
        errorMessage: 'Unable to process deposit.',
      );
    }
  }

  Future<Map<String, dynamic>> _createSavingsIntent({
    required String memberId,
    required int amountCents,
  }) async {
    final response = await http.post(
      Uri.parse('$_baseUrl${devPath('/member/savings/create-intent')}'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'member_id': memberId,
        'amount_cents': amountCents,
      }),
    );

    if (response.statusCode != 200) {
      String message = 'Failed to start deposit (${response.statusCode}).';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        message = body['error'] as String? ?? message;
      } catch (_) {}
      throw SavingsServiceException(message);
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSavingsAccount(String memberId) async {
    final uri = Uri.parse('$_baseUrl${devPath('/member/savings')}?memberId=${Uri.encodeComponent(memberId)}');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Failed to load savings: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

class SavingsServiceException implements Exception {
  final String message;
  const SavingsServiceException(this.message);
}
