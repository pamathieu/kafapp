import 'package:flutter_test/flutter_test.dart';
import 'package:member_management/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const KAFAMemberApp());
  });
}
