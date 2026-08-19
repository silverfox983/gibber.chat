import 'package:gibber_backend/src/services/database_service.dart';
import 'package:gibber_backend/src/services/slidge_process_manager.dart';
import 'package:gibber_backend/src/services/prosody_component_manager.dart';
import 'package:gibber_backend/src/services/user_gateway_service.dart';

class GatewayOrchestrator {
  final DatabaseService _db;
  late final SlidgeProcessManager processManager;
  late final ProsodyComponentManager prosodyManager;
  late final UserGatewayService userGatewayService;

  bool _initialized = false;

  GatewayOrchestrator(this._db);

  Future<void> initialize() async {
    if (_initialized) return;

    processManager = SlidgeProcessManager();
    prosodyManager = ProsodyComponentManager();
    await prosodyManager.initialize();

    userGatewayService = UserGatewayService(_db, processManager, prosodyManager);

    await userGatewayService.startAllEnabledGateways();

    _initialized = true;
    print('GatewayOrchestrator initialized');
  }

  Future<void> shutdown() async {
    await userGatewayService.stopAllGateways();
    _initialized = false;
    print('GatewayOrchestrator shut down');
  }
}
