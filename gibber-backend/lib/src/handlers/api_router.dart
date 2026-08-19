import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:gibber_backend/src/services/database_service.dart';
import 'package:gibber_backend/src/services/xmpp_registrar.dart';
import 'package:gibber_backend/src/services/miner_pool_service.dart';
import 'package:gibber_backend/src/services/entitlement_service.dart';
import 'package:gibber_backend/src/services/captcha_service.dart';
import 'package:gibber_backend/src/services/rate_limiter.dart';
import 'package:gibber_backend/src/services/payment_service.dart';
import 'package:gibber_backend/src/services/input_validator.dart';
import 'package:gibber_backend/src/services/health_service.dart';
import 'package:gibber_backend/src/services/jwt_service.dart';
import 'package:gibber_backend/src/services/user_gateway_service.dart';
import 'package:uuid/uuid.dart';

extension _RequestIp on Request {
  String? get ip {
    final forwarded = headers['x-forwarded-for'];
    if (forwarded != null) {
      final ips = forwarded.split(',');
      return ips.first.trim();
    }
    final realIp = headers['x-real-ip'];
    if (realIp != null) return realIp;
    return context['shelf.remote_address']?.toString();
  }
}

class ApiRouter {
  final DatabaseService db;
  final XmppRegistrar xmppRegistrar;
  final MinerPoolService minerPool;
  final BackendEntitlementService entitlementService;
  final PaymentService paymentService;
  final String adminApiKey;
  final CaptchaService captchaService;
  final HealthService healthService;
  final JwtService? jwtService;
  final UserGatewayService userGatewayService;
  final _uuid = const Uuid();
  final RateLimiter _registerLimiter = RateLimiter(maxRequests: 3, window: Duration(hours: 1));
  final RateLimiter _checkLimiter = RateLimiter(maxRequests: 20, window: Duration(minutes: 1));
  final RateLimiter _minerLimiter = RateLimiter(maxRequests: 30, window: Duration(minutes: 1));
  final RateLimiter _paymentLimiter = RateLimiter(maxRequests: 10, window: Duration(minutes: 1));
  final RateLimiter _gatewayLimiter = RateLimiter(maxRequests: 20, window: Duration(minutes: 1));
  final RateLimiter _entitlementLimiter = RateLimiter(maxRequests: 30, window: Duration(minutes: 1));
  final RateLimiter _redeemLimiter = RateLimiter(maxRequests: 5, window: Duration(hours: 1));
  final RateLimiter _authLimiter = RateLimiter(maxRequests: 10, window: Duration(minutes: 1));
  final RateLimiter _sfuLimiter = RateLimiter(maxRequests: 30, window: Duration(minutes: 1));
  final String? janusApiKey;
  final String? janusUrl;
  final String? giphyApiKey;

  String? get _effectiveJanusApiKey =>
      janusApiKey ?? Platform.environment['GIBBER_JANUS_API_KEY'] ?? '';
  String? get _effectiveJanusUrl =>
      janusUrl ?? Platform.environment['GIBBER_JANUS_URL'] ?? '';

  ApiRouter({
    required this.db,
    required this.xmppRegistrar,
    required this.minerPool,
    required this.entitlementService,
    required this.paymentService,
    required this.userGatewayService,
    this.adminApiKey = 'gibber-admin-key',
    this.janusApiKey,
    this.janusUrl,
    this.giphyApiKey,
    CaptchaService? captchaService,
    JwtService? jwtService,
  }) : captchaService = captchaService ?? CaptchaService(),
       jwtService = jwtService,
       healthService = HealthService(db: db, xmppRegistrar: xmppRegistrar) {
    _setupRoutes();
  }

  Handler get handler => _router.call;

  final Router _router = Router();

  void _setupRoutes() {
    _router.get('/config', _handleConfig);
    _router.post('/auth/token', _handleAuthToken);
    _router.post('/auth/refresh', _handleAuthRefresh);
    _router.post('/register', _handleRegister);
    _router.post('/register/check', _handleCheckUser);
    _router.get('/entitlements/<jid>', _handleGetEntitlement);
    _router.post('/redeem', _handleRedeem);
    _router.post('/gateways/authorize', _handleGatewayAuthorize);
    _router.get('/gateways/check/<jid>/<protocol>', _handleGatewayCheck);
    _router.post('/miner/register', _handleMinerRegister);
    _router.post('/miner/submit', _handleMinerSubmit);
    _router.post('/miner/heartbeat', _handleMinerHeartbeat);
    _router.get('/miner/stats/<jid>', _handleMinerStats);
    _router.get('/pricing', _handlePricing);
    _router.post('/payments/stripe/checkout', _handleStripeCheckout);
    _router.post('/payments/btcpay/invoice', _handleBtcpayInvoice);
    _router.post('/payments/stripe/webhook', _handleStripeWebhook);
    _router.post('/payments/btcpay/webhook', _handleBtcpayWebhook);
    _router.get('/subscription/<jid>', _handleGetSubscription);
    _router.post('/subscription/<jid>/cancel', _handleCancelSubscription);
    _router.post('/password/change', _handlePasswordChange);
    _router.post('/account/delete', _handleAccountDelete);
    _router.post('/codes', _handleGenerateCode);
    _router.get('/codes', _handleListCodes);
    _router.post('/sfu/create-room', _handleSfuCreateRoom);
    _router.post('/sfu/token', _handleSfuToken);
    _router.get('/sfu/ice-servers', _handleSfuIceServers);
    _router.get('/health', _handleHealth);
    _router.get('/gateways', _handleListGateways);
    _router.post('/gateways/configure', _handleConfigureGateway);
    _router.post('/gateways/enable', _handleEnableGateway);
    _router.post('/gateways/disable', _handleDisableGateway);
    _router.get('/user/<jid>/gateways', _handleListUserGateways);
    _router.get('/user/<jid>/gateways/<type>', _handleGetUserGateway);
    _router.put('/user/<jid>/gateways/<type>', _handleConfigureUserGateway);
    _router.delete('/user/<jid>/gateways/<type>', _handleDeleteUserGateway);
    _router.post('/user/<jid>/gateways/<type>/enable', _handleEnableUserGateway);
    _router.post('/user/<jid>/gateways/<type>/disable', _handleDisableUserGateway);
    _router.post('/gateways/<type>/test', _handleTestGateway);
  }

