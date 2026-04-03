import 'package:flutter_test/flutter_test.dart';
import 'package:chat_app/main.dart';

void main() {
  testWidgets('App renders without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatApp());
    await tester.pump(const Duration(seconds: 2));

    // If we get here without an exception, the basic app structure works
    expect(true, isTrue);
  });
}
