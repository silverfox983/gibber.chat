import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_static/shelf_static.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:gibber_backend/src/handlers/api_router.dart';
import 'package:gibber_backend/src/services/database_service.dart';
import 'package:gibber_backend/src/services/xmpp_registrar.dart';
import 'package:gibber_backend/src/services/miner_pool_service.dart';
import 'package:gibber_backend/src/services/entitlement_service.dart';
import 'package:gibber_backend/src/services/captcha_service.dart';
import 'package:gibber_backend/src/services/payment_service.dart';

Future<shelf.Response> _proxyToProsody(shelf.Request request, String prosodyUrl, String domain) async {
  final client = HttpClient();
  try {
    final path = request.requestedUri.path;
    final queryString = request.requestedUri.query.isEmpty ? '' : '?${request.requestedUri.query}';
    final proxiedUrl = Uri.parse('$prosodyUrl$path$queryString');

    late HttpClientRequest proxyRequest;
    switch (request.method) {
      case 'GET':
        proxyRequest = await client.getUrl(proxiedUrl);
      case 'POST':
        proxyRequest = await client.postUrl(proxiedUrl);
      case 'PUT':
        proxyRequest = await client.putUrl(proxiedUrl);
      case 'DELETE':
        proxyRequest = await client.deleteUrl(proxiedUrl);
      case 'OPTIONS':
        client.close();
        return shelf.Response.ok('', headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type, Authorization',
          'Access-Control-Max-Age': '86400',
        });
      default:
        client.close();
        return shelf.Response(405);
    }

    request.headers.forEach((name, values) {
      if (name.toLowerCase() != 'host' && name.toLowerCase() != 'transfer-encoding') {
        proxyRequest.headers.set(name, values);
      }
    });
    proxyRequest.headers.set('Host', domain);

    final body = await request.read().toList();
    if (body.isNotEmpty) {
      proxyRequest.write(body.expand((chunk) => chunk));
    }

    final proxyResponse = await proxyRequest.close();
    final responseHeaders = <String, String>{};
    proxyResponse.headers.forEach((name, values) {
      final lower = name.toLowerCase();
      if (lower != 'transfer-encoding' && lower != 'content-length') {
        responseHeaders[name] = values.join(', ');
      }
    });

    final responseBody = await proxyResponse.fold<List<int>>([], (prev, element) => prev..addAll(element));
    client.close();

    return shelf.Response(proxyResponse.statusCode, headers: responseHeaders, body: responseBody);
  } catch (e) {
    client.close(force: true);
    return shelf.Response.internalServerError(
      body: jsonEncode({'error': 'Prosody proxy error: $e'}),
      headers: {'Content-Type': 'application/json'},
    );
  }
}

