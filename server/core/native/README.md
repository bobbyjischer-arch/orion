# O.R.I.O.N. Cascade Crypto — native core

High-performance C++ implementation of the O.R.I.O.N. multi-layer (cascade)
encryption used for outgoing iOS → server traffic. **Byte-for-byte compatible**
with the pure-Python reference in [`../crypto.py`](../crypto.py), which is the
source of truth for the wire format.

## Why two implementations

- `core/crypto.py` — pure-Python, zero deps, works everywhere. Used by default
  and to validate the wire format in tests. This is the **reference**.
- `orion_crypto.cpp` — the fast path. When compiled to a shared library, it is
  loaded automatically by `crypto.py` via `ctypes` (`native_available()` → True).

Both produce identical bytes, so encrypting with one and decrypting with the
other must always succeed.

## Wire format

```
MAGIC("ORNC") | VER(1) | SALT(16) | CIPHERTEXT | TAG(32)
```

Cascade: `HKDF-SHA256(secret, salt)` → subkeys → `ChaCha20(k2,n2, ChaCha20(k1,n1, pt))`
→ `TAG = HMAC-SHA256(k_mac, MAGIC|VER|SALT|CIPHERTEXT)` (encrypt-then-MAC).
ChaCha20 follows RFC 8439 with initial counter = 1.

## Build

Requires a C++17 compiler and CMake (neither is installed on the current dev
box — build this on the deployment host or in CI).

```bash
cd core/native
cmake -B build
cmake --build build --config Release
ctest --test-dir build --output-on-failure   # runs the known-answer test
```

The build copies `liborion_crypto.{so,dylib}` / `orion_crypto.dll` next to the
source, where `crypto.py` looks for it.

## Known-answer vector (parity check)

`secret = "a-very-long-random-shared-secret-32b!!"`, `salt = 00 01 02 … 0f`,
`plaintext = "hello"` must encrypt to exactly:

```
4f524e4301000102030405060708090a0b0c0d0e0fd6c35058b3eca03cb3dc6b5a740f64798517d4712202401525a1a8caec2f82c6bce605be54
```

`orion_crypto_test` (the CMake `kat` test) prints this and round-trips it. If the
C++ output differs from this vector, the two implementations have diverged —
`crypto.py` wins.

## iOS side

The Swift client encryptor (`ORION/Services/CascadeCrypto.swift`) implements the
same format on-device using CryptoKit, so the phone encrypts and the server
(`/secure/ingest`) decrypts with the same shared secret.
