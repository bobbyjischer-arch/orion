"""Self-contained tests for the cascade crypto core.

Run: python tests/test_crypto.py   (exits non-zero on failure)
No pytest dependency so it runs anywhere.
"""
import binascii
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from core import crypto  # noqa: E402

FAIL = 0


def check(name, cond):
    global FAIL
    print(("PASS " if cond else "FAIL ") + name)
    if not cond:
        FAIL += 1


# RFC 8439 §2.4.2 ChaCha20 vector
key = bytes(range(32))
nonce = binascii.unhexlify("000000000000004a00000000")
pt = (b"Ladies and Gentlemen of the class of '99: If I could offer you "
      b"only one tip for the future, sunscreen would be it.")
exp = ("6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b"
       "f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8"
       "07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab7793736"
       "5af90bbf74a35be6b40b8eedf2785e42874d")
check("ChaCha20 RFC 8439 vector",
      binascii.hexlify(crypto.chacha20_xor(key, nonce, pt, 1)).decode() == exp)

secret = b"a-very-long-random-shared-secret-32b!!"

# Roundtrip over sizes
ok = True
for msg in [b"", b"x", b'{"lat":55.75,"lon":37.61}', b"A" * 5000, bytes(range(256))]:
    ok = ok and crypto.decrypt_py(crypto.encrypt_py(msg, secret), secret) == msg
check("cascade roundtrip (multi-size)", ok)

# Known-answer vector (must match C++ core + README)
salt = bytes(range(16))
kat = binascii.hexlify(crypto.encrypt_py(b"hello", secret, salt)).decode()
expected_kat = ("4f524e4301000102030405060708090a0b0c0d0e0f"
                "d6c35058b3eca03cb3dc6b5a740f64798517d471"
                "2202401525a1a8caec2f82c6bce605be54")
check("known-answer vector (C++ parity)", kat == expected_kat)

# Tamper detection
pkt = bytearray(crypto.encrypt_py(b"payload", secret))
pkt[-1] ^= 1
try:
    crypto.decrypt_py(bytes(pkt), secret)
    check("tamper detected", False)
except ValueError:
    check("tamper detected", True)

# Wrong key
try:
    crypto.decrypt_py(crypto.encrypt_py(b"hi", secret), b"nope" * 8)
    check("wrong key rejected", False)
except ValueError:
    check("wrong key rejected", True)

# base64 wrapper
check("base64 roundtrip",
      crypto.decrypt_b64(crypto.encrypt_b64(b'{"a":1}', secret), secret) == b'{"a":1}')

if FAIL:
    print(f"\n{FAIL} FAILURE(S)")
    sys.exit(1)
print("\nAll crypto tests passed.")
