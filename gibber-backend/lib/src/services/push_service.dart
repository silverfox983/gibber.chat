import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

class PushService {
  final String? _vapidPublicKey;
  final String? _vapidPrivateKey;
  final String _subject;

  PushService({
    String? vapidPublicKey,
    String? vapidPrivateKey,
    required String subject,
  })  : _vapidPublicKey = vapidPublicKey,
        _vapidPrivateKey = vapidPrivateKey,
        _subject = subject;

  factory PushService.fromEnv() {
    return PushService(
      vapidPublicKey: Platform.environment['GIBBER_VAPID_PUBLIC_KEY'],
      vapidPrivateKey: Platform.environment['GIBBER_VAPID_PRIVATE_KEY'],
      subject: Platform.environment['GIBBER_VAPID_SUBJECT'] ??
          'mailto:admin@gibberapp.online',
    );
  }

  bool get isConfigured =>
      _vapidPublicKey != null &&
      _vapidPublicKey.isNotEmpty &&
      _vapidPrivateKey != null &&
      _vapidPrivateKey.isNotEmpty;

  String _base64UrlEncode(List<int> bytes) {
    return base64Url
        .encode(bytes)
        .replaceAll('+', '-')
        .replaceAll('/', '_')
        .replaceAll('=', '');
  }

  Uint8List _base64UrlDecode(String input) {
    var output = input.replaceAll('-', '+').replaceAll('_', '/');
    switch (output.length % 4) {
      case 2:
        output += '==';
      case 3:
        output += '=';
    }
    return base64Decode(output);
  }

  Uint8List _bigIntToBytes(BigInt value, int byteLength) {
    final hexStr = value.toRadixString(16);
    final padded = hexStr.padLeft(byteLength * 2, '0');
    final bytes = Uint8List(byteLength);
    for (var i = 0; i < byteLength; i++) {
      bytes[i] = int.parse(padded.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  ECDomainParameters get _curve => ECDomainParameters('prime256v1');

  SecureRandom _secureRandom() {
    final seedSource = Random.secure();
    final seeds = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      seeds[i] = seedSource.nextInt(256);
    }
    final secureRandom = SecureRandom('Fortuna')
      ..seed(KeyParameter(seeds));
    return secureRandom;
  }

  ECPrivateKey _importPrivateKey(Uint8List keyBytes) {
    final d = _bytesToBigInt(keyBytes);
    return ECPrivateKey(d, _curve);
  }

  BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (var i = 0; i < bytes.length; i++) {
      result = (result << 8) | BigInt.from(bytes[i]);
    }
    return result;
  }

  Map<String, String> _generateVapidHeaders(
      String audience, String subject) {
    final privateKeyBytes = _base64UrlDecode(_vapidPrivateKey!);
    final privateKey = _importPrivateKey(privateKeyBytes);

    final header = base64Url.encode(utf8.encode('{"typ":"JWT","alg":"ES256"}'));
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final payload = base64Url.encode(utf8.encode(
        '{"aud":"$audience","exp":${now + 12 * 3600},"sub":"$subject"}'));
    final signingInput = '$header.$payload';
    final signingInputBytes = utf8.encode(signingInput);

    final digest = SHA256Digest();
    final signer = ECDSASigner(digest)
      ..init(true, PrivateKeyParameter<ECPrivateKey>(privateKey));
    final sig = signer.generateSignature(signingInputBytes) as ECSignature;

    final sigBytes = Uint8List(64);
    final rBytes = _bigIntToBytes(sig.r, 32);
    final sBytes = _bigIntToBytes(sig.s, 32);
    sigBytes.setRange(0, 32, rBytes);
    sigBytes.setRange(32, 64, sBytes);

    final jwt = '$signingInput.${_base64UrlEncode(sigBytes)}';

    return {
      'Authorization': 'vapid t=$jwt, k=$_vapidPublicKey',
    };
  }

  Future<Uint8List> _encryptPayload({
    required Uint8List payload,
    required Uint8List clientPublicKeyBytes,
    required Uint8List clientAuthBytes,
  }) async {
    final salt = _secureRandom().nextBytes(16);

    final serverKeyPair =
        ECKeyGenerator()..init(ECKeyGeneratorParameters(_curve));
    final serverEphemeral = serverKeyPair.generateKeyPair();
    final serverPrivateKey = serverEphemeral.privateKey as ECPrivateKey;
    final serverPublicKey = serverEphemeral.publicKey as ECPublicKey;
    final serverPublicRaw = serverPublicKey.Q!.getEncoded(false);

    final clientPoint = _curve.curve.decodePoint(clientPublicKeyBytes);
    final clientPubKey = ECPublicKey(clientPoint, _curve);

    final agreement = ECDHBasicAgreement()..init(serverPrivateKey);
    final sharedSecretBigInt = agreement.calculateAgreement(clientPubKey);
    final sharedSecret = _bigIntToBytes(sharedSecretBigInt, 32);

    final info1 = Uint8List.fromList([
      ...utf8.encode('WebPush: info'),
      0x00,
      ...clientPublicKeyBytes,
      ...serverPublicRaw,
    ]);

    final hkdf1 = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(sharedSecret, 32, clientAuthBytes, info1));
    final ikm = Uint8List(32);
    hkdf1.deriveKey(null, 0, ikm, 0);

    final hkdfCek = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(ikm, 16, salt, utf8.encode('Content-Encoding: aes128gcm')));
    final contentEncryptionKey = Uint8List(16);
    hkdfCek.deriveKey(null, 0, contentEncryptionKey, 0);

