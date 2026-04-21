import 'package:flutter_stripe/flutter_stripe.dart';

/// Native (non-web) implementation: uses flutter_stripe SDK.
Future<void> confirmStripePayment(String clientSecret) async {
  await Stripe.instance.confirmPayment(
    paymentIntentClientSecret: clientSecret,
    data: const PaymentMethodParams.card(
      paymentMethodData: PaymentMethodData(),
    ),
  );
}
