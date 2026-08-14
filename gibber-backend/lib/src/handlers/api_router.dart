import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:gibber_backend/src/services/database_service.dart';
import 'package:gibber_backend/src/services/xmpp_registrar.dart';
import 'package:gibber_backend/src/services/miner_pool_service.dart';
import 'package:gibber_backend/src/services/entitlement_service.dart';
import 'package:gibber_backend/src/services/captcha_service.dart';
import 'package:gibber_backend/src/services/rate_limiter.dart';

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
  final String adminApiKey;
  final CaptchaService captchaService;
  final RateLimiter _registerLimiter = RateLimiter(maxRequests: 3, window: Duration(hours: 1));
  final RateLimiter _checkLimiter = RateLimiter(maxRequests: 20, window: Duration(minutes: 1));

  ApiRouter({
    required this.db,
    required this.xmppRegistrar,
    required this.minerPool,
    required this.entitlementService,
    this.adminApiKey = 'gibber-admin-key',
    CaptchaService? captchaService,
  }) : captchaService = captchaService ?? CaptchaService() {
    _setupRoutes();
  }

  Handler get handler => _router.call;

  final Router _router = Router();

  void _setupRoutes() {
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
    _router.post('/codes', _handleGenerateCode);
    _router.get('/codes', _handleListCodes);
    _router.get('/health', _handleHealth);
  }

  // XMPP Registration
  Future<Response> _handleRegister(Request request) async {
    try {
      final clientIp = request.ip ?? 'unknown';
      if (!_registerLimiter.allow(clientIp)) {
        return Response(429, body: jsonEncode({'error': 'Too many registration attempts. Please try again later.'}), headers: _jsonHeaders);
      }

      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final username = body['username'] as String?;
      final password = body['password'] as String?;
      final host = body['host'] as String?;
      final captchaToken = body['captchaToken'] as String?;

      if (captchaService.enabled && (captchaToken == null || captchaToken.isEmpty)) {
        return Response(403, body: jsonEncode({'error': 'Captcha verification required'}), headers: _jsonHeaders);
      }

      if (captchaService.enabled && !await captchaService.verifyToken(captchaToken!, remoteIp: clientIp)) {
        return Response(403, body: jsonEncode({'error': 'Captcha verification failed'}), headers: _jsonHeaders);
      }

      if (username == null || password == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'username and password are required'}),
          headers: _jsonHeaders,
        );
      }

      if (username.length < 3 || password.length < 8) {
        return Response.badRequest(
          body: jsonEncode({'error': 'Username must be >= 3 chars, password >= 8 chars'}),
          headers: _jsonHeaders,
        );
      }

      final result = await xmppRegistrar.register(username, password, host: host);

      if (result.success) {
        return Response.ok(
          jsonEncode({'jid': result.jid, 'message': result.message}),
          headers: _jsonHeaders,
        );
      } else {
        return Response(
          409,
          body: jsonEncode({'error': result.message, 'jid': result.jid}),
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

  Future<Response> _handleCheckUser(Request request) async {
    try {
      final clientIp = request.ip ?? 'unknown';
      if (!_checkLimiter.allow(clientIp)) {
        return Response(429, body: jsonEncode({'error': 'Too many requests'}), headers: _jsonHeaders);
      }

      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final username = body['username'] as String?;
      final host = body['host'] as String?;

      if (username == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'username is required'}),
          headers: _jsonHeaders,
        );
      }

      final exists = await xmppRegistrar.userExists(username, host: host);
      return Response.ok(
        jsonEncode({'available': !exists}),
        headers: _jsonHeaders,
      );
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
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final code = body['code'] as String?;
      final jid = body['jid'] as String?;

      if (code == null || jid == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'code and jid are required'}),
          headers: _jsonHeaders,
        );
      }

      final entitlement = await entitlementService.redeemCode(code, jid);
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
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final jid = body['jid'] as String?;
      final protocol = body['protocol'] as String?;

      if (jid == null || protocol == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'jid and protocol are required'}),
          headers: _jsonHeaders,
        );
      }

      final authorized = await entitlementService.authorizeGateway(jid, protocol);
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
      final body = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
      final jid = body['jid'] as String?;
      final cpuCap = (body['cpuCap'] as num?)?.toDouble() ?? 0.3;

      if (jid == null) {
        return Response.badRequest(
          body: jsonEncode({'error': 'jid is required'}),
          headers: _jsonHeaders,
        );
      }

      final session = await minerPool.register(jid, cpuCap: cpuCap);
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

  Future<Response> _handleHealth(Request request) async {
    return Response.ok(
      jsonEncode({
        'status': 'healthy',
        'domain': xmppRegistrar.domain,
        'timestamp': DateTime.now().toIso8601String(),
      }),
      headers: _jsonHeaders,
    );
  }

  static const _jsonHeaders = {'Content-Type': 'application/json'};
}