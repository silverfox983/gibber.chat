import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

class JwtService {
  final String _secret;
  final Duration _tokenExpiry;
  final Duration _refreshExpiry;

  JwtService({
    required String secret,
    Duration tokenExpiry = const Duration(hours: 24),
    Duration refreshExpiry = const Duration(days: 30),
  }) : _secret = secret,
       _tokenExpiry = tokenExpiry,
       _refreshExpiry = refreshExpiry;

  String generateToken(String jid, {String? tier}) {
    final now = DateTime.now();
    final payload = JwtPayload(
      jid: jid,
      tier: tier ?? 'free',
      iat: now.millisecondsSinceEpoch ~/ 1000,
      exp: now.add(_tokenExpiry).millisecondsSinceEpoch ~/ 1000,
      type: 'access',
    );
    return JWT(payload.toJson()).sign(SecretKey(_secret));
  }

  String generateRefreshToken(String jid) {
    final now = DateTime.now();
    final payload = JwtPayload(
      jid: jid,
      iat: now.millisecondsSinceEpoch ~/ 1000,
      exp: now.add(_refreshExpiry).millisecondsSinceEpoch ~/ 1000,
      type: 'refresh',
    );
    return JWT(payload.toJson()).sign(SecretKey(_secret));
  }

  JwtPayload? verifyToken(String token) {
    try {
      final jwt = JWT.verify(token, SecretKey(_secret));
      final payload = JwtPayload.fromJson(jwt.payload as Map<String, dynamic>);
      if (payload.type != 'access') return null;
      return payload;
    } catch (_) {
      return null;
    }
  }

  JwtPayload? verifyRefreshToken(String token) {
    try {
      final jwt = JWT.verify(token, SecretKey(_secret));
      final payload = JwtPayload.fromJson(jwt.payload as Map<String, dynamic>);
      if (payload.type != 'refresh') return null;
      return payload;
    } catch (_) {
      return null;
    }
  }
}

class JwtPayload {
  final String jid;
  final String? tier;
  final int? iat;
  final int? exp;
  final String type;

  JwtPayload({
    required this.jid,
    this.tier,
    this.iat,
    this.exp,
    required this.type,
  });

  factory JwtPayload.fromJson(Map<String, dynamic> json) {
    return JwtPayload(
      jid: json['jid'] as String? ?? '',
      tier: json['tier'] as String?,
      iat: json['iat'] as int?,
      exp: json['exp'] as int?,
      type: json['type'] as String? ?? 'access',
    );
  }

  Map<String, dynamic> toJson() => {
    'jid': jid,
    if (tier != null) 'tier': tier,
    if (iat != null) 'iat': iat,
    if (exp != null) 'exp': exp,
    'type': type,
  };
}