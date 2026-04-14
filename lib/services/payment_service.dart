import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:http/http.dart' as http;

/// Result object returned from [PaymentService.processPayment]
class PaymentResult {
  final bool success;
  final String? paymentId;
  final String? receiptUrl;
  final String? errorMessage;

  const PaymentResult({
    required this.success,
    this.paymentId,
    this.receiptUrl,
    this.errorMessage,
  });
}

/// Handles the full Stripe payment flow:
///   1. POST to KAFA Lambda → get client_secret
///   2. Confirm payment via Stripe Flutter SDK
///   3. Return result to caller
class PaymentService {
  // TODO: Replace with your API Gateway URL (from Terraform output)
  static const String _baseUrl =
      'https://your-api-id.execute-api.us-east-1.amazonaws.com/prod';

  /// Initiates and confirms a member premium payment.
  ///
  /// [memberId]    - KAFA member ID (e.g. "M-001")
  /// [policyId]    - Policy being paid for (e.g. "POL-2024-001")
  /// [amountCents] - Amount in cents (e.g. 2500 = $25.00)
  /// [periodStart] - Coverage start date "2026-04-01"
  /// [periodEnd]   - Coverage end date "2026-04-30"
  Future<PaymentResult> processPayment({
    required String memberId,
    required String policyId,
    required int amountCents,
    required String periodStart,
    required String periodEnd,
    String currency = 'usd',
  }) async {
    try {
      // ── Step 1: Create PaymentIntent on our Lambda ──────────────────────
      final intentResponse = await _createPaymentIntent(
        memberId: memberId,
        policyId: policyId,
        amountCents: amountCents,
        currency: currency,
        periodStart: periodStart,
        periodEnd: periodEnd,
      );

      final clientSecret = intentResponse['client_secret'] as String;
      final paymentId = intentResponse['payment_id'] as String;

      // ── Step 2: Confirm payment via Stripe SDK ──────────────────────────
      await Stripe.instance.confirmPayment(
        paymentIntentClientSecret: clientSecret,
        data: const PaymentMethodParams.card(
          paymentMethodData: PaymentMethodData(),
        ),
      );

      return PaymentResult(
        success: true,
        paymentId: paymentId,
      );
    } on StripeException catch (e) {
      debugPrint('[PaymentService] Stripe error: ${e.error.message}');
      return PaymentResult(
        success: false,
        errorMessage: e.error.message ?? 'Payment failed. Please try again.',
      );
    } on PaymentServiceException catch (e) {
      return PaymentResult(success: false, errorMessage: e.message);
    } catch (e) {
      debugPrint('[PaymentService] Unexpected error: $e');
      return PaymentResult(
        success: false,
        errorMessage: 'An unexpected error occurred. Please try again.',
      );
    }
  }

  // ── Private: call Lambda to create PaymentIntent ──────────────────────────
  Future<Map<String, dynamic>> _createPaymentIntent({
    required String memberId,
    required String policyId,
    required int amountCents,
    required String currency,
    required String periodStart,
    required String periodEnd,
  }) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/payments/create-intent'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'member_id': memberId,
        'policy_id': policyId,
        'amount_cents': amountCents,
        'currency': currency,
        'period_start': periodStart,
        'period_end': periodEnd,
      }),
    );

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body);
      throw PaymentServiceException(
        body['error'] ?? 'Failed to initialize payment.',
      );
    }

    return jsonDecode(response.body) as Map<String, dynamic>;
  }
}

class PaymentServiceException implements Exception {
  final String message;
  const PaymentServiceException(this.message);
}
