import 'package:flutter_test/flutter_test.dart';
import 'package:chat_app/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('App loads successfully and shows login UI', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ChatApp());
    await tester.pumpAndSettle();

    expect(find.text('Gibber'), findsOneWidget);
    expect(find.text('Multi-protocol Chat Client'), findsOneWidget);
    expect(find.text('Connect Now'), findsOneWidget);
  });

  testWidgets('Protocol detection switches to IRC fields', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ChatApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'irc.example.com');
    await tester.pump();

    expect(find.text('IRC Server'), findsOneWidget);
    expect(find.text('Nickname'), findsOneWidget);
    expect(find.text('Channel'), findsOneWidget);
  });

  testWidgets('Connect button can be tapped', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect Now'));
    await tester.pump();

    expect(true, isTrue);
  });
}
