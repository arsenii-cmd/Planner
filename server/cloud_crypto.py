"""AES-256-GCM helper for the cloud sync channel (plannerd <-> planner.example.com).

Wire format, shared byte-for-byte with app/lib/crypto.dart:
    base64( nonce[12 bytes] || ciphertext || tag[16 bytes] )
No AAD: the only two parties that ever hold the key are the owner's own devices.
The server this blob passes through never sees the key or the plaintext.
"""

import base64
import json
import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

KEY_BYTES = 32
NONCE_BYTES = 12


def new_key() -> bytes:
    return os.urandom(KEY_BYTES)


class CloudCrypto:
    def __init__(self, key: bytes):
        if len(key) != KEY_BYTES:
            raise ValueError("cloud key must be %d bytes" % KEY_BYTES)
        self.aesgcm = AESGCM(key)

    def encrypt(self, obj) -> str:
        nonce = os.urandom(NONCE_BYTES)
        ct = self.aesgcm.encrypt(nonce, json.dumps(obj, ensure_ascii=False).encode(), None)
        return base64.b64encode(nonce + ct).decode()

    def decrypt(self, blob_b64: str):
        raw = base64.b64decode(blob_b64)
        nonce, ct = raw[:NONCE_BYTES], raw[NONCE_BYTES:]
        return json.loads(self.aesgcm.decrypt(nonce, ct, None))
