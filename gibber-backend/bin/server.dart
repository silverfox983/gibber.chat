import 'dart:async';
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
import 'package:gibber_backend/src/services/jwt_service.dart';

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

void _handleXmppWebSocket(WebSocketChannel webSocket, String prosodyUrl, String domain, {bool enableSasl2 = true}) {
  final prosodyUri = Uri.parse(prosodyUrl);
  final wsScheme = prosodyUri.scheme == 'https' ? 'wss' : 'ws';
  final wsPort = prosodyUri.port;
  final wsUrl = '$wsScheme://${prosodyUri.host}:${wsPort > 0 ? wsPort : (prosodyUri.scheme == 'https' ? 5281 : 5280)}/xmpp-websocket';

  print('XMPP WS proxy: Connecting to Prosody at $wsUrl (Host: $domain)');

  // Buffer for <close> frames from Prosody. Prosody sometimes sends <close>
  // before <failure> on auth errors. We buffer <close> briefly so the <failure>
  // reaches the client first, allowing xmpp_stone to detect auth failures.
  String? bufferedClose;
  Timer? closeTimer;

  WebSocket.connect(wsUrl, headers: {'Host': domain}, protocols: ['xmpp']).then((prosodyWs) {
    print('XMPP WS proxy: Connected to Prosody');

    prosodyWs.listen(
      (data) {
        if (data is String) {
          String content = data;

          final preview = content.length > 300 ? '${content.substring(0, 300)}...' : content;
          print('XMPP WS proxy: [S->C] ${preview.replaceAll('\n', ' ')}');

          // Transform ALL stream:features packets for xmpp_stone compatibility
          // xmpp_stone processes every stream:features it receives, including
          // post-auth features after SASL re-open
          if (content.contains('<stream:features') || content.contains('<features xmlns')) {
            final originalPreview = content.length > 500 ? '${content.substring(0, 500)}...' : content;
            print('XMPP WS proxy: Original stream features from Prosody: ${originalPreview.replaceAll('\n', ' ')}');

            // 1. Strip STARTTLS (connection is already secure via WSS/proxy)
            content = content.replaceAll(RegExp(r'<starttls[^>]*>.*?</starttls>', dotAll: true), '');
            content = content.replaceAll(RegExp(r'<starttls[^>]*/>'), '');

            // 2. SASL2 <authentication> block handling
            // Always strip SASL2 from stream features since xmpp_stone only
            // supports SASL1. Extract mechanisms and inject a SASL1 <mechanisms>
            // element so the client can authenticate.
            if (content.contains(RegExp('<authentication xmlns=[\'"]urn:xmpp:sasl:2[\'"]', dotAll: true))) {
              final sasl2Mechs = RegExp(r'<mechanism>([^<]+)</mechanism>')
                  .allMatches(content)
                  .map((m) => m.group(1)!)
                  .toSet();

              content = content.replaceAll(RegExp('<authentication xmlns=[\'"]urn:xmpp:sasl:2[\'"][^>]*>.*?</authentication>', dotAll: true), '');

              if (!content.contains('<mechanisms')) {
                final mechs = sasl2Mechs.toList()..add('PLAIN');
                final mechsXml = mechs.map((m) => '<mechanism>$m</mechanism>').join('');
                final legacySasl = "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'>$mechsXml</mechanisms>";
                content = content.replaceFirst('<stream:features>', '<stream:features>$legacySasl');
              }
            }

            // 3. Ensure PLAIN mechanism is available for xmpp_stone SASL1 auth
            if (content.contains('<mechanisms') && !content.contains('<mechanism>PLAIN</mechanism>')) {
              content = content.replaceFirst(
                RegExp("<mechanisms xmlns=['\"]urn:ietf:params:xml:ns:xmpp-sasl['\"]>"),
                "<mechanisms xmlns='urn:ietf:params:xml:ns:xmpp-sasl'><mechanism>PLAIN</mechanism>",
              );
            }

            final transformedPreview = content.length > 500 ? '${content.substring(0, 500)}...' : content;
            print('XMPP WS proxy: Transformed stream features to client: ${transformedPreview.replaceAll('\n', ' ')}');
          }

          // If Prosody sends a <close> frame, buffer it so any subsequent
          // <failure> frames get forwarded to the client first.
          // Prosody sometimes sends <close> before <failure> on auth errors.
          if (content.contains('<close') && content.contains('urn:ietf:params:xml:ns:xmpp-framing')) {
            print('XMPP WS proxy: Buffering <close> frame from Prosody');
            if (content.contains('<failure')) {
              webSocket.sink.add(content);
            } else {
              bufferedClose = content;
              closeTimer?.cancel();
              closeTimer = Timer(const Duration(milliseconds: 200), () {
                if (bufferedClose != null) {
                  print('XMPP WS proxy: Forwarding buffered <close> (no <failure> followed)');
                  webSocket.sink.add(bufferedClose!);
                  bufferedClose = null;
                }
              });
            }
          } else {
            webSocket.sink.add(content);
            if (content.contains('<failure') && bufferedClose != null) {
              print('XMPP WS proxy: Forwarding buffered <close> after <failure>');
              webSocket.sink.add(bufferedClose!);
              bufferedClose = null;
              closeTimer?.cancel();
            }
          }
        } else {
          webSocket.sink.add(data);
        }
      },
      onDone: () {
        print('XMPP WS proxy: Prosody closed connection');
        if (bufferedClose != null) {
          print('XMPP WS proxy: Forwarding buffered <close> on Prosody disconnect');
          webSocket.sink.add(bufferedClose!);
          bufferedClose = null;
        }
        closeTimer?.cancel();
        webSocket.sink.close();
      },
      onError: (e) {
        print('XMPP WS proxy: Prosody error: $e');
        closeTimer?.cancel();
        webSocket.sink.close();
      },
      cancelOnError: false,
    );

    webSocket.stream.listen(
      (data) {
        if (data is String) {
          final preview = data.length > 300 ? '${data.substring(0, 300)}...' : data;
          print('XMPP WS proxy: [C->S] ${preview.replaceAll('\n', ' ')}');
        }
        prosodyWs.add(data);
      },
      onDone: () {
        print('XMPP WS proxy: Client closed connection');
        closeTimer?.cancel();
        prosodyWs.close();
      },
      onError: (e) {
        print('XMPP WS proxy: Client error: $e');
        closeTimer?.cancel();
        prosodyWs.close();
      },
      cancelOnError: false,
    );
  }).catchError((e) {
    print('XMPP WS proxy: Failed to connect to Prosody at $wsUrl: $e');
    closeTimer?.cancel();
    webSocket.sink.close();
  });
}

