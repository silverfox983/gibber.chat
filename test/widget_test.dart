import 'package:flutter_test/flutter_test.dart';
import 'package:chat_app/main.dart';

void main() {
  testWidgets('App loads successfully and shows Login screen', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    // ChatApp now includes its own MultiProvider context internally.
    await tester.pumpWidget(const ChatApp());

    // Verify that the app title 'Antigravity Chat' is displayed.
    expect(find.text('Antigravity Chat'), findsOneWidget);

    // Verify that the subtitle is present.
    expect(find.text('Connect with XMPP or IRC'), findsOneWidget);

    // Verify that the login button is present.
    expect(find.text('Login Now'), findsOneWidget);

    // Verify that protocol toggles are present.
    expect(find.text('XMPP'), findsOneWidget);
    expect(find.text('IRC'), findsOneWidget);
  });
}
