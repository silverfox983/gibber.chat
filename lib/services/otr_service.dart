import 'package:flutter/foundation.dart';
import 'otr/otr_engine.dart';

class OtrService {
  final Map<String, OtrEngine> _sessions = {};
  
  void Function(String bareJid, String message)? injectMessage;

  OtrEngine _getEngine(String bareJid) {
    if (!_sessions.containsKey(bareJid)) {
      _sessions[bareJid] = OtrEngine();
    }
    return _sessions[bareJid]!;
  }

  bool isOtrSessionActive(String bareJid) {
    return _getEngine(bareJid).msgState == OtrMessageState.encrypted;
  }

  void startSession(String bareJid) {
    final engine = _getEngine(bareJid);
    final msg = engine.startAke();
    if (msg != null && injectMessage != null) {
      injectMessage!(bareJid, msg);
    }
  }

  void endSession(String bareJid) {
    _getEngine(bareJid).reset();
  }

  String processOutgoingMessage(String bareJid, String text) {
    final engine = _getEngine(bareJid);
    if (engine.msgState == OtrMessageState.encrypted) {
      return engine.encryptMessage(text);
    }
    return text; // Return plaintext if OTR is not active
  }

  String? processIncomingMessage(String bareJid, String text) {
    final engine = _getEngine(bareJid);

    // Check for OTR Whitespace Tag (indicating OTR support)
    if (text.contains('\x20\x09\x20\x20\x09\x09\x09\x09\x20\x09\x20\x09\x20\x09\x20\x20')) {
      debugPrint('OTR: Received whitespace tag from $bareJid, starting AKE if policies allow');
      // In a real implementation, we would auto-start AKE based on user policy
    }

    if (text.startsWith('?OTR?')) {
      // OTR Query Message
      debugPrint('OTR: Received Query Message from $bareJid');
      final reply = engine.startAke();
      if (reply != null && injectMessage != null) {
        injectMessage!(bareJid, reply);
      }
      return null; // Do not show in UI
    }

    if (text.startsWith('?OTR:')) {
      // OTR Encrypted Data or AKE Message
      if (engine.msgState != OtrMessageState.encrypted || text.startsWith('?OTR:DH-')) {
        final reply = engine.processIncomingAkeMessage(text);
        if (reply != null && injectMessage != null) {
          injectMessage!(bareJid, reply);
        }
        return null; // Do not show AKE negotiation in UI
      } else {
        return engine.decryptMessage(text);
      }
    }

    if (text.startsWith('?OTR Error:')) {
      debugPrint('OTR Error from $bareJid: $text');
      return text;
    }

    return text;
  }
}
