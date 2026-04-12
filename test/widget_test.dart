import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gibber/main.dart';
import 'package:gibber/services/database_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.testPath = ':memory:';
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App loads successfully and shows login UI', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ChatApp());
    
    // Drain async init
    for (int i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    
    await tester.pumpAndSettle();

    expect(find.text('Gibber'), findsOneWidget);
    expect(find.text('Connect Now'), findsOneWidget);
  });
}
