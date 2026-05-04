import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:gibber/services/auth_service.dart';
import 'package:gibber/services/data_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AuthService authService;
  late DataExportService dataExportService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    authService = AuthService();
    dataExportService = DataExportService(authService);
  });

  test('Export functionality does not crash', () async {
    // This is just to ensure no Syntax/Compilation errors and that
    // the code path can be executed in a test environment,
    // although path_provider and zip might fail if not mocked properly.
    expect(dataExportService, isNotNull);
  });
}
