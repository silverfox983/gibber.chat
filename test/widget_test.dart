import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chat_app/main.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App loads successfully and shows Login screen', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatApp());
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
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
}