void _handleXmppWebSocket(WebSocketChannel webSocket, String prosodyUrl, String domain) {
  final prosodyUri = Uri.parse(prosodyUrl);
  final wsScheme = prosodyUri.scheme == 'https' ? 'wss' : 'ws';
  final wsPort = prosodyUri.port;
  final wsUrl = '$wsScheme://${prosodyUri.host}:${wsPort > 0 ? wsPort : (prosodyUri.scheme == 'https' ? 5281 : 5280)}/xmpp-websocket';

  print('XMPP WS proxy: Connecting to Prosody at $wsUrl (Host: $domain)');

  WebSocket.connect(wsUrl, headers: {'Host': domain}, protocols: ['xmpp']).then((prosodyWs) {
    print('XMPP WS proxy: Connected to Prosody');

    prosodyWs.listen(
      (data) {
        webSocket.sink.add(data);
      },
      onDone: () {
        print('XMPP WS proxy: Prosody closed connection');
        webSocket.sink.close();
      },
      onError: (e) {
        print('XMPP WS proxy: Prosody error: $e');
        webSocket.sink.close();
      },
      cancelOnError: false,
    );

    webSocket.stream.listen(
      (data) {
        prosodyWs.add(data);
      },
      onDone: () {
        print('XMPP WS proxy: Client closed connection');
        prosodyWs.close();
      },
      onError: (e) {
        print('XMPP WS proxy: Client error: $e');
        prosodyWs.close();
      },
      cancelOnError: false,
    );
  }).catchError((e) {
    print('XMPP WS proxy: Failed to connect to Prosody at $wsUrl: $e');
    webSocket.sink.close();
  });
}

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
    ..addOption('web-dir', defaultsTo: Platform.environment['GIBBER_WEB_DIR'] ?? '')
    ..addOption('admin-key', defaultsTo: Platform.environment['GIBBER_ADMIN_KEY'] ?? 'gibber-admin-key')
    ..addOption('turnstile-secret', defaultsTo: Platform.environment['TURNSTILE_SECRET_KEY'] ?? '')
    ..addOption('turnstile-action', defaultsTo: Platform.environment['TURNSTILE_ACTION'] ?? 'signup')
    ..addOption('turnstile-hostnames', defaultsTo: Platform.environment['TURNSTILE_HOSTNAMES'] ?? 'gibberapp.online,localhost,127.0.0.1')
    ..addOption('stripe-secret', defaultsTo: Platform.environment['STRIPE_SECRET_KEY'] ?? '')
    ..addOption('stripe-webhook-secret', defaultsTo: Platform.environment['STRIPE_WEBHOOK_SECRET'] ?? '')
    ..addOption('btcpay-url', defaultsTo: Platform.environment['BTCPAY_URL'] ?? '')
    ..addOption('btcpay-api-key', defaultsTo: Platform.environment['BTCPAY_API_KEY'] ?? '')
    ..addOption('btcpay-store-id', defaultsTo: Platform.environment['BTCPAY_STORE_ID'] ?? '')
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
  final turnstileSecret = result['turnstile-secret'] as String;
  final turnstileAction = result['turnstile-action'] as String;
  final turnstileHostnames = (result['turnstile-hostnames'] as String).split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
  final stripeSecret = result['stripe-secret'] as String;
  final stripeWebhookSecret = result['stripe-webhook-secret'] as String;
  final btcpayUrl = result['btcpay-url'] as String;
  final btcpayApiKey = result['btcpay-api-key'] as String;
  final btcpayStoreId = result['btcpay-store-id'] as String;
  final resetDb = result['reset-db'] as bool;
  final webDir = result['web-dir'] as String;
  final prosodyUrl = result['prosody-url'] as String;

  final db = DatabaseService(dbPath);
  await db.initialize(reset: resetDb);

  final modeStr = result['mode'] as String;
  final mode = modeStr == 'http' ? RegistrationMode.http
      : modeStr == 'internal' ? RegistrationMode.internal
      : RegistrationMode.prosodyctl;

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
  final captchaSvc = CaptchaService(
    secretKey: turnstileSecret,
    expectedAction: turnstileAction,
    allowedHostnames: turnstileHostnames,
  );
  final paymentSvc = PaymentService(
    db: db,
    stripeSecretKey: stripeSecret,
    stripeWebhookSecret: stripeWebhookSecret,
    btcpayUrl: btcpayUrl,
    btcpayApiKey: btcpayApiKey,
    btcpayStoreId: btcpayStoreId,
  );

  final apiRouter = ApiRouter(
    db: db,
    xmppRegistrar: xmppRegistrar,
    minerPool: minerPool,
    entitlementService: entitlementSvc,
    paymentService: paymentSvc,
    adminApiKey: adminKey,
    captchaService: captchaSvc,
  );

  final corsMiddleware = corsHeaders(headers: {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Admin-Key',
  });

  final xmppWsHandler = webSocketHandler(
    (webSocket, _) {
      _handleXmppWebSocket(webSocket, prosodyUrl, xmppRegistrar.domain);
    },
    protocols: ['xmpp'],
  );

  final xmppProxyPaths = {'/xmpp-websocket', '/xmpp-websocket/', '/http-bind', '/http-bind/'};
  final xmppWsPaths = {'/xmpp-websocket', '/xmpp-websocket/'};

  const assetExtensions = {
    '.js', '.mjs', '.wasm', '.css', '.png', '.jpg', '.jpeg', '.gif', '.svg',
    '.ico', '.json', '.woff2', '.woff', '.ttf', '.eot', '.otf', '.map',
    '.mp3', '.wav', '.ogg', '.webm', '.mp4', '.webp', '.pdf', '.zip',
  };

  bool isAssetRequest(String path) {
    final lastDot = path.lastIndexOf('.');
    if (lastDot == -1) return false;
    final ext = path.substring(lastDot).toLowerCase();
    return assetExtensions.contains(ext);
  }

  shelf.Handler handler;
  if (webDir.isNotEmpty && Directory(webDir).existsSync()) {
    final staticHandler = createStaticHandler(
      webDir,
      defaultDocument: 'index.html',
    );

    final indexFile = File('$webDir/index.html');
    final indexBytes = indexFile.existsSync() ? indexFile.readAsStringSync() : '';

    handler = const shelf.Pipeline()
        .addMiddleware(shelf.logRequests())
        .addMiddleware(corsMiddleware)
        .addHandler((request) async {
          final path = request.requestedUri.path;

          if (xmppWsPaths.contains(path)) {
            final upgrade = request.headers['upgrade'];
            if (upgrade != null && upgrade.toLowerCase() == 'websocket') {
              return xmppWsHandler(request);
            }
          }

          if (xmppProxyPaths.any((p) => path == p || path.startsWith('$p/') )) {
            return _proxyToProsody(request, prosodyUrl, xmppRegistrar.domain);
          }

          final apiResponse = await apiRouter.handler(request);
          if (apiResponse.statusCode != 404) {
            return apiResponse;
          }
          if (request.method == 'GET') {
            final staticResponse = await staticHandler(request);
            if (staticResponse.statusCode == 200) {
              return staticResponse;
            }
            if (indexBytes.isNotEmpty && !isAssetRequest(path)) {
              return shelf.Response.ok(
                indexBytes,
                headers: {'Content-Type': 'text/html; charset=utf-8'},
              );
            }
          }
          return apiResponse;
        });

    print('Serving web frontend from: $webDir');
  } else {
    handler = const shelf.Pipeline()
        .addMiddleware(shelf.logRequests())
        .addMiddleware(corsMiddleware)
        .addHandler((request) async {
          final path = request.requestedUri.path;

          if (xmppWsPaths.contains(path)) {
            final upgrade = request.headers['upgrade'];
            if (upgrade != null && upgrade.toLowerCase() == 'websocket') {
              return xmppWsHandler(request);
            }
          }

          if (xmppProxyPaths.any((p) => path == p || path.startsWith('$p/') )) {
            return _proxyToProsody(request, prosodyUrl, xmppRegistrar.domain);
          }

          return apiRouter.handler(request);
        });
  }

  final server = await io.serve(handler, host, port);
  print('Gibber backend running on http://${server.address.host}:${server.port}');
  print('  XMPP domain: ${xmppRegistrar.domain}');
  print('  Database: $dbPath');
  print('  Prosody proxy: $prosodyUrl');
  if (webDir.isNotEmpty) {
    print('  Web dir: $webDir');
  }
}