    final hkdfNonce = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(ikm, 12, salt, utf8.encode('Content-Encoding: nonce')));
    final nonce = Uint8List(12);
    hkdfNonce.deriveKey(null, 0, nonce, 0);

    final aes = GCMBlockCipher(AESEngine())
      ..init(
          true,
          AEADParameters(
            KeyParameter(contentEncryptionKey),
            128,
            nonce,
            Uint8List(0),
          ));
    final encrypted = aes.process(payload);

    return Uint8List.fromList([
      ...salt,
      ...serverPublicRaw,
      ...encrypted,
    ]);
  }

  Future<void> sendPush({
    required String endpoint,
    required String p256dh,
    required String auth,
    required String title,
    required String body,
    String? icon,
    String? tag,
    String? url,
    String? conversationId,
    String? spaceId,
  }) async {
    if (!isConfigured) {
      print('PushService: not configured (missing VAPID keys)');
      return;
    }

    try {
      final payload = jsonEncode({
        'title': title,
        'body': body,
        'icon': icon ?? '/icons/Icon-192.png',
        'tag': tag ?? 'gibber-message',
        'url': url ?? '/',
        if (conversationId != null) 'conversationId': conversationId,
        if (spaceId != null) 'spaceId': spaceId,
      });

      final audienceUri = Uri.parse(endpoint);
      final audience =
          '${audienceUri.scheme}://${audienceUri.host}${audienceUri.port != 80 && audienceUri.port != 443 ? ':${audienceUri.port}' : ''}';

      final clientPubKeyBytes = _base64UrlDecode(p256dh);
      final clientAuthBytes = _base64UrlDecode(auth);

      final encrypted = await _encryptPayload(
        payload: Uint8List.fromList(utf8.encode(payload)),
        clientPublicKeyBytes: clientPubKeyBytes,
        clientAuthBytes: clientAuthBytes,
      );

      final headers = _generateVapidHeaders(audience, _subject);

      final response = await http.post(
        Uri.parse(endpoint),
        headers: {
          ...headers,
          'TTL': '86400',
          'Urgency': 'normal',
          'Content-Type': 'application/octet-stream',
        },
        body: encrypted,
      );

      if (response.statusCode != 201 && response.statusCode != 200) {
        print(
            'PushService: push to $endpoint failed with ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      print('PushService: failed to send push to $endpoint: $e');
    }
  }
}