void _handleJanusWebSocket(WebSocketChannel clientWs) {
  const janusWsUrl = 'ws://localhost:8188/';
  print('Janus WS proxy: Connecting to Janus at $janusWsUrl');
  WebSocket.connect(janusWsUrl).then((janusWs) {
    print('Janus WS proxy: Connected to Janus');
    janusWs.listen(
      (data) => clientWs.sink.add(data),
      onDone: () => clientWs.sink.close(),
      onError: (e) {
        print('Janus WS proxy: Janus error: $e');
        clientWs.sink.close();
      },
      cancelOnError: false,
    );
    clientWs.stream.listen(
      (data) => janusWs.add(data),
      onDone: () => janusWs.close(),
      onError: (e) {
        print('Janus WS proxy: Client error: $e');
        janusWs.close();
      },
      cancelOnError: false,
    );
  }).catchError((e) {
    print('Janus WS proxy: Failed to connect to Janus at $janusWsUrl: $e');
    clientWs.sink.close();
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
    ..addOption('mode', defaultsTo: Platform.environment['GIBBER_REGISTRATION_MODE'] ?? 'prosodyctl', allowed: ['prosodyctl', 'http', 'internal', 'xmpp'])
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
    ..addFlag('enable-sasl2', defaultsTo: Platform.environment['GIBBER_ENABLE_SASL2'] != '0', help: 'Enable SASL2 pass-through (default: true). Disable to strip SASL2 and fall back to SASL1.')
    ..addOption('jwt-secret', defaultsTo: Platform.environment['GIBBER_JWT_SECRET'] ?? '', help: 'Secret key for JWT token generation. If not set, auth/token endpoint returns 503.')
    ..addOption('janus-url', defaultsTo: Platform.environment['GIBBER_JANUS_URL'] ?? '', help: 'Janus WebSocket URL for SFU calls (e.g., ws://localhost:8188).')
    ..addOption('janus-api-key', defaultsTo: Platform.environment['GIBBER_JANUS_API_KEY'] ?? '', help: 'Janus API secret key.')
    ..addOption('turn-host', defaultsTo: Platform.environment['GIBBER_TURN_HOST'] ?? '', help: 'TURN server hostname for STUN/TURN.')
    ..addOption('turn-url', defaultsTo: Platform.environment['GIBBER_TURN_URL'] ?? '', help: 'TURN server URL (host:port) for relay.')
    ..addOption('turn-user', defaultsTo: Platform.environment['GIBBER_TURN_USER'] ?? '', help: 'TURN server username.')
    ..addOption('turn-pass', defaultsTo: Platform.environment['GIBBER_TURN_PASS'] ?? '', help: 'TURN server password/credential.')
    ..addOption('giphy-api-key', defaultsTo: Platform.environment['GIBBER_GIPHY_API_KEY'] ?? '', help: 'Giphy API key for GIF search.')
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
  final enableSasl2 = result['enable-sasl2'] as bool;
  final jwtSecret = result['jwt-secret'] as String;
  final janusUrl = result['janus-url'] as String;
  final janusApiKey = result['janus-api-key'] as String;
  final giphyApiKey = result['giphy-api-key'] as String;

  final db = DatabaseService(dbPath);
  await db.initialize(reset: resetDb);

  if (adminKey == 'gibber-admin-key' || adminKey == 'gibber-admin-key-change-in-production') {
    print('WARNING: Using default admin key. Set GIBBER_ADMIN_KEY env var to a secure value for production!');
  }
  if (stripeSecret.isNotEmpty && stripeWebhookSecret.isEmpty) {
    print('WARNING: Stripe is configured but STRIPE_WEBHOOK_SECRET is not set. Webhook signatures will not be verified!');
  }

  final modeStr = result['mode'] as String;
  final mode = modeStr == 'http' ? RegistrationMode.http
      : modeStr == 'internal' ? RegistrationMode.internal
      : modeStr == 'xmpp' ? RegistrationMode.xmpp
      : RegistrationMode.prosodyctl;

  final xmppRegistrar = XmppRegistrar(
    configPath: configPath,
    prosodyCtlPath: prosodyCtlPath,
    dockerContainer: dockerContainer,
    useDocker: useDocker,
    mode: mode,
    prosodyHttpUrl: prosodyUrl,
  );

  // Startup diagnostics for registration modes that use the shared volume
  if (mode == RegistrationMode.internal || mode == RegistrationMode.xmpp) {
    final modeLabel = mode == RegistrationMode.xmpp ? 'xmpp' : 'internal';
    final prosodyDataDir = Directory('/var/lib/prosody');
    if (prosodyDataDir.existsSync()) {
      print('Startup [$modeLabel]: /var/lib/prosody exists and is accessible');
      final domainDir = Directory('/var/lib/prosody/${xmppRegistrar.domain}');
      if (domainDir.existsSync()) {
        print('Startup [$modeLabel]: Domain directory ${domainDir.path} exists');
        final accountsDir = Directory('${domainDir.path}/accounts');
        if (accountsDir.existsSync()) {
          print('Startup [$modeLabel]: Accounts directory ${accountsDir.path} exists');
          final existingAccounts = accountsDir.listSync().whereType<File>().toList();
          print('Startup [$modeLabel]: Found ${existingAccounts.length} existing account(s)');
          for (final f in existingAccounts) {
            print('Startup [$modeLabel]:   - ${f.path}');
          }
        } else {
          print('Startup [$modeLabel]: Accounts directory does not yet exist (will be created on first registration)');
        }
      } else {
        print('Startup [$modeLabel]: Domain directory does not yet exist (will be created on first registration)');
      }
    } else {
      print('Startup [$modeLabel]: WARNING - /var/lib/prosody does not exist! Shared volume may not be mounted.');
    }
    // Also test XMPP connection for xmpp mode
    if (mode == RegistrationMode.xmpp) {
      final testWsUrl = '${prosodyUrl.replaceFirst('http', 'ws')}/xmpp-websocket';
      print('Startup [xmpp]: Registration will use in-band XMPP via $testWsUrl');
      print('Startup [xmpp]: userExists/deleteUser will use shared volume at /var/lib/prosody');
    }
  }
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

  JwtService? jwtService;
  if (jwtSecret.isNotEmpty) {
    jwtService = JwtService(secret: jwtSecret);
    print('JWT auth enabled (secret length: ${jwtSecret.length})');
  } else {
    print('JWT auth disabled (set GIBBER_JWT_SECRET or --jwt-secret to enable /auth/token and /auth/refresh)');
  }

  final apiRouter = ApiRouter(
    db: db,
    xmppRegistrar: xmppRegistrar,
    minerPool: minerPool,
    entitlementService: entitlementSvc,
    paymentService: paymentSvc,
    adminApiKey: adminKey,
    captchaService: captchaSvc,
    jwtService: jwtService,
    janusUrl: janusUrl,
    janusApiKey: janusApiKey,
    giphyApiKey: giphyApiKey,
  );

  final corsMiddleware = corsHeaders(headers: {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, Authorization, X-Admin-Key',
  });

  final xmppWsHandler = webSocketHandler(
    (webSocket, _) {
      _handleXmppWebSocket(webSocket, prosodyUrl, xmppRegistrar.domain, enableSasl2: enableSasl2);
    },
    protocols: ['xmpp'],
  );

  final janusWsHandler = webSocketHandler(
    (webSocket, _) {
      _handleJanusWebSocket(webSocket);
    },
  );

  final xmppProxyPaths = {'/xmpp-websocket', '/xmpp-websocket/', '/http-bind', '/http-bind/', '/upload', '/upload/'};
  final xmppWsPaths = {'/xmpp-websocket', '/xmpp-websocket/'};
  final janusWsPaths = {'/janus', '/janus/'};

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

          if (janusWsPaths.contains(path)) {
            final upgrade = request.headers['upgrade'];
            if (upgrade != null && upgrade.toLowerCase() == 'websocket') {
              return janusWsHandler(request);
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

          if (janusWsPaths.contains(path)) {
            final upgrade = request.headers['upgrade'];
            if (upgrade != null && upgrade.toLowerCase() == 'websocket') {
              return janusWsHandler(request);
            }
          }

          if (xmppProxyPaths.any((p) => path == p || path.startsWith('$p/'))) {
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
  if (janusUrl.isNotEmpty) {
    print('  Janus SFU: $janusUrl');
  } else {
    print('  Janus SFU: not configured (group calls will use mesh P2P fallback)');
  }
  if (webDir.isNotEmpty) {
    print('  Web dir: $webDir');
  }

  Timer.periodic(const Duration(minutes: 5), (_) {
    minerPool.deactivateStaleSessions();
  });
}