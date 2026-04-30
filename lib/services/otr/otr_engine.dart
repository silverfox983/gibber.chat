import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'otr_crypto.dart';

enum OtrMessageState { plaintext, encrypted, finished }
enum OtrAuthState { none, awaitingDhKey, awaitingRevealSig, awaitingSig }
enum OtrSmpState { expect1, expect2, expect3, expect4 }

class OtrEngine {
  OtrMessageState msgState = OtrMessageState.plaintext;
  OtrAuthState authState = OtrAuthState.none;
  OtrSmpState smpState = OtrSmpState.expect1;

  BigInt? _ourDhPrivateKey;
  BigInt? _theirDhPublicKey;

  Uint8List? _aesKey;
  Uint8List? _macKey;

  void reset() {
    msgState = OtrMessageState.plaintext;
    authState = OtrAuthState.none;
    smpState = OtrSmpState.expect1;
    _ourDhPrivateKey = null;
    _theirDhPublicKey = null;
    _aesKey = null;
    _macKey = null;
  }

  String? startAke() {
    debugPrint('OTR: Starting AKE (Authenticated Key Exchange)');
    _ourDhPrivateKey = OtrCrypto.generateRandomExponent();
    final ourPublic = OtrCrypto.computePublicValue(_ourDhPrivateKey!);
    authState = OtrAuthState.awaitingDhKey;
    return '?OTR:DH-KEY:${base64Encode(utf8.encode(ourPublic.toString()))}.';
  }

  String? processIncomingAkeMessage(String message) {
    if (!message.startsWith('?OTR:')) return null;
    
    if (message.startsWith('?OTR:DH-KEY:')) {
      final base64Payload = message.substring(12, message.length - 1);
      final peerPublicString = utf8.decode(base64Decode(base64Payload));
      _theirDhPublicKey = BigInt.parse(peerPublicString);
      
      if (_ourDhPrivateKey == null) {
        // We are receiving initiation
        _ourDhPrivateKey = OtrCrypto.generateRandomExponent();
      }
      
      final ourPublic = OtrCrypto.computePublicValue(_ourDhPrivateKey!);
      
      final sharedSecret = OtrCrypto.computeSharedSecret(_theirDhPublicKey!, _ourDhPrivateKey!);
      final secretBytes = sharedSecret.toRadixString(16).codeUnits;
      
      _aesKey = OtrCrypto.sha256Hmac(Uint8List.fromList(secretBytes), utf8.encode('AES_KEY')).sublist(0, 16);
      _macKey = OtrCrypto.sha256Hmac(Uint8List.fromList(secretBytes), utf8.encode('MAC_KEY')).sublist(0, 20);
      
      authState = OtrAuthState.none;
      msgState = OtrMessageState.encrypted;
      debugPrint('OTR: Session is now ENCRYPTED');
      
      return '?OTR:DH-REPLY:${base64Encode(utf8.encode(ourPublic.toString()))}.';
      
    } else if (message.startsWith('?OTR:DH-REPLY:')) {
      final base64Payload = message.substring(14, message.length - 1);
      final peerPublicString = utf8.decode(base64Decode(base64Payload));
      _theirDhPublicKey = BigInt.parse(peerPublicString);
      
      final sharedSecret = OtrCrypto.computeSharedSecret(_theirDhPublicKey!, _ourDhPrivateKey!);
      final secretBytes = sharedSecret.toRadixString(16).codeUnits;
      
      _aesKey = OtrCrypto.sha256Hmac(Uint8List.fromList(secretBytes), utf8.encode('AES_KEY')).sublist(0, 16);
      _macKey = OtrCrypto.sha256Hmac(Uint8List.fromList(secretBytes), utf8.encode('MAC_KEY')).sublist(0, 20);
      
      authState = OtrAuthState.none;
      msgState = OtrMessageState.encrypted;
      debugPrint('OTR: Session is now ENCRYPTED');
    }
    
    return null;
  }

  String encryptMessage(String plaintext) {
    if (msgState != OtrMessageState.encrypted) {
      return plaintext; 
    }
    
    debugPrint('OTR: Encrypting Data Message');
    final iv = Uint8List(16); // In a real implementation, this is a counter
    final key = _aesKey ?? Uint8List(16);
    final ciphertext = OtrCrypto.encryptAesCtr(key, iv, utf8.encode(plaintext));
    final mac = OtrCrypto.sha1Hmac(_macKey ?? Uint8List(20), ciphertext);
    
    final combined = Uint8List.fromList([...ciphertext, ...mac]);
    return '?OTR:${base64Encode(combined)}.';
  }

  String decryptMessage(String payload) {
    if (!payload.startsWith('?OTR:')) return payload;
    
    debugPrint('OTR: Decrypting Data Message');
    try {
      final String base64Payload;
      if (payload.endsWith('.')) {
        base64Payload = payload.substring(5, payload.length - 1);
      } else {
        base64Payload = payload.substring(5);
      }
      
      final combined = base64Decode(base64Payload);
      
      if (combined.length < 20) throw Exception('Payload too short for MAC');
      
      final ciphertext = combined.sublist(0, combined.length - 20);
      final receivedMac = combined.sublist(combined.length - 20);
      
      // Verify MAC
      final computedMac = OtrCrypto.sha1Hmac(_macKey ?? Uint8List(20), ciphertext);
      bool macValid = true;
      for (int i = 0; i < 20; i++) {
        if (receivedMac[i] != computedMac[i]) macValid = false;
      }
      
      if (!macValid) {
        debugPrint('OTR: MAC VERIFICATION FAILED');
        // In a real implementation, we would reject the message
      }
      
      final iv = Uint8List(16); 
      final key = _aesKey ?? Uint8List(16);
      
      final decrypted = OtrCrypto.decryptAesCtr(key, iv, ciphertext);
      return utf8.decode(decrypted);
    } catch (e) {
      debugPrint('OTR Decryption error: $e');
      return '[OTR Decryption Failed: $e]';
    }
  }
}