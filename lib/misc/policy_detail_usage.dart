// ──────────────────────────────────────────────────────────────────────────────
// KAFA — PolicyDetailScreen usage examples
// Drop this into a member dashboard or policy list screen.
// ──────────────────────────────────────────────────────────────────────────────

import '../screens/policy_detail_screen.dart';

// ── Example: Navigate from a policy list tile ─────────────────────────────────
//
// ListTile(
//   title: Text('Plan Familyal'),
//   onTap: () {
//     Navigator.push(
//       context,
//       MaterialPageRoute(
//         builder: (_) => PolicyDetailScreen(policy: samplePolicy),
//       ),
//     );
//   },
// );


// ── Sample policy object (replace with your DynamoDB fetch) ───────────────────
final samplePolicy = PolicyDetail(
  policyId:    'POL-2024-001',
  memberId:    'M-001',
  memberName:  'Jean-Pierre Mathieu',
  planName:    'Plan Familyal',
  monthlyPremiumCents: 2500,       // $25.00/month
  coverageAmountCents: 500000,     // $5,000 coverage
  startDate:   '2024-01-01',
  nextDueDate: '2026-05-01',
  nextPeriodStart: '2026-05-01',
  nextPeriodEnd:   '2026-05-31',
  status: PolicyStatus.active,
  beneficiaries: const [
    Beneficiary(
      name:         'Marie Mathieu',
      relationship: 'Spouse',
      percentage:   60,
    ),
    Beneficiary(
      name:         'Claudette Mathieu',
      relationship: 'Child',
      percentage:   40,
    ),
  ],
  paymentHistory: const [
    PaymentHistory(
      paymentId:    'PAY-3F9A1B2C',
      date:         'Apr 1, 2026',
      amountCents:  2500,
      status:       'SUCCEEDED',
      period:       'Apr 2026',
    ),
    PaymentHistory(
      paymentId:    'PAY-2D8E4A1F',
      date:         'Mar 1, 2026',
      amountCents:  2500,
      status:       'SUCCEEDED',
      period:       'Mar 2026',
    ),
    PaymentHistory(
      paymentId:    'PAY-1C7B3E9D',
      date:         'Feb 1, 2026',
      amountCents:  2500,
      status:       'FAILED',
      period:       'Feb 2026',
    ),
  ],
);


// ── Fetching from DynamoDB via your Lambda ────────────────────────────────────
//
// Future<PolicyDetail> fetchPolicy(String policyId, String memberId) async {
//   final response = await http.get(
//     Uri.parse('$baseUrl/policies/$policyId?memberId=$memberId'),
//   );
//   final json = jsonDecode(response.body);
//   return PolicyDetail(
//     policyId:    json['policy_id'],
//     memberId:    json['member_id'],
//     memberName:  json['member_name'],
//     planName:    json['plan_name'],
//     monthlyPremiumCents: json['monthly_premium_cents'],
//     coverageAmountCents: json['coverage_amount_cents'],
//     startDate:   json['start_date'],
//     nextDueDate: json['next_due_date'],
//     nextPeriodStart: json['next_period_start'],
//     nextPeriodEnd:   json['next_period_end'],
//     status: PolicyStatus.values.byName(json['status'].toLowerCase()),
//     beneficiaries: (json['beneficiaries'] as List)
//         .map((b) => Beneficiary(
//               name:         b['name'],
//               relationship: b['relationship'],
//               percentage:   b['percentage'],
//             ))
//         .toList(),
//     paymentHistory: (json['payment_history'] as List)
//         .map((p) => PaymentHistory(
//               paymentId:   p['payment_id'],
//               date:        p['date'],
//               amountCents: p['amount_cents'],
//               status:      p['status'],
//               period:      p['period'],
//             ))
//         .toList(),
//   );
// }
