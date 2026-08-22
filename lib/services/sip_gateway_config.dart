import 'package:shared_preferences/shared_preferences.dart';

class SipGatewayConfig {
  static const String _gatewayJidKey = 'sip_gateway_jid';
  static const String _defaultGatewayJid = 'cheogram.com';

  static Future<String> getGatewayJid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_gatewayJidKey) ?? _defaultGatewayJid;
  }

  static Future<void> setGatewayJid(String jid) async {
    final prefs = await SharedPreferences.getInstance();
    final cleaned = jid.trim().toLowerCase();
    await prefs.setString(_gatewayJidKey, cleaned.isEmpty ? _defaultGatewayJid : cleaned);
  }
}
