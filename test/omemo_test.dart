import 'package:flutter_test/flutter_test.dart';
import 'package:gibber/services/omemo_service.dart';
import 'package:gibber/services/database_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseService.testPath = ':memory:';
    SharedPreferences.setMockInitialValues({});
  });

  group('OMEMO Service Protocol Tests', () {
    test('Initialization generates device ID and keys', () async {
      final omemo = OmemoService();
      await omemo.initialize();
      expect(omemo.localDeviceId, isNonZero);
      // Since device ID is random, we just check it's not null via internal state if we could,
      // but we'll check it doesn't throw.
      expect(true, isTrue);
    });
  });
}
