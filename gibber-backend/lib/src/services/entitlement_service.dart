import 'package:uuid/uuid.dart';
import 'package:gibber_backend/src/services/database_service.dart';
import 'package:gibber_backend/src/models/entitlement.dart';
import 'package:gibber_backend/src/models/redemption_code.dart';

class BackendEntitlementService {
  final DatabaseService db;
  final _uuid = const Uuid();

  static const Map<String, List<String>> tierProtocols = {
    'free': ['XMPP'],
    'pro': ['XMPP', 'Slack', 'Discord', 'IRC'],
    'ultimate': ['XMPP', 'Slack', 'Discord', 'IRC', 'Teams', 'Matrix', 'Telegram', 'SMS'],
  };

  BackendEntitlementService({required this.db});

  Future<Entitlement> getEntitlement(String jid) async {
    final rows = db.db.select(
      'SELECT * FROM entitlements WHERE jid = ?',
      [jid],
    );

    if (rows.isEmpty) {
      return Entitlement(id: _uuid.v4(), jid: jid, tier: 'free');
    }

    final entitlement = Entitlement.fromRow(rows.first);
    if (!entitlement.isActive) {
      return Entitlement(id: _uuid.v4(), jid: jid, tier: 'free');
    }

    return entitlement;
  }

  Future<Entitlement> redeemCode(String code, String jid) async {
    final rows = db.db.select(
      'SELECT * FROM redemption_codes WHERE code = ? AND used = 0',
      [code],
    );

    if (rows.isEmpty) {
      throw Exception('Invalid or already used redemption code');
    }

    final redemptionCode = RedemptionCode.fromRow(rows.first);
    final tier = redemptionCode.tier;
    final expiresAt = redemptionCode.durationDays > 0
        ? DateTime.now().add(Duration(days: redemptionCode.durationDays))
        : null;

    db.db.execute(
      'UPDATE redemption_codes SET used = 1, used_by = ?, used_at = datetime(\'now\') WHERE code = ?',
      [jid, code],
    );

    final id = _uuid.v4();
    db.db.execute(
      'INSERT OR REPLACE INTO entitlements (id, jid, tier, additional_protocols, expires_at) VALUES (?, ?, ?, ?, ?)',
      [
        id,
        jid,
        tier,
        redemptionCode.protocols.join(','),
        expiresAt?.toIso8601String(),
      ],
    );

    _ensureUser(jid);
    db.db.execute(
      'UPDATE users SET tier = ?, updated_at = datetime(\'now\') WHERE jid = ?',
      [tier, jid],
    );

    return Entitlement(
      id: id,
      jid: jid,
      tier: tier,
      additionalProtocols: redemptionCode.protocols,
      expiresAt: expiresAt,
    );
  }

  Future<bool> isProtocolAuthorized(String jid, String protocol) async {
    final entitlement = await getEntitlement(jid);
    if (!entitlement.isActive) return protocol == 'XMPP';

    if (entitlement.additionalProtocols.contains(protocol)) return true;

    final allowedProtocols = tierProtocols[entitlement.tier] ?? ['XMPP'];
    return allowedProtocols.contains(protocol);
  }

  Future<bool> authorizeGateway(String jid, String protocol) async {
    final authorized = await isProtocolAuthorized(jid, protocol);
    if (!authorized) return false;

    final existing = db.db.select(
      'SELECT id FROM gateway_authorizations WHERE jid = ? AND protocol = ?',
      [jid, protocol],
    );

    if (existing.isNotEmpty) {
      db.db.execute(
        'UPDATE gateway_authorizations SET authorized = 1, authorized_at = datetime(\'now\') WHERE jid = ? AND protocol = ?',
        [jid, protocol],
      );
    } else {
      db.db.execute(
        'INSERT INTO gateway_authorizations (id, jid, protocol, authorized, authorized_at) VALUES (?, ?, ?, 1, datetime(\'now\'))',
        [_uuid.v4(), jid, protocol],
      );
    }

    return true;
  }

  Future<bool> isGatewayAuthorized(String jid, String protocol) async {
    final rows = db.db.select(
      'SELECT authorized FROM gateway_authorizations WHERE jid = ? AND protocol = ?',
      [jid, protocol],
    );
    if (rows.isEmpty) return false;
    return (rows.first['authorized'] as int) == 1;
  }

  Future<RedemptionCode> generateCode(String tier, {List<String> protocols = const [], int durationDays = 30}) async {
    final code = _generateRedemptionCode();
    db.db.execute(
      'INSERT INTO redemption_codes (code, tier, protocols, duration_days) VALUES (?, ?, ?, ?)',
      [code, tier, protocols.join(','), durationDays],
    );
    return RedemptionCode(
      code: code,
      tier: tier,
      protocols: protocols,
      durationDays: durationDays,
    );
  }

  Future<List<RedemptionCode>> listCodes({int limit = 50}) async {
    final rows = db.db.select(
      'SELECT * FROM redemption_codes ORDER BY created_at DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => RedemptionCode.fromRow(r)).toList();
  }

  String _generateRedemptionCode() {
    final buffer = StringBuffer();
    final random = DateTime.now().microsecondsSinceEpoch;
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    for (var i = 0; i < 16; i++) {
      if (i > 0 && i % 4 == 0) buffer.write('-');
      buffer.write(chars[(random + i * 7) % chars.length]);
    }
    return buffer.toString();
  }

  void _ensureUser(String jid) {
    final existing = db.db.select('SELECT id FROM users WHERE jid = ?', [jid]);
    if (existing.isEmpty) {
      db.db.execute(
        'INSERT INTO users (id, jid) VALUES (?, ?)',
        [_uuid.v4(), jid],
      );
    }
  }
}