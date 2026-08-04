"""
╔══════════════════════════════════════════════════════════════╗
║  O.R.I.O.N. CASCADE CRYPTO  —  многослойное шифрование        ║
║  Каскад: HKDF → 2 слоя ChaCha20 → encrypt-then-HMAC-SHA256    ║
╚══════════════════════════════════════════════════════════════╝

Назначение
----------
iOS-приложение шифрует исходящий трафик ЭТИМ форматом перед отправкой
на сервер; core расшифровывает во входящем эндпоинте `/secure/ingest`.
Слой прикладного шифрования поверх TLS: даже при MITM/перехвате
(или скомпрометированном TLS-прокси) полезная нагрузка нечитаема без
общего секрета, а HMAC отсекает подделку.

Формат пакета (wire)
--------------------
Base64( MAGIC(4) | VER(1) | SALT(16) | CIPHERTEXT | TAG(32) )

    MAGIC  = b"ORNC"            маркер формата
    VER    = 1                  версия каскада
    SALT   = 16 случайных байт  соль HKDF (уникальна на сообщение)
    TAG    = HMAC_SHA256(k_mac, MAGIC|VER|SALT|CIPHERTEXT)  (encrypt-then-MAC)

Ключи (HKDF-SHA256 из общего секрета + SALT):
    k1  (32)  — ChaCha20 слой 1
    n1  (12)  — nonce слоя 1
    k2  (32)  — ChaCha20 слой 2
    n2  (12)  — nonce слоя 2
    k_mac(32) — HMAC-SHA256

CIPHERTEXT = ChaCha20(k2,n2, ChaCha20(k1,n1, plaintext))

Взаимозаменяемость
------------------
Есть две реализации ОДНОГО формата:
  • pure-Python (этот файл) — работает везде, используется по умолчанию;
  • C++ ядро (core/native/orion_crypto.cpp) — быстрый путь, грузится
    через ctypes, если собран (`liborion_crypto.{so,dll,dylib}`).
`encrypt`/`decrypt` автоматически берут C++, когда он доступен, иначе Python.
Оба дают идентичные байты — совместимость проверяется тестом.

Замечание по безопасности
-------------------------
Двухслойный ChaCha20 — «каскад» по требованию ТЗ. Он не слабее одного
слоя; основную стойкость даёт HKDF + encrypt-then-HMAC. Общий секрет
должен быть длинным случайным (32+ байта) и храниться в Keychain (iOS)
и в переменной окружения ORION_CASCADE_SECRET (сервер).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import struct
from typing import Optional

MAGIC = b"ORNC"
VERSION = 1
SALT_LEN = 16
TAG_LEN = 32


# ─────────────────────────────────────────────────────────────
#  Примитивы (чистый Python, без внешних зависимостей)
# ─────────────────────────────────────────────────────────────

def hkdf_sha256(secret: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    """HKDF (RFC 5869) на HMAC-SHA256."""
    prk = hmac.new(salt, secret, hashlib.sha256).digest()  # extract
    out = b""
    t = b""
    counter = 1
    while len(out) < length:                                # expand
        t = hmac.new(prk, t + info + bytes([counter]), hashlib.sha256).digest()
        out += t
        counter += 1
    return out[:length]


def _rotl32(x: int, n: int) -> int:
    x &= 0xFFFFFFFF
    return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF


def _chacha20_block(key: bytes, counter: int, nonce: bytes) -> bytes:
    """Одна 64-байтная гамма ChaCha20 (RFC 8439)."""
    constants = (0x61707865, 0x3320646e, 0x79622d32, 0x6b206574)
    key_words = struct.unpack("<8I", key)
    nonce_words = struct.unpack("<3I", nonce)
    state = list(constants) + list(key_words) + [counter & 0xFFFFFFFF] + list(nonce_words)
    working = state[:]

    def qr(a, b, c, d):
        working[a] = (working[a] + working[b]) & 0xFFFFFFFF
        working[d] = _rotl32(working[d] ^ working[a], 16)
        working[c] = (working[c] + working[d]) & 0xFFFFFFFF
        working[b] = _rotl32(working[b] ^ working[c], 12)
        working[a] = (working[a] + working[b]) & 0xFFFFFFFF
        working[d] = _rotl32(working[d] ^ working[a], 8)
        working[c] = (working[c] + working[d]) & 0xFFFFFFFF
        working[b] = _rotl32(working[b] ^ working[c], 7)

    for _ in range(10):  # 20 раундов = 10 двойных
        qr(0, 4, 8, 12); qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15)
        qr(0, 5, 10, 15); qr(1, 6, 11, 12); qr(2, 7, 8, 13); qr(3, 4, 9, 14)

    out = [(working[i] + state[i]) & 0xFFFFFFFF for i in range(16)]
    return struct.pack("<16I", *out)


def chacha20_xor(key: bytes, nonce: bytes, data: bytes, counter: int = 1) -> bytes:
    """ChaCha20 keystream XOR (RFC 8439; начальный счётчик = 1)."""
    out = bytearray(len(data))
    blk = counter
    for offset in range(0, len(data), 64):
        keystream = _chacha20_block(key, blk, nonce)
        chunk = data[offset:offset + 64]
        for i, b in enumerate(chunk):
            out[offset + i] = b ^ keystream[i]
        blk += 1
    return bytes(out)


# ─────────────────────────────────────────────────────────────
#  Каскад (эталонная реализация)
# ─────────────────────────────────────────────────────────────

def _derive(secret: bytes, salt: bytes):
    material = hkdf_sha256(secret, salt, b"orion-cascade-v1", 32 + 12 + 32 + 12 + 32)
    k1 = material[0:32]
    n1 = material[32:44]
    k2 = material[44:76]
    n2 = material[76:88]
    k_mac = material[88:120]
    return k1, n1, k2, n2, k_mac


def encrypt_py(plaintext: bytes, secret: bytes, salt: Optional[bytes] = None) -> bytes:
    """Зашифровать → wire-байты (без base64). Эталонная Python-реализация."""
    if salt is None:
        salt = os.urandom(SALT_LEN)
    if len(salt) != SALT_LEN:
        raise ValueError("salt must be 16 bytes")
    k1, n1, k2, n2, k_mac = _derive(secret, salt)
    inner = chacha20_xor(k1, n1, plaintext)
    ciphertext = chacha20_xor(k2, n2, inner)
    header = MAGIC + bytes([VERSION]) + salt
    tag = hmac.new(k_mac, header + ciphertext, hashlib.sha256).digest()
    return header + ciphertext + tag


def decrypt_py(packet: bytes, secret: bytes) -> bytes:
    """Расшифровать wire-байты → plaintext. Проверяет MAGIC/версию/HMAC."""
    if len(packet) < 4 + 1 + SALT_LEN + TAG_LEN:
        raise ValueError("packet too short")
    if packet[0:4] != MAGIC:
        raise ValueError("bad magic")
    if packet[4] != VERSION:
        raise ValueError(f"unsupported version {packet[4]}")
    salt = packet[5:5 + SALT_LEN]
    tag = packet[-TAG_LEN:]
    ciphertext = packet[5 + SALT_LEN:-TAG_LEN]
    header = packet[:5 + SALT_LEN]
    k1, n1, k2, n2, k_mac = _derive(secret, salt)
    expected = hmac.new(k_mac, header + ciphertext, hashlib.sha256).digest()
    if not hmac.compare_digest(expected, tag):
        raise ValueError("HMAC verification failed (tampered or wrong key)")
    inner = chacha20_xor(k2, n2, ciphertext)
    return chacha20_xor(k1, n1, inner)


# ─────────────────────────────────────────────────────────────
#  Загрузчик C++ ядра (быстрый путь, опционально)
# ─────────────────────────────────────────────────────────────

_native = None
_native_tried = False


def _load_native():
    """Пытается подгрузить скомпилированное C++ ядро через ctypes."""
    global _native, _native_tried
    if _native_tried:
        return _native
    _native_tried = True
    import ctypes
    from pathlib import Path
    here = Path(__file__).parent / "native"
    for name in ("liborion_crypto.so", "orion_crypto.dll",
                 "liborion_crypto.dylib", "liborion_crypto.dll"):
        p = here / name
        if not p.exists():
            continue
        try:
            lib = ctypes.CDLL(str(p))
            # int orion_encrypt(const uint8_t* pt, size_t pt_len,
            #                   const uint8_t* secret, size_t secret_len,
            #                   const uint8_t* salt16,
            #                   uint8_t* out, size_t out_cap);  -> bytes written or -1
            lib.orion_encrypt.restype = ctypes.c_int
            lib.orion_encrypt.argtypes = [
                ctypes.c_char_p, ctypes.c_size_t,
                ctypes.c_char_p, ctypes.c_size_t,
                ctypes.c_char_p,
                ctypes.c_char_p, ctypes.c_size_t,
            ]
            lib.orion_decrypt.restype = ctypes.c_int
            lib.orion_decrypt.argtypes = [
                ctypes.c_char_p, ctypes.c_size_t,
                ctypes.c_char_p, ctypes.c_size_t,
                ctypes.c_char_p, ctypes.c_size_t,
            ]
            _native = lib
            return _native
        except OSError:
            continue
    return None


def _encrypt_native(plaintext: bytes, secret: bytes, salt: bytes) -> Optional[bytes]:
    lib = _load_native()
    if lib is None:
        return None
    import ctypes
    cap = len(plaintext) + 4 + 1 + SALT_LEN + TAG_LEN
    buf = ctypes.create_string_buffer(cap)
    n = lib.orion_encrypt(plaintext, len(plaintext), secret, len(secret),
                          salt, buf, cap)
    if n < 0:
        return None
    return buf.raw[:n]


# ─────────────────────────────────────────────────────────────
#  Публичный API (авто-выбор реализации) + base64-обёртка
# ─────────────────────────────────────────────────────────────

def encrypt(plaintext: bytes, secret: bytes, salt: Optional[bytes] = None,
            prefer_native: bool = True) -> bytes:
    """Зашифровать → wire-байты. Использует C++ ядро, если оно собрано."""
    if prefer_native:
        s = salt if salt is not None else os.urandom(SALT_LEN)
        native = _encrypt_native(plaintext, secret, s)
        if native is not None:
            return native
        return encrypt_py(plaintext, secret, s)
    return encrypt_py(plaintext, secret, salt)


def decrypt(packet: bytes, secret: bytes) -> bytes:
    """Расшифровать wire-байты. Python-декодер (валидирует HMAC) —
    он и является эталоном совместимости с C++."""
    return decrypt_py(packet, secret)


def encrypt_b64(plaintext: bytes, secret: bytes) -> str:
    return base64.b64encode(encrypt(plaintext, secret)).decode("ascii")


def decrypt_b64(token: str, secret: bytes) -> bytes:
    return decrypt(base64.b64decode(token), secret)


def native_available() -> bool:
    return _load_native() is not None
