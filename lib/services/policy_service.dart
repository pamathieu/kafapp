import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../screens/policy_detail_screen.dart';

/// Fetches a full [PolicyDetail] from GET /policies/{policyId}?memberId=...
class PolicyService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://8ajfrnzdag.execute-api.us-east-1.amazonaws.com/prod',
  );

  Future<PolicyDetail> fetchPolicy({
    required String policyId,
    required String memberId,
  }) async {
    final uri = Uri.parse(
      '$_baseUrl/policies/${Uri.encodeComponent(policyId)}'
      '?memberId=${Uri.encodeComponent(memberId)}',
    );

    final response = await http.get(uri).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      final body = _tryDecode(response.body);
      throw PolicyServiceException(
        body?['error'] as String? ?? 'Failed to load policy (${response.statusCode})',
      );
    }

    final json = _tryDecode(response.body);
    if (json == null) throw const PolicyServiceException('Invalid response from server.');

    return _fromJson(json);
  }

  // ── JSON → PolicyDetail ────────────────────────────────────────────────────

  static PolicyDetail _fromJson(Map<String, dynamic> j) {
    return PolicyDetail(
      policyId:             j['policy_id'] as String,
      memberId:             j['member_id'] as String,
      memberName:           j['member_name'] as String? ?? 'Member',
      planName:             j['plan_name'] as String? ?? 'KAFA Plan',
      monthlyPremiumCents:  j['monthly_premium_cents'] as int? ?? 0,
      coverageAmountCents:  j['coverage_amount_cents'] as int? ?? 0,
      startDate:            j['start_date'] as String? ?? '',
      nextDueDate:          j['next_due_date'] as String? ?? '',
      nextPeriodStart:      j['next_period_start'] as String? ?? '',
      nextPeriodEnd:        j['next_period_end'] as String? ?? '',
      status: _parseStatus(j['status'] as String? ?? 'ACTIVE'),
      beneficiaries: _parseBeneficiaries(j['beneficiaries']),
      paymentHistory: _parsePayments(j['payment_history']),
    );
  }

  static PolicyStatus _parseStatus(String raw) {
    switch (raw.trim().toUpperCase()) {
      case 'ACTIVE':    return PolicyStatus.active;
      case 'PENDING':   return PolicyStatus.pending;
      case 'LAPSED':    return PolicyStatus.lapsed;
      case 'CANCELLED': return PolicyStatus.cancelled;
      default:          return PolicyStatus.active;
    }
  }

  static List<Beneficiary> _parseBeneficiaries(dynamic raw) {
    if (raw == null) return [];
    return (raw as List).map((b) {
      final m = b as Map<String, dynamic>;
      return Beneficiary(
        name:         m['name']         as String? ?? '',
        relationship: m['relationship'] as String? ?? '',
        percentage:   m['percentage']   as int?    ?? 0,
      );
    }).toList();
  }

  static List<PaymentHistory> _parsePayments(dynamic raw) {
    if (raw == null) return [];
    return (raw as List).map((p) {
      final m = p as Map<String, dynamic>;
      return PaymentHistory(
        paymentId:   m['payment_id']   as String? ?? '',
        date:        m['date']         as String? ?? '',
        amountCents: m['amount_cents'] as int?    ?? 0,
        status:      m['status']       as String? ?? 'PENDING',
        period:      m['period']       as String? ?? '',
      );
    }).toList();
  }

  static Map<String, dynamic>? _tryDecode(String body) {
    try {
      return jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      debugPrint('[PolicyService] Failed to decode: $body');
      return null;
    }
  }
}

class PolicyServiceException implements Exception {
  final String message;
  const PolicyServiceException(this.message);
  @override
  String toString() => message;
}