  // XMPP Registration
  Future<Response> _handleRegister(Request request) async {
    try {
      final clientIp = request.ip ?? 'unknown';
      if (!_registerLimiter.allow(clientIp)) {
        print('Registration rate limited for IP: $clientIp');
        return Response(429, body: jsonEncode({'error': 'Too many registration attempts. Please try again later.'}), headers: _jsonHeaders);
      }

      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final username = body['username'] as String?;
      final password = body['password'] as String?;
      final host = body['host'] as String?;
      final captchaToken = body['captchaToken'] as String?;

      final usernameError = InputValidator.validateUsername(username);
      if (usernameError != null) {
        return Response.badRequest(body: jsonEncode({'error': usernameError}), headers: _jsonHeaders);
      }

      final passwordError = InputValidator.validatePassword(password);
      if (passwordError != null) {
        return Response.badRequest(body: jsonEncode({'error': passwordError}), headers: _jsonHeaders);
      }

      final hostError = InputValidator.validateHost(host);
      if (hostError != null) {
        return Response.badRequest(body: jsonEncode({'error': hostError}), headers: _jsonHeaders);
      }

      print('Registration request: username=$username, host=$host, ip=$clientIp, captchaEnabled=${captchaService.enabled}, hasCaptchaToken=${captchaToken != null}');

      if (captchaService.enabled && (captchaToken == null || captchaToken.isEmpty)) {
        print('Registration rejected: captcha required but no token provided');
        return Response(403, body: jsonEncode({'error': 'Captcha verification required'}), headers: _jsonHeaders);
      }

      if (captchaService.enabled && !await captchaService.verifyToken(captchaToken!, remoteIp: clientIp)) {
        print('Registration rejected: captcha verification failed');
        return Response(403, body: jsonEncode({'error': 'Captcha verification failed'}), headers: _jsonHeaders);
      }

      print('Calling xmppRegistrar.register(username=$username, host=$host)');
      final result = await xmppRegistrar.register(username!, password!, host: host);
      print('Registration result: success=${result.success}, jid=${result.jid}, message=${result.message}');

      if (!result.success) {
        return Response(
          409,
          body: jsonEncode({'error': result.message, 'jid': result.jid}),
          headers: _jsonHeaders,
        );
      }

      final jid = result.jid;

      if (jwtService == null) {
        print('Registration warning: JWT auth not configured, returning without tokens');
        return Response.ok(
          jsonEncode({'jid': jid, 'message': result.message}),
          headers: _jsonHeaders,
        );
      }

      final entitlement = await entitlementService.getEntitlement(jid);
      final accessToken = jwtService!.generateToken(jid, tier: entitlement.tier);
      final refreshToken = jwtService!.generateRefreshToken(jid);

      _ensureUser(jid);

      print('Registration success: issued JWT tokens for $jid');
      return Response.ok(
        jsonEncode({
          'jid': jid,
          'accessToken': accessToken,
          'refreshToken': refreshToken,
          'message': result.message,
          'tier': entitlement.tier,
        }),
        headers: _jsonHeaders,
      );
    } on FormatException catch (_) {
      return Response.badRequest(body: jsonEncode({'error': 'Invalid JSON body'}), headers: _jsonHeaders);
    } catch (e) {
      print('Registration error: $e');
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleCheckUser(Request request) async {
    try {
      final clientIp = request.ip ?? 'unknown';
      if (!_checkLimiter.allow(clientIp)) {
        return Response(429, body: jsonEncode({'error': 'Too many requests'}), headers: _jsonHeaders);
      }

      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final username = body['username'] as String?;
      final host = body['host'] as String?;

      final usernameError = InputValidator.validateUsername(username);
      if (usernameError != null) {
        return Response.badRequest(body: jsonEncode({'error': usernameError}), headers: _jsonHeaders);
      }

      final hostError = InputValidator.validateHost(host);
      if (hostError != null) {
        return Response.badRequest(body: jsonEncode({'error': hostError}), headers: _jsonHeaders);
      }

      final exists = await xmppRegistrar.userExists(username!, host: host);
      return Response.ok(
        jsonEncode({'available': !exists}),
        headers: _jsonHeaders,
      );
    } on FormatException catch (_) {
      return Response.badRequest(body: jsonEncode({'error': 'Invalid JSON body'}), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  // Entitlements
  Future<Response> _handleGetEntitlement(Request request, String jid) async {
    try {
      final clientIp = request.ip ?? 'unknown';
      if (!_entitlementLimiter.allow(clientIp)) {
        return Response(429, body: jsonEncode({'error': 'Too many requests'}), headers: _jsonHeaders);
      }
      final jidError = InputValidator.validateJid(jid);
      if (jidError != null) {
        return Response.badRequest(body: jsonEncode({'error': jidError}), headers: _jsonHeaders);
      }
      final entitlement = await entitlementService.getEntitlement(jid);
      final hashes = await minerPool.getTotalHashes(jid);
      return Response.ok(
        jsonEncode({
          ...entitlement.toJson(),
          'hashesDonated': hashes,
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleRedeem(Request request) async {
    try {
      final clientIp = request.ip ?? 'unknown';
      if (!_redeemLimiter.allow(clientIp)) {
        return Response(429, body: jsonEncode({'error': 'Too many redemption attempts'}), headers: _jsonHeaders);
      }

      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final code = body['code'] as String?;
      final jid = body['jid'] as String?;

      final codeError = InputValidator.validateRedemptionCode(code);
      if (codeError != null) {
        return Response.badRequest(body: jsonEncode({'error': codeError}), headers: _jsonHeaders);
      }

      final jidError = InputValidator.validateJid(jid);
      if (jidError != null) {
        return Response.badRequest(body: jsonEncode({'error': jidError}), headers: _jsonHeaders);
      }

      final entitlement = await entitlementService.redeemCode(code!, jid!);
      return Response.ok(
        jsonEncode(entitlement.toJson()),
        headers: _jsonHeaders,
      );
    } on Exception catch (e) {
      return Response.badRequest(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  // Gateway Authorization
  Future<Response> _handleGatewayAuthorize(Request request) async {
    try {
      final clientIp = request.ip ?? 'unknown';
      if (!_gatewayLimiter.allow(clientIp)) {
        return Response(429, body: jsonEncode({'error': 'Too many requests'}), headers: _jsonHeaders);
      }

      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final jid = body['jid'] as String?;
      final protocol = body['protocol'] as String?;

      final jidError = InputValidator.validateJid(jid);
      if (jidError != null) {
        return Response.badRequest(body: jsonEncode({'error': jidError}), headers: _jsonHeaders);
      }

      final protocolError = InputValidator.validateProtocol(protocol);
      if (protocolError != null) {
        return Response.badRequest(body: jsonEncode({'error': protocolError}), headers: _jsonHeaders);
      }

      final authorized = await entitlementService.authorizeGateway(jid!, protocol!);
      if (authorized) {
        return Response.ok(
          jsonEncode({'authorized': true, 'jid': jid, 'protocol': protocol}),
          headers: _jsonHeaders,
        );
      } else {
        return Response(
          403,
          body: jsonEncode({
            'authorized': false,
            'error': 'Protocol $protocol not available for your tier. Upgrade to unlock more protocols.',
          }),
          headers: _jsonHeaders,
        );
      }
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleGatewayCheck(Request request, String jid, String protocol) async {
    try {
      final authorized = await entitlementService.isGatewayAuthorized(jid, protocol);
      return Response.ok(
        jsonEncode({'authorized': authorized, 'jid': jid, 'protocol': protocol}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  // Miner
  Future<Response> _handleMinerRegister(Request request) async {
    try {
      final clientIp = request.ip ?? 'unknown';
      if (!_minerLimiter.allow(clientIp)) {
        return Response(429, body: jsonEncode({'error': 'Too many requests'}), headers: _jsonHeaders);
      }

      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final jid = body['jid'] as String?;
      final cpuCap = (body['cpuCap'] as num?)?.toDouble() ?? 0.3;

      final jidError = InputValidator.validateJid(jid);
      if (jidError != null) {
        return Response.badRequest(body: jsonEncode({'error': jidError}), headers: _jsonHeaders);
      }

      final cpuError = InputValidator.validateCpuCap(cpuCap);
      if (cpuError != null) {
        return Response.badRequest(body: jsonEncode({'error': cpuError}), headers: _jsonHeaders);
      }

      final session = await minerPool.register(jid!, cpuCap: cpuCap);
      return Response.ok(
        jsonEncode({
          'sessionToken': session.sessionToken,
          'jid': session.jid,
          'cpuCap': session.cpuCap,
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleMinerSubmit(Request request) async {
    try {
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response(403, body: jsonEncode({'error': 'Authorization required'}), headers: _jsonHeaders);
      }

      final token = authHeader.substring(7);
      final session = await minerPool.validateSession(token);
      if (session == null) {
        return Response(403, body: jsonEncode({'error': 'Invalid session token'}), headers: _jsonHeaders);
      }

      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final hashes = (body['hashes'] as num?)?.toDouble() ?? 0;

      await minerPool.submitHashes(token, hashes);
      final totalHashes = await minerPool.getTotalHashes(session.jid);

      return Response.ok(
        jsonEncode({'hashesDonated': totalHashes}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleMinerHeartbeat(Request request) async {
    try {
      final authHeader = request.headers['authorization'];
      if (authHeader == null || !authHeader.startsWith('Bearer ')) {
        return Response(403, body: jsonEncode({'error': 'Authorization required'}), headers: _jsonHeaders);
      }

      final token = authHeader.substring(7);
      final session = await minerPool.validateSession(token);
      if (session == null) {
        return Response(403, body: jsonEncode({'error': 'Invalid session token'}), headers: _jsonHeaders);
      }

      await minerPool.heartbeat(token);
      return Response.ok(
        jsonEncode({'status': 'ok'}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleMinerStats(Request request, String jid) async {
    try {
      final hashes = await minerPool.getTotalHashes(jid);
      final sessions = await minerPool.getActiveSessions(jid: jid);
      return Response.ok(
        jsonEncode({
          'jid': jid,
          'hashesDonated': hashes,
          'activeSessions': sessions.length,
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  bool _verifyAdminKey(Request request) {
    final key = request.headers['x-admin-key'];
    return key == adminApiKey;
  }

  // Redemption codes (admin)
  Future<Response> _handleGenerateCode(Request request) async {
    if (!_verifyAdminKey(request)) {
      return Response(403, body: jsonEncode({'error': 'Invalid admin key'}), headers: _jsonHeaders);
    }
    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final tier = body['tier'] as String? ?? 'pro';
      final protocols = (body['protocols'] as List?)?.cast<String>() ?? <String>[];
      final durationDays = (body['durationDays'] as int?) ?? 30;

      final code = await entitlementService.generateCode(
        tier,
        protocols: protocols,
        durationDays: durationDays,
      );
      return Response.ok(
        jsonEncode(code.toJson()),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleListCodes(Request request) async {
    if (!_verifyAdminKey(request)) {
      return Response(403, body: jsonEncode({'error': 'Invalid admin key'}), headers: _jsonHeaders);
    }
    try {
      final codes = await entitlementService.listCodes();
      return Response.ok(
        jsonEncode(codes.map((c) => c.toJson()).toList()),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleConfig(Request request) async {
    final prosodyUri = Uri.parse(xmppRegistrar.prosodyHttpUrl);

    final hostHeader = request.headers['x-forwarded-host'] ?? request.headers['host'] ?? 'localhost';
    final isHttps = request.headers['x-forwarded-proto'] == 'https' || request.headers['x-forwarded-proto'] == 'https';
    final wsScheme = isHttps ? 'wss' : 'ws';
    final wsPort = isHttps ? '' : ':8080';
    final uploadScheme = isHttps ? 'https' : 'http';
    final uploadPort = isHttps ? '' : ':8080';

    final websocketUrl = '$wsScheme://$hostHeader$wsPort/xmpp-websocket';
    final uploadUrl = '$uploadScheme://$hostHeader$uploadPort/upload';

    final config = <String, dynamic>{
      'captchaEnabled': captchaService.enabled,
      'domain': xmppRegistrar.domain,
      'uploadUrl': uploadUrl,
      'websocketUrl': websocketUrl,
      'maxUploadSize': 52428800,
      if (giphyApiKey != null && giphyApiKey!.isNotEmpty) 'giphyApiKey': giphyApiKey,
    };

    if (_effectiveJanusUrl != null && _effectiveJanusUrl!.isNotEmpty) {
      final janusUrl = _effectiveJanusUrl!;
      // In monolith deployments Janus runs on localhost, so proxy through the
      // backend at /janus. For external Janus or docker-compose, use the URL
      // directly (client must be able to resolve it).
      if (janusUrl.contains('localhost') || janusUrl.contains('127.0.0.1')) {
        final janusWsScheme = isHttps ? 'wss' : 'ws';
        config['sfuUrl'] = '$janusWsScheme://$hostHeader/janus';
      } else {
        config['sfuUrl'] = janusUrl;
      }
    }
    if (_effectiveJanusApiKey != null && _effectiveJanusApiKey!.isNotEmpty) {
      config['sfuApiKey'] = _effectiveJanusApiKey;
    }

    final iceServers = _buildIceServers(prosodyUri.host);
    if (iceServers.isNotEmpty) {
      config['iceServers'] = iceServers;
    }

    return Response.ok(
      jsonEncode(config),
      headers: _jsonHeaders,
    );
  }

  List<Map<String, dynamic>> _buildIceServers(String host) {
    final servers = <Map<String, dynamic>>[
      {'urls': 'stun:stun.l.google.com:19302'},
    ];

    final turnHost = Platform.environment['GIBBER_TURN_HOST'] ?? '';
    if (turnHost.isNotEmpty) {
      servers.add({'urls': 'stun:$turnHost:3478'});
    }

    final turnUrl = Platform.environment['GIBBER_TURN_URL'] ?? '';
    final turnUser = Platform.environment['GIBBER_TURN_USER'] ?? '';
    final turnPass = Platform.environment['GIBBER_TURN_PASS'] ?? '';

    if (turnUrl.isNotEmpty) {
      servers.add({
        'urls': 'turn:$turnUrl',
        'username': turnUser,
        'credential': turnPass,
      });
      if (turnHost.isNotEmpty) {
        servers.add({
          'urls': 'turns:$turnHost:5349?transport=tcp',
          'username': turnUser,
          'credential': turnPass,
        });
      }
    }

    return servers;
  }

  Future<Response> _handleSfuCreateRoom(Request request) async {
    if (!_sfuLimiter.allow(request.ip ?? 'unknown')) {
      return Response(429, body: jsonEncode({'error': 'Rate limit exceeded'}), headers: _jsonHeaders);
    }

    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response(401, body: jsonEncode({'error': 'Unauthorized'}), headers: _jsonHeaders);
    }

    final token = authHeader.substring(7);
    final payload = jwtService?.verifyToken(token);
    if (payload == null) {
      return Response(401, body: jsonEncode({'error': 'Invalid token'}), headers: _jsonHeaders);
    }

    final jid = payload.jid;
    if (jid.isEmpty) {
      return Response(401, body: jsonEncode({'error': 'Invalid token'}), headers: _jsonHeaders);
    }

    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final roomId = data['room_id'] as String? ?? 'room_${DateTime.now().millisecondsSinceEpoch}';
      final description = data['description'] as String? ?? '';
      final maxPublishers = data['max_publishers'] as int? ?? 6;
      final secret = data['secret'] as String? ?? _uuid.v4().substring(0, 16);
      final isPrivate = data['private'] as bool? ?? false;

      final roomConfig = <String, dynamic>{
        'room': roomId,
        'description': description,
        'max_publishers': maxPublishers,
        'secret': secret,
        'is_private': isPrivate,
        'created_by': jid,
        'created_at': DateTime.now().toIso8601String(),
      };

      if (_effectiveJanusApiKey != null && _effectiveJanusApiKey!.isNotEmpty) {
        roomConfig['janus_api_key'] = _effectiveJanusApiKey;
      }
      if (_effectiveJanusUrl != null && _effectiveJanusUrl!.isNotEmpty) {
        roomConfig['janus_url'] = _effectiveJanusUrl;
      }

      return Response.ok(
        jsonEncode(roomConfig),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.badRequest(
        body: jsonEncode({'error': 'Invalid request body'}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleSfuToken(Request request) async {
    if (!_sfuLimiter.allow(request.ip ?? 'unknown')) {
      return Response(429, body: jsonEncode({'error': 'Rate limit exceeded'}), headers: _jsonHeaders);
    }

    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response(401, body: jsonEncode({'error': 'Unauthorized'}), headers: _jsonHeaders);
    }

    final token = authHeader.substring(7);
    final payload = jwtService?.verifyToken(token);
    if (payload == null) {
      return Response(401, body: jsonEncode({'error': 'Invalid token'}), headers: _jsonHeaders);
    }

    final jid = payload.jid;
    if (jid.isEmpty) {
      return Response(401, body: jsonEncode({'error': 'Invalid token'}), headers: _jsonHeaders);
    }

    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final roomId = data['room_id'] as String?;
      if (roomId == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'room_id required'}),
          headers: _jsonHeaders,
        );
      }

      final displayName = data['display_name'] as String? ?? jid.split('@').first;
      final sfuToken = jwtService?.generateToken(jid, tier: 'sfu');

      return Response.ok(
        jsonEncode({
          'token': sfuToken,
          'room_id': roomId,
          'display_name': displayName,
          'janus_url': _effectiveJanusUrl,
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.badRequest(
        body: jsonEncode({'error': 'Invalid request body'}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleSfuIceServers(Request request) async {
    final host = xmppRegistrar.domain;
    final servers = _buildIceServers(host);
    return Response.ok(
      jsonEncode({'iceServers': servers}),
      headers: _jsonHeaders,
    );
  }

  Future<Response> _handleHealth(Request request) async {
    try {
      final health = await healthService.checkHealth();
      final statusCode = health['status'] == 'healthy' ? 200 : 503;
      return Response(statusCode, body: jsonEncode(health), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'status': 'unhealthy', 'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  // JWT Auth
  Future<Response> _handleAuthToken(Request request) async {
    if (jwtService == null) {
      return Response(503, body: jsonEncode({'error': 'JWT auth not configured'}), headers: _jsonHeaders);
    }

    final clientIp = request.ip ?? 'unknown';
    if (!_authLimiter.allow(clientIp)) {
      return Response(429, body: jsonEncode({'error': 'Too many auth attempts'}), headers: _jsonHeaders);
    }

    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final username = body['username'] as String?;
      final password = body['password'] as String?;
      final host = body['host'] as String?;

      final usernameError = InputValidator.validateUsername(username);
      if (usernameError != null) {
        return Response.badRequest(body: jsonEncode({'error': usernameError}), headers: _jsonHeaders);
      }
      if (password == null || password.isEmpty) {
        return Response.badRequest(body: jsonEncode({'error': 'Password is required'}), headers: _jsonHeaders);
      }
      final hostError = InputValidator.validateHost(host);
      if (hostError != null) {
        return Response.badRequest(body: jsonEncode({'error': hostError}), headers: _jsonHeaders);
      }

      final domain = host ?? xmppRegistrar.domain;
      final jid = '$username@$domain';

      final verified = await _verifyXmppCredentials(username!, password, domain);
      if (!verified) {
        return Response(401, body: jsonEncode({'error': 'Invalid credentials'}), headers: _jsonHeaders);
      }

      final entitlement = await entitlementService.getEntitlement(jid);
      final accessToken = jwtService!.generateToken(jid, tier: entitlement.tier);
      final refreshToken = jwtService!.generateRefreshToken(jid);

      _ensureUser(jid);

      return Response.ok(
        jsonEncode({
          'accessToken': accessToken,
          'refreshToken': refreshToken,
          'jid': jid,
          'tier': entitlement.tier,
        }),
        headers: _jsonHeaders,
      );
    } on FormatException catch (_) {
      return Response.badRequest(body: jsonEncode({'error': 'Invalid JSON body'}), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleAuthRefresh(Request request) async {
    if (jwtService == null) {
      return Response(503, body: jsonEncode({'error': 'JWT auth not configured'}), headers: _jsonHeaders);
    }

    final clientIp = request.ip ?? 'unknown';
    if (!_authLimiter.allow(clientIp)) {
      return Response(429, body: jsonEncode({'error': 'Too many auth attempts'}), headers: _jsonHeaders);
    }

    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final refreshToken = body['refreshToken'] as String?;

      if (refreshToken == null || refreshToken.isEmpty) {
        return Response.badRequest(body: jsonEncode({'error': 'Refresh token is required'}), headers: _jsonHeaders);
      }

      final payload = jwtService!.verifyRefreshToken(refreshToken);
      if (payload == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid or expired refresh token'}), headers: _jsonHeaders);
      }
      if (payload.jid.isEmpty) {
        return Response(401, body: jsonEncode({'error': 'Invalid refresh token'}), headers: _jsonHeaders);
      }

      final entitlement = await entitlementService.getEntitlement(payload.jid);
      final newAccessToken = jwtService!.generateToken(payload.jid, tier: entitlement.tier);

      _ensureUser(payload.jid);

      return Response.ok(
        jsonEncode({
          'accessToken': newAccessToken,
          'jid': payload.jid,
          'tier': entitlement.tier,
        }),
        headers: _jsonHeaders,
      );
    } on FormatException catch (_) {
      return Response.badRequest(body: jsonEncode({'error': 'Invalid JSON body'}), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<bool> _verifyXmppCredentials(String username, String password, String domain) async {
    final prosodyUri = Uri.parse(xmppRegistrar.prosodyHttpUrl);
    final wsScheme = prosodyUri.scheme == 'https' ? 'wss' : 'ws';
    final wsPort = prosodyUri.port > 0 ? prosodyUri.port : (prosodyUri.scheme == 'https' ? 5281 : 5280);
    final wsUrl = '$wsScheme://${prosodyUri.host}:$wsPort/xmpp-websocket';

    try {
      final socket = await WebSocket.connect(wsUrl, headers: {'Host': domain}, protocols: ['xmpp']);
      final completer = Completer<bool>();
      bool authSent = false;

      socket.listen((data) {
        if (data is! String) return;
        final msg = data.trim();
        if (msg.isEmpty) return;

        if (msg.contains('<stream:features') || msg.contains('<features')) {
          if (msg.contains('<mechanisms') && !authSent) {
            final creds = base64Encode(utf8.encode('\x00$username\x00$password'));
            final authStanza = "<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>$creds</auth>";
            socket.add(authStanza);
            authSent = true;
          }
        } else if (msg.contains('<success')) {
          if (!completer.isCompleted) completer.complete(true);
        } else if (msg.contains('<failure')) {
          if (!completer.isCompleted) completer.complete(false);
        }
      }, onDone: () {
        if (!completer.isCompleted) completer.complete(false);
      }, onError: (e) {
        if (!completer.isCompleted) completer.complete(false);
      });

      socket.add("<open xmlns='urn:ietf:params:xml:ns:xmpp-framing' to='$domain' version='1.0'/>");

      final result = await completer.future.timeout(const Duration(seconds: 10), onTimeout: () => false);
      try { socket.add("<close xmlns='urn:ietf:params:xml:ns:xmpp-framing'/>"); } catch (_) {}
      await socket.close();
      return result;
    } catch (e) {
      return false;
    }
  }

  Future<Response> _handlePasswordChange(Request request) async {
    final authHeader = request.headers['authorization'];
    String? authenticatedJid;
    bool isAdmin = false;

    if (jwtService != null && authHeader != null && authHeader.startsWith('Bearer ')) {
      final token = authHeader.substring(7);
      final payload = jwtService!.verifyToken(token);
      if (payload == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: _jsonHeaders);
      }
      authenticatedJid = payload.jid;
    } else if (_verifyAdminKey(request)) {
      isAdmin = true;
    } else {
      return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: _jsonHeaders);
    }

    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final newPassword = body['newPassword'] as String?;
      String? targetUsername;
      String? host;

      if (isAdmin) {
        targetUsername = body['username'] as String?;
        host = body['host'] as String?;
      } else {
        targetUsername = authenticatedJid?.split('@').first;
        host = authenticatedJid?.contains('@') == true ? authenticatedJid!.split('@').last : null;
      }

      if (targetUsername == null || targetUsername.isEmpty) {
        return Response.badRequest(body: jsonEncode({'error': 'Username is required'}), headers: _jsonHeaders);
      }

      final usernameError = InputValidator.validateUsername(targetUsername);
      if (usernameError != null) {
        return Response.badRequest(body: jsonEncode({'error': usernameError}), headers: _jsonHeaders);
      }

      final passwordError = InputValidator.validatePassword(newPassword);
      if (passwordError != null) {
        return Response.badRequest(body: jsonEncode({'error': passwordError}), headers: _jsonHeaders);
      }

      final success = await xmppRegistrar.changePassword(targetUsername, newPassword!, host: host);
      if (success) {
        return Response.ok(
          jsonEncode({'message': 'Password changed successfully'}),
          headers: _jsonHeaders,
        );
      } else {
        return Response(500, body: jsonEncode({'error': 'Failed to change password. Try again later or contact support.'}), headers: _jsonHeaders);
      }
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  void _ensureUser(String jid) {
    final existing = db.db.select('SELECT id FROM users WHERE jid = ?', [jid]);
    if (existing.isEmpty) {
      db.db.execute('INSERT INTO users (id, jid) VALUES (?, ?)', [_uuid.v4(), jid]);
    }
  }

  Future<Response> _handleAccountDelete(Request request) async {
    final authHeader = request.headers['authorization'];
    String? authenticatedJid;
    bool isAdmin = false;

    if (jwtService != null && authHeader != null && authHeader.startsWith('Bearer ')) {
      final token = authHeader.substring(7);
      final payload = jwtService!.verifyToken(token);
      if (payload == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: _jsonHeaders);
      }
      authenticatedJid = payload.jid;
    } else if (_verifyAdminKey(request)) {
      isAdmin = true;
    } else {
      return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: _jsonHeaders);
    }

    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final domain = (body['host'] as String?) ?? xmppRegistrar.domain;
      String targetUsername;
      String targetJid;

      if (isAdmin) {
        final username = body['username'] as String?;
        if (username == null || username.isEmpty) {
          return Response.badRequest(body: jsonEncode({'error': 'Username is required for admin deletion'}), headers: _jsonHeaders);
        }
        final usernameError = InputValidator.validateUsername(username);
        if (usernameError != null) {
          return Response.badRequest(body: jsonEncode({'error': usernameError}), headers: _jsonHeaders);
        }
        targetUsername = username;
        targetJid = '$username@$domain';
      } else {
        if (authenticatedJid == null) {
          return Response(401, body: jsonEncode({'error': 'Unable to determine authenticated user'}), headers: _jsonHeaders);
        }
        targetUsername = authenticatedJid.split('@').first;
        targetJid = authenticatedJid;
      }

      final deleted = await xmppRegistrar.deleteUser(targetUsername, host: domain);
      if (deleted) {
        db.db.execute('DELETE FROM users WHERE jid = ?', [targetJid]);
        db.db.execute('DELETE FROM entitlements WHERE jid = ?', [targetJid]);
        db.db.execute('DELETE FROM miner_sessions WHERE jid = ?', [targetJid]);
        db.db.execute('DELETE FROM payments WHERE jid = ?', [targetJid]);
        db.db.execute('DELETE FROM subscriptions WHERE jid = ?', [targetJid]);
        db.db.execute('DELETE FROM gateway_authorizations WHERE jid = ?', [targetJid]);
        return Response.ok(
          jsonEncode({'message': 'Account deleted successfully', 'jid': targetJid}),
          headers: _jsonHeaders,
        );
      } else {
        return Response(500, body: jsonEncode({'error': 'Failed to delete account. User may not exist or server does not support deletion.'}), headers: _jsonHeaders);
      }
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  static const _jsonHeaders = {'Content-Type': 'application/json'};

  Future<Response> _handlePricing(Request request) async {
    try {
      final pricing = await paymentService.getPricing();
      return Response.ok(
        jsonEncode(pricing),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleStripeCheckout(Request request) async {
    try {
      final clientIp = request.ip ?? 'unknown';
      if (!_paymentLimiter.allow(clientIp)) {
        return Response(429, body: jsonEncode({'error': 'Too many requests'}), headers: _jsonHeaders);
      }

      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final jid = body['jid'] as String?;
      final tier = body['tier'] as String?;

      final jidError = InputValidator.validateJid(jid);
      if (jidError != null) {
        return Response.badRequest(body: jsonEncode({'error': jidError}), headers: _jsonHeaders);
      }

      final tierError = InputValidator.validateTier(tier);
      if (tierError != null) {
        return Response.badRequest(body: jsonEncode({'error': tierError}), headers: _jsonHeaders);
      }

      if (!paymentService.stripeEnabled) {
        return Response(503, body: jsonEncode({'error': 'Stripe is not configured'}), headers: _jsonHeaders);
      }

      final session = await paymentService.createStripeCheckoutSession(jid!, tier!);
      return Response.ok(
        jsonEncode(session),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleBtcpayInvoice(Request request) async {
    try {
      final clientIp = request.ip ?? 'unknown';
      if (!_paymentLimiter.allow(clientIp)) {
        return Response(429, body: jsonEncode({'error': 'Too many requests'}), headers: _jsonHeaders);
      }

      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final jid = body['jid'] as String?;
      final tier = body['tier'] as String?;

      final jidError = InputValidator.validateJid(jid);
      if (jidError != null) {
        return Response.badRequest(body: jsonEncode({'error': jidError}), headers: _jsonHeaders);
      }

      final tierError = InputValidator.validateTier(tier);
      if (tierError != null) {
        return Response.badRequest(body: jsonEncode({'error': tierError}), headers: _jsonHeaders);
      }

      if (!paymentService.btcpayEnabled) {
        return Response(503, body: jsonEncode({'error': 'BTCPay Server is not configured'}), headers: _jsonHeaders);
      }

      final invoice = await paymentService.createBtcpayInvoice(jid!, tier!);
      return Response.ok(
        jsonEncode(invoice),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleStripeWebhook(Request request) async {
    try {
      final body = await request.readAsString();
      final signatureHeader = request.headers['stripe-signature'];
      if (!paymentService.verifyStripeWebhookSignature(body, signatureHeader)) {
        print('Stripe webhook: Invalid signature');
        return Response(401, body: jsonEncode({'error': 'Invalid webhook signature'}), headers: _jsonHeaders);
      }
      final event = jsonDecode(body) as Map<String, dynamic>;
      await paymentService.handleStripeWebhook(event);
      return Response.ok(
        jsonEncode({'received': true}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleBtcpayWebhook(Request request) async {
    try {
      final body = await request.readAsString();
      final signatureHeader = request.headers['btcpay-sig'];
      if (!paymentService.verifyBtcpayWebhookSignature(body, signatureHeader)) {
        print('BTCPay webhook: Invalid signature');
        return Response(401, body: jsonEncode({'error': 'Invalid webhook signature'}), headers: _jsonHeaders);
      }
      final event = jsonDecode(body) as Map<String, dynamic>;
      await paymentService.handleBtcpayWebhook(event);
      return Response.ok(
        jsonEncode({'received': true}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleGetSubscription(Request request, String jid) async {
    try {
      final subscription = await paymentService.getActiveSubscription(jid);
      final payments = await paymentService.getPaymentHistory(jid);
      final entitlement = await entitlementService.getEntitlement(jid);
      return Response.ok(
        jsonEncode({
          'subscription': subscription?.toJson(),
          'payments': payments.map((p) => p.toJson()).toList(),
          'entitlement': entitlement.toJson(),
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleCancelSubscription(Request request, String jid) async {
    try {
      final subscription = await paymentService.getActiveSubscription(jid);
      if (subscription == null) {
        return Response(404, body: jsonEncode({'error': 'No active subscription found'}), headers: _jsonHeaders);
      }
      if (subscription.provider == 'stripe' && paymentService.stripeEnabled) {
        final client = HttpClient();
        try {
          final url = Uri.parse('https://api.stripe.com/v1/subscriptions/${subscription.providerId}');
          final req = await client.deleteUrl(url);
          req.headers.set('Authorization', 'Bearer ${paymentService.stripeSecretKey}');
          final resp = await req.close();
          await resp.drain<void>();
          client.close();
          if (resp.statusCode == 200) {
            return Response.ok(
              jsonEncode({'cancelled': true}),
              headers: _jsonHeaders,
            );
          }
        } catch (_) {
          client.close(force: true);
        }
      }
      await paymentService.cancelSubscription(subscription.providerId);
      return Response.ok(
        jsonEncode({'cancelled': true}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  static final _availableGateways = {
    'telegram': {
      'name': 'Telegram',
      'description': 'Bridge to Telegram messenger',
      'icon': 'telegram',
      'requiresConfig': ['api_id', 'api_hash'],
      'componentJid': 'telegram',
      'slidgeImage': 'ghcr.io/regretfulswan/slidgram:latest',
    },
    'discord': {
      'name': 'Discord',
      'description': 'Bridge to Discord servers and channels',
      'icon': 'discord',
      'requiresConfig': ['bot_token'],
      'componentJid': 'discord',
      'slidgeImage': 'ghcr.io/regretfulswan/slidcord:latest',
    },
    'irc': {
      'name': 'IRC',
      'description': 'Bridge to IRC networks',
      'icon': 'irc',
      'requiresConfig': [],
      'componentJid': 'irc',
      'slidgeImage': 'ghcr.io/regretfulswan/slidirc:latest',
    },
    'matrix': {
      'name': 'Matrix',
      'description': 'Bridge to Matrix homeservers',
      'icon': 'matrix',
      'requiresConfig': ['homeserver'],
      'componentJid': 'matrix',
      'slidgeImage': 'ghcr.io/regretfulswan/matridge:latest',
    },
    'whatsapp': {
      'name': 'WhatsApp',
      'description': 'Bridge to WhatsApp (via linked device)',
      'icon': 'whatsapp',
      'requiresConfig': ['phone_number'],
      'componentJid': 'whatsapp',
      'slidgeImage': 'ghcr.io/regretfulswan/slidge-whatsapp:latest',
    },
  };

  Future<Response> _handleListGateways(Request request) async {
    final enabledGateways = _getEnabledGateways();
    final configuredGateways = _getConfiguredGateways();
    
    final gateways = <String, Map<String, dynamic>>{};
    for (final entry in _availableGateways.entries) {
      final key = entry.key;
      final info = Map<String, dynamic>.from(entry.value);
      info['enabled'] = enabledGateways.contains(key);
      info['configured'] = configuredGateways.contains(key);
      info['status'] = _getGatewayStatus(key);
      gateways[key] = info;
    }

    return Response.ok(
      jsonEncode({'gateways': gateways}),
      headers: _jsonHeaders,
    );
  }

  Set<String> _getEnabledGateways() {
    final enabled = <String>{};
    final envVars = Platform.environment;
    if (envVars['GIBBER_SLIDGRAM_ENABLED'] == 'true') enabled.add('telegram');
    if (envVars['GIBBER_SLIDCORD_ENABLED'] == 'true') enabled.add('discord');
    if (envVars['GIBBER_SLIDIRC_ENABLED'] == 'true') enabled.add('irc');
    if (envVars['GIBBER_MATRIDGE_ENABLED'] == 'true') enabled.add('matrix');
    if (envVars['GIBBER_SLIDGEWHATSAPPER_ENABLED'] == 'true') enabled.add('whatsapp');
    return enabled;
  }

  Set<String> _getConfiguredGateways() {
    final configured = <String>{};
    final envVars = Platform.environment;
    if (envVars['TG_API_ID'] != null && envVars['TG_API_ID']!.isNotEmpty) configured.add('telegram');
    if (envVars['DISCORD_BOT_TOKEN'] != null && envVars['DISCORD_BOT_TOKEN']!.isNotEmpty) configured.add('discord');
    if (envVars['MATRIX_HOMESERVER'] != null && envVars['MATRIX_HOMESERVER']!.isNotEmpty) configured.add('matrix');
    return configured;
  }

  String _getGatewayStatus(String gateway) {
    final enabled = _getEnabledGateways();
    if (!enabled.contains(gateway)) return 'disabled';
    final configured = _getConfiguredGateways();
    if (!configured.contains(gateway)) return 'not_configured';
    return 'ready';
  }

  Future<Response> _handleConfigureGateway(Request request) async {
    if (!_verifyAdminKey(request)) {
      return Response(403, body: jsonEncode({'error': 'Admin key required'}), headers: _jsonHeaders);
    }

    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final gateway = body['gateway'] as String?;
      final config = body['config'] as Map<String, dynamic>?;

      if (gateway == null || !_availableGateways.containsKey(gateway)) {
        return Response.badRequest(body: jsonEncode({'error': 'Invalid gateway type'}), headers: _jsonHeaders);
      }

      return Response.ok(
        jsonEncode({
          'gateway': gateway,
          'config': config ?? {},
          'dockerComposeSnippet': _generateDockerCompose(gateway, config ?? {}),
          'environmentVars': _generateEnvVars(gateway, config ?? {}),
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  String _generateDockerCompose(String gateway, Map<String, dynamic> config) {
    final info = _availableGateways[gateway]!;
    final componentJid = '${info['componentJid']}.\${DOMAIN:-gibberapp.online}';

    final buffer = StringBuffer();
    buffer.writeln('  # ${info['name']} Gateway');
    buffer.writeln('  ${info['componentJid']}:');
    buffer.writeln('    image: ${info['slidgeImage']}');
    buffer.writeln('    container_name: gibber-${info['componentJid']}');
    buffer.writeln('    restart: unless-stopped');
    buffer.writeln('    environment:');
    buffer.writeln('      - SLIDGE_COMPONENT_JID=${componentJid}');
    buffer.writeln('      - SLIDGE_XMPP_SERVER=\${XMPP_SERVER:-prosody}');
    buffer.writeln('      - SLIDGE_XMPP_PORT=\${XMPP_PORT:-5270}');

    for (final key in info['requiresConfig'] as List) {
      final envKey = key.toString().toUpperCase();
      if (config.containsKey(key)) {
        buffer.writeln('      - ${envKey}=\${${gateway.toUpperCase()}_${envKey}:-${config[key]}}');
      }
    }

    buffer.writeln('    networks:');
    buffer.writeln('      - gibber_transports');
    buffer.writeln('    depends_on:');
    buffer.writeln('      - prosody');

    return buffer.toString();
  }

  Map<String, String> _generateEnvVars(String gateway, Map<String, dynamic> config) {
    final info = _availableGateways[gateway]!;
    final prefix = gateway.toUpperCase();
    final envVars = <String, String>{
      'GIBBER_${prefix}_ENABLED': 'true',
      '${prefix}_SECRET': '\${SLIDGE_COMPONENT_SECRET}',
    };

    for (final key in info['requiresConfig'] as List) {
      final envKey = key.toString().toUpperCase();
      if (config.containsKey(key)) {
        envVars['${prefix}_${envKey}'] = config[key].toString();
      }
    }

    return envVars;
  }

  Future<Response> _handleEnableGateway(Request request) async {
    if (!_verifyAdminKey(request)) {
      return Response(403, body: jsonEncode({'error': 'Admin key required'}), headers: _jsonHeaders);
    }

    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final gateway = body['gateway'] as String?;

      if (gateway == null || !_availableGateways.containsKey(gateway)) {
        return Response.badRequest(body: jsonEncode({'error': 'Invalid gateway type'}), headers: _jsonHeaders);
      }

      return Response.ok(
        jsonEncode({
          'gateway': gateway,
          'message': 'Gateway ${_availableGateways[gateway]!['name']} enabled',
          'action': 'restart_required',
          'restartCommand': 'supervisorctl restart prosody',
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleDisableGateway(Request request) async {
    if (!_verifyAdminKey(request)) {
      return Response(403, body: jsonEncode({'error': 'Admin key required'}), headers: _jsonHeaders);
    }

    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final gateway = body['gateway'] as String?;

      if (gateway == null || !_availableGateways.containsKey(gateway)) {
        return Response.badRequest(body: jsonEncode({'error': 'Invalid gateway type'}), headers: _jsonHeaders);
      }

      return Response.ok(
        jsonEncode({
          'gateway': gateway,
          'message': 'Gateway ${_availableGateways[gateway]!['name']} disabled',
          'action': 'restart_required',
          'restartCommand': 'supervisorctl restart prosody',
        }),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  // Per-user gateway handlers

  Future<Response> _handleListUserGateways(Request request, String jid) async {
    final authHeader = request.headers['authorization'];
    String? authenticatedJid;

    if (jwtService != null && authHeader != null && authHeader.startsWith('Bearer ')) {
      final token = authHeader.substring(7);
      final payload = jwtService!.verifyToken(token);
      if (payload == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: _jsonHeaders);
      }
      authenticatedJid = payload.jid;
    } else {
      return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: _jsonHeaders);
    }

    if (authenticatedJid != jid) {
      return Response(403, body: jsonEncode({'error': 'Access denied'}), headers: _jsonHeaders);
    }

    try {
      final gateways = userGatewayService.getUserGateways(jid);
      return Response.ok(
        jsonEncode({'gateways': gateways.map((g) => g.toJson()).toList()}),
        headers: _jsonHeaders,
      );
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleGetUserGateway(Request request, String jid, String type) async {
    final authHeader = request.headers['authorization'];
    String? authenticatedJid;

    if (jwtService != null && authHeader != null && authHeader.startsWith('Bearer ')) {
      final token = authHeader.substring(7);
      final payload = jwtService!.verifyToken(token);
      if (payload == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: _jsonHeaders);
      }
      authenticatedJid = payload.jid;
    } else {
      return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: _jsonHeaders);
    }

    if (authenticatedJid != jid) {
      return Response(403, body: jsonEncode({'error': 'Access denied'}), headers: _jsonHeaders);
    }

    try {
      final gateway = userGatewayService.getUserGateway(jid, type);
      if (gateway == null) {
        return Response(404, body: jsonEncode({'error': 'Gateway not found'}), headers: _jsonHeaders);
      }
      return Response.ok(jsonEncode(gateway.toJson()), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleConfigureUserGateway(Request request, String jid, String type) async {
    final authHeader = request.headers['authorization'];
    String? authenticatedJid;

    if (jwtService != null && authHeader != null && authHeader.startsWith('Bearer ')) {
      final token = authHeader.substring(7);
      final payload = jwtService!.verifyToken(token);
      if (payload == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: _jsonHeaders);
      }
      authenticatedJid = payload.jid;
    } else {
      return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: _jsonHeaders);
    }

    if (authenticatedJid != jid) {
      return Response(403, body: jsonEncode({'error': 'Access denied'}), headers: _jsonHeaders);
    }

    if (!UserGatewayService.availableGatewayTypes.containsKey(type)) {
      return Response.badRequest(body: jsonEncode({'error': 'Invalid gateway type'}), headers: _jsonHeaders);
    }

    final authorized = await entitlementService.isProtocolAuthorized(jid, type);
    if (!authorized) {
      return Response(403, body: jsonEncode({'error': 'Protocol not available for your tier. Upgrade to unlock ${type}.'}), headers: _jsonHeaders);
    }

    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final config = body['config'] as Map<String, dynamic>? ?? {};

      final gateway = userGatewayService.createOrUpdateGateway(
        jid: jid,
        gatewayType: type,
        config: config,
      );

      return Response.ok(jsonEncode(gateway.toJson()), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleDeleteUserGateway(Request request, String jid, String type) async {
    final authHeader = request.headers['authorization'];
    String? authenticatedJid;

    if (jwtService != null && authHeader != null && authHeader.startsWith('Bearer ')) {
      final token = authHeader.substring(7);
      final payload = jwtService!.verifyToken(token);
      if (payload == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: _jsonHeaders);
      }
      authenticatedJid = payload.jid;
    } else {
      return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: _jsonHeaders);
    }

    if (authenticatedJid != jid) {
      return Response(403, body: jsonEncode({'error': 'Access denied'}), headers: _jsonHeaders);
    }

    try {
      final removed = await userGatewayService.removeGateway(jid, type);
      if (!removed) {
        return Response(404, body: jsonEncode({'error': 'Gateway not found'}), headers: _jsonHeaders);
      }
      return Response.ok(jsonEncode({'success': true}), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleEnableUserGateway(Request request, String jid, String type) async {
    final authHeader = request.headers['authorization'];
    String? authenticatedJid;

    if (jwtService != null && authHeader != null && authHeader.startsWith('Bearer ')) {
      final token = authHeader.substring(7);
      final payload = jwtService!.verifyToken(token);
      if (payload == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: _jsonHeaders);
      }
      authenticatedJid = payload.jid;
    } else {
      return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: _jsonHeaders);
    }

    if (authenticatedJid != jid) {
      return Response(403, body: jsonEncode({'error': 'Access denied'}), headers: _jsonHeaders);
    }

    if (!UserGatewayService.availableGatewayTypes.containsKey(type)) {
      return Response.badRequest(body: jsonEncode({'error': 'Invalid gateway type'}), headers: _jsonHeaders);
    }

    final authorized = await entitlementService.isProtocolAuthorized(jid, type);
    if (!authorized) {
      return Response(403, body: jsonEncode({'error': 'Protocol not available for your tier. Upgrade to unlock ${type}.'}), headers: _jsonHeaders);
    }

    try {
      final gateway = await userGatewayService.enableGateway(jid, type);
      if (gateway == null) {
        return Response(404, body: jsonEncode({'error': 'Gateway not found. Configure it first.'}), headers: _jsonHeaders);
      }
      return Response.ok(jsonEncode(gateway.toJson()), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleDisableUserGateway(Request request, String jid, String type) async {
    final authHeader = request.headers['authorization'];
    String? authenticatedJid;

    if (jwtService != null && authHeader != null && authHeader.startsWith('Bearer ')) {
      final token = authHeader.substring(7);
      final payload = jwtService!.verifyToken(token);
      if (payload == null) {
        return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: _jsonHeaders);
      }
      authenticatedJid = payload.jid;
    } else {
      return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: _jsonHeaders);
    }

    if (authenticatedJid != jid) {
      return Response(403, body: jsonEncode({'error': 'Access denied'}), headers: _jsonHeaders);
    }

    try {
      final gateway = await userGatewayService.disableGateway(jid, type);
      if (gateway == null) {
        return Response(404, body: jsonEncode({'error': 'Gateway not found'}), headers: _jsonHeaders);
      }
      return Response.ok(jsonEncode(gateway.toJson()), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }

  Future<Response> _handleTestGateway(Request request, String type) async {
    final authHeader = request.headers['authorization'];

    if (jwtService == null || authHeader == null || !authHeader.startsWith('Bearer ')) {
      return Response(401, body: jsonEncode({'error': 'Authentication required'}), headers: _jsonHeaders);
    }

    final token = authHeader.substring(7);
    final payload = jwtService!.verifyToken(token);
    if (payload == null) {
      return Response(401, body: jsonEncode({'error': 'Invalid or expired token'}), headers: _jsonHeaders);
    }

    if (!UserGatewayService.availableGatewayTypes.containsKey(type)) {
      return Response.badRequest(body: jsonEncode({'error': 'Invalid gateway type'}), headers: _jsonHeaders);
    }

    try {
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final config = body['config'] as Map<String, dynamic>? ?? {};

      final result = userGatewayService.testGatewayConfig(type, config);
      if (result == null) {
        return Response.badRequest(body: jsonEncode({'error': 'Unknown error'}), headers: _jsonHeaders);
      }

      return Response.ok(jsonEncode(result), headers: _jsonHeaders);
    } catch (e) {
      return Response.internalServerError(
        body: jsonEncode({'error': e.toString()}),
        headers: _jsonHeaders,
      );
    }
  }
}