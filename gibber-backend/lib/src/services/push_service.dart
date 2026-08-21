import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' hide Hash;
import 'package:http/http.dart' as http;
import 'package:webcrypto/webcrypto.dart';

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
      subject: Platform.environment['GIBBER_VAPID_SUBJECT'] ?? 'mailto:admin@gibberapp.online',
    );
  }

  bool get isConfigured =>
      _vapidPublicKey != null &&
      _vapidPublicKey.isNotEmpty &&
      _vapidPrivateKey != null &&
      _vapidPrivateKey.isNotEmpty;

  String _base64UrlEncode(List<int> bytes) {
    return base64Url.encode(bytes).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
  }

  Uint8List _base64UrlDecode(String input) {
    String output = input.replaceAll('-', '+').replaceAll('_', '/');
    switch (output.length % 4) {
      case 2: output += '==';
      case 3: output += '=';
    }
    return base64Decode(output);
  }

  Map<String, String> _generateVapidHeaders(String audience, String subject) {
    final authToken = sha256.convert(utf8.encode('$audience$subject')).bytes;
    final vapidKeyBytes = _base64UrlDecode(_vapidPublicKey!);

    final signatureInput = 'webpush-${Hmac(sha256, authToken).convert(vapidKeyBytes).bytes}';
    final signature = Hmac(sha256, authToken).convert(utf8.encode(signatureInput)).bytes;

    return {
      'Authorization': 'vapid t=${_base64UrlEncode(signature)}, k=$_vapidPublicKey',
      'Crypto-Key': 'p256ecdsa=$_vapidPublicKey',
    };
  }

  Future<Uint8List> _encryptPayload({
    required Uint8List payload,
    required Uint8List clientPublicKeyBytes,
    required Uint8List clientAuthBytes,
  }) async {
    final random = Random.secure();

    final salt = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      salt[i] = random.nextInt(256);
    }

    final serverEphemeralKeyPair = await EcdhPrivateKey.generateKey(EllipticCurve.p256);
    final serverPublicRaw = await serverEphemeralKeyPair.publicKey.exportRawKey();

    final clientPubKey = await EcdhPublicKey.importRawKey(clientPublicKeyBytes, EllipticCurve.p256);

    final sharedSecret = await serverEphemeralKeyPair.privateKey.deriveBits(256, clientPubKey);

    final ikmData = Uint8List.fromList([
      ...sharedSecret,
      ...clientAuthBytes,
      ...serverPublicRaw,
      ...clientPublicKeyBytes,
    ]);

    final hkdfKey = await HkdfSecretKey.importRawKey(ikmData);
    final derivedKey = await hkdfKey.deriveBits(256, Hash.sha256, salt, utf8.encode('Content-Encoding: auth'));

    final contentEncryptionKey = derivedKey.sublist(0, 16);
    final nonce = derivedKey.sublist(16, 28);

    final contentKey = await AesGcmSecretKey.importRawKey(contentEncryptionKey);
    final encrypted = await contentKey.encryptBytes(payload, nonce);

    final keyBytes = await serverEphemeralKeyPair.publicKey.exportRawKey();
    return Uint8List.fromList([...salt, ...keyBytes, ...encrypted]);
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
      final audience = '${audienceUri.scheme}://${audienceUri.host}${audienceUri.port != 80 && audienceUri.port != 443 ? ':${audienceUri.port}' : ''}';

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
        print('PushService: push to $endpoint failed with ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      print('PushService: failed to send push to $endpoint: $e');
    }
  }
}
