import 'dart:js_interop';
import 'dart:convert';

@JS('kafaConfirmPayment')
external JSPromise<JSString> _kafaConfirmPayment(String clientSecret);

/// Web implementation: calls kafaConfirmPayment() defined in index.html.
Future<void> confirmStripePayment(String clientSecret) async {
  final resultJson = await _kafaConfirmPayment(clientSecret).toDart;
  final result = jsonDecode(resultJson.toDart) as Map<String, dynamic>;
  if (result['ok'] != true) {
    throw Exception(result['msg'] ?? 'Payment failed');
  }
}
