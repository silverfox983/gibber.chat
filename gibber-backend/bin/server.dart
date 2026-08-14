import 'dart:io';
import 'package:args/args.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:gibber_backend/src/handlers/api_router.dart';
import 'package:gibber_backend/src/services/database_service.dart';
import 'package:gibber_backend/src/services/xmpp_registrar.dart';
import 'package:gibber_backend/src/services/miner_pool_service.dart';
import 'package:gibber_backend/src/services/entitlement_service.dart';

void main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('port', abbr: 'p', defaultsTo: Platform.environment['GIBBER_PORT'] ?? '8080')
    ..addOption('host', abbr: 'h', defaultsTo: Platform.environment['GIBBER_HOST'] ?? '0.0.0.0')
    ..addOption('db-path', defaultsTo: Platform.environment['GIBBER_DB_PATH'] ?? 'gibber_backend.db')
    ..addOption('config', abbr: 'c', defaultsTo: Platform.environment['GIBBER_PROSODY_CONFIG'] ?? 'config/prosody.cfg.lua')
    ..addOption('prosody-ctl', defaultsTo: Platform.environment['GIBBER_PROSODYCTL_PATH'] ?? 'prosodyctl')
    ..addOption('docker-container', defaultsTo: Platform.environment['GIBBER_DOCKER_CONTAINER'] ?? 'gibber_xmpp')
    ..addFlag('use-docker', defaultsTo: Platform.environment['GIBBER_USE_DOCKER'] == '1')
    ..addOption('mode', defaultsTo: Platform.environment['GIBBER_REGISTRATION_MODE'] ?? 'prosodyctl', allowed: ['prosodyctl', 'http', 'internal'])
    ..addOption('prosody-url', defaultsTo: Platform.environment['GIBBER_PROSODY_URL'] ?? 'http://localhost:5280')
    ..addOption('admin-key', defaultsTo: Platform.environment['GIBBER_ADMIN_KEY'] ?? 'gibber-admin-key')
    ..addFlag('reset-db', abbr: 'r', defaultsTo: false);

  final result = parser.parse(args);
  final port = int.parse(result['port'] as String);
  final host = result['host'] as String;
  final dbPath = result['db-path'] as String;
  final configPath = result['config'] as String;
  final prosodyCtlPath = result['prosody-ctl'] as String;
  final dockerContainer = result['docker-container'] as String;
  final useDocker = result['use-docker'] as bool;
  final adminKey = result['admin-key'] as String;
  final resetDb = result['reset-db'] as bool;

  final db = DatabaseService(dbPath);
  await db.initialize(reset: resetDb);

  final modeStr = result['mode'] as String;
  final mode = modeStr == 'http' ? RegistrationMode.http
      : modeStr == 'internal' ? RegistrationMode.internal
      : RegistrationMode.prosodyctl;
  final prosodyUrl = result['prosody-url'] as String;

  final xmppRegistrar = XmppRegistrar(
    configPath: configPath,
    prosodyCtlPath: prosodyCtlPath,
    dockerContainer: dockerContainer,
    useDocker: useDocker,
    mode: mode,
    prosodyHttpUrl: prosodyUrl,
  );
  final minerPool = MinerPoolService(db: db);
  final entitlementSvc = BackendEntitlementService(db: db);

  final apiRouter = ApiRouter(
    db: db,
    xmppRegistrar: xmppRegistrar,
    minerPool: minerPool,
    entitlementService: entitlementSvc,
    adminApiKey: adminKey,
  );

  final handler = const shelf.Pipeline()
      .addMiddleware(shelf.logRequests())
      .addMiddleware(corsHeaders(headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Admin-Key',
      }))
      .addHandler(apiRouter.handler);

  final server = await io.serve(handler, host, port);
  print('Gibber backend running on http://${server.address.host}:${server.port}');
  print('  XMPP domain: ${xmppRegistrar.domain}');
  print('  Database: $dbPath');
}