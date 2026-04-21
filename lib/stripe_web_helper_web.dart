import 'package:flutter/widgets.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;

bool _registered = false;

void registerStripeCardViewFactory(String publishableKey) {
  if (_registered) return;
  _registered = true;

  js.context.callMethod('kafaSetupCard', [publishableKey]);

  _registerField('kafa-card-number', 'kafaMountNumber');
  _registerField('kafa-card-expiry', 'kafaMountExpiry');
  _registerField('kafa-card-cvc',    'kafaMountCvc');
}

void _registerField(String viewType, String mountFn) {
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
    final div = html.DivElement()
      ..id = viewType
      ..style.cssText =
          'width:100%;height:100%;display:flex;align-items:center;'
          'padding:0 12px;box-sizing:border-box;pointer-events:auto;'
          'background:#FFFFFF;color:#1A1A1A;';
    Future.delayed(const Duration(milliseconds: 300), () {
      js.context.callMethod(mountFn, []);
    });
    return div;
  });
}

Widget stripeCardHtmlView()   => const HtmlElementView(viewType: 'kafa-card-number');
Widget stripeExpiryHtmlView() => const HtmlElementView(viewType: 'kafa-card-expiry');
Widget stripeCvcHtmlView()    => const HtmlElementView(viewType: 'kafa-card-cvc');
