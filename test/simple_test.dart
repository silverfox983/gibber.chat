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

  testWidgets('App renders without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatApp());
    await tester.pump(const Duration(seconds: 2));

    expect(true, isTrue);
  });
}
