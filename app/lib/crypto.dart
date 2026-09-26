import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AES-256-GCM for the cloud sync channel, matching server/cloud_crypto.py byte-for-byte:
/// base64( nonce[12] || ciphertext || tag[16] ). No AAD - the only two parties that ever
/// hold [keyBytes] are the owner's own devices; the cloud server never sees it.
class CloudCrypto {
  CloudCrypto(this.keyBytes) : assert(keyBytes.length == 32);

  final List<int> keyBytes;
  static const _nonceLength = 12;
  static const _macLength = 16;
  final _algorithm = AesGcm.with256bits();

  Future<String> encryptField(Map<String, dynamic> plain) async {
    final secretKey = SecretKey(keyBytes);
    final box = await _algorithm.encrypt(
      utf8.encode(jsonEncode(plain)),
      secretKey: secretKey,
    );
    final nonceEnd = box.nonce.length;
    final cipherEnd = nonceEnd + box.cipherText.length;
    final total = cipherEnd + box.mac.bytes.length;
    final wire = Uint8List(total)
      ..setRange(0, nonceEnd, box.nonce)
      ..setRange(nonceEnd, cipherEnd, box.cipherText)
      ..setRange(cipherEnd, total, box.mac.bytes);
    return base64.encode(wire);
  }

  Future<Map<String, dynamic>> decryptField(String blobB64) async {
    final raw = base64.decode(blobB64);
    final nonce = raw.sublist(0, _nonceLength);
    final mac = raw.sublist(raw.length - _macLength);
    final cipherText = raw.sublist(_nonceLength, raw.length - _macLength);
    final secretKey = SecretKey(keyBytes);
    final clear = await _algorithm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: secretKey,
    );
    return jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
  }
}
