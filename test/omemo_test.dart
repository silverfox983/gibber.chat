import 'package:flutter_test/flutter_test.dart';
import 'package:chat_app/services/omemo_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
  });

  group('OMEMO Service Protocol Tests', () {
    test('Initialization generates device ID and keys', () async {
      final omemo = OmemoService();
      await omemo.initialize();
      expect(omemo.localDeviceId, isNonZero);
    });
  });
}
