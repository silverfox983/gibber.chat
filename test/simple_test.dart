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

  testWidgets('App renders without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatApp());
    await tester.pump(const Duration(seconds: 2));

    expect(true, isTrue);
  });
}
