import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/stream/ctr.dart';
import 'package:pointycastle/random/fortuna_random.dart';
    

class OtrCrypto {
  static final BigInt modpGroup5Prime = BigInt.parse(
    'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA237327FFFFFFFFFFFFFFFF',
    radix: 16,
  );
  static final BigInt generator = BigInt.two;

  static BigInt generateRandomExponent() {
    final rand = FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => Random.secure().nextInt(256)))));
    return rand.nextBigInteger(1536);
  }

  static BigInt computePublicValue(BigInt exponent) {
    return generator.modPow(exponent, modpGroup5Prime);
  }

  static BigInt computeSharedSecret(BigInt peerPublicValue, BigInt exponent) {
    return peerPublicValue.modPow(exponent, modpGroup5Prime);
  }

  static Uint8List encryptAesCtr(Uint8List key, Uint8List iv, Uint8List plaintext) {
    final cipher = CTRStreamCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), iv));
    return cipher.process(plaintext);
  }

  static Uint8List decryptAesCtr(Uint8List key, Uint8List iv, Uint8List ciphertext) {
    final cipher = CTRStreamCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    return cipher.process(ciphertext);
  }

  static Uint8List sha256Hmac(Uint8List key, Uint8List data) {
    final hmac = Hmac(sha256, key);
    return Uint8List.fromList(hmac.convert(data).bytes);
  }

  static Uint8List sha1Hmac(Uint8List key, Uint8List data) {
    final hmac = Hmac(sha1, key);
    return Uint8List.fromList(hmac.convert(data).bytes);
  }
}