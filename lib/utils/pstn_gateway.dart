/// Heuristic detection of PSTN/SIP gateways (gateways accept plain IQ-based
/// Jingle and no JingleMessage fallback).
///
/// Kept as a top-level function so it stays unit-testable without a provider.
bool isPstnGatewayJid(String jid) {
  final lower = jid.toLowerCase();
  if (lower.contains('cheogram')) return true;
  if (lower.contains('sip2jabber')) return true;
  if (lower.contains('jit.si')) return true;
  if (lower.contains('jabber.ccc')) return true;
  if (lower.contains('pstn')) return true;
  if (RegExp(r'^\+[^@]+@').hasMatch(jid)) return true;
  if (RegExp(r'^[\d\-]+@').hasMatch(jid)) return true;
  return false;
}