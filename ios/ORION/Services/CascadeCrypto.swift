import Foundation
import CryptoKit

/// Многослойное (каскадное) шифрование исходящего трафика.
///
/// Байт-в-байт совместимо с серверными реализациями
/// `orion_final/core/crypto.py` (эталон) и `core/native/orion_crypto.cpp`.
/// Приложение шифрует полезную нагрузку ЭТИМ форматом перед отправкой,
/// сервер расшифровывает в `/secure/ingest`.
///
/// Формат пакета:
///   MAGIC("ORNC") | VER(1) | SALT(16) | CIPHERTEXT | TAG(32)
///   CIPHERTEXT = ChaCha20(k2,n2, ChaCha20(k1,n1, plaintext))
///   TAG        = HMAC-SHA256(k_mac, MAGIC|VER|SALT|CIPHERTEXT)
/// Ключи выводятся HKDF-SHA256(secret, salt).
///
/// Прикладной слой поверх TLS: даже при перехвате/подмене TLS
/// payload остаётся нечитаемым без общего секрета, а HMAC ловит подделку.
enum CascadeCrypto {

    private static let magic: [UInt8] = Array("ORNC".utf8)
    private static let version: UInt8 = 1
    private static let saltLen = 16
    private static let info = Array("orion-cascade-v1".utf8)

    enum CryptoError: Error { case badFormat, badVersion, hmacMismatch }

    // MARK: - Public

    /// Зашифровать данные общим секретом. Возвращает wire-байты.
    static func encrypt(_ plaintext: Data, secret: Data, salt: Data? = nil) -> Data {
        let saltBytes: [UInt8]
        if let s = salt, s.count == saltLen {
            saltBytes = [UInt8](s)
        } else {
            // 16 криптослучайных байт через CryptoKit (без импорта Security).
            saltBytes = SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }
        }

        let keys = derive(secret: [UInt8](secret), salt: saltBytes)
        let inner = chacha20(key: keys.k1, nonce: keys.n1, data: [UInt8](plaintext))
        let cipher = chacha20(key: keys.k2, nonce: keys.n2, data: inner)

        var header = magic
        header.append(version)
        header.append(contentsOf: saltBytes)

        var headerCipher = header
        headerCipher.append(contentsOf: cipher)

        let tag = hmacSHA256(key: keys.kMac, message: headerCipher)
        var out = headerCipher
        out.append(contentsOf: tag)
        return Data(out)
    }

    /// Base64-строка для JSON-поля `payload`.
    static func encryptBase64(_ plaintext: Data, secret: Data) -> String {
        encrypt(plaintext, secret: secret).base64EncodedString()
    }

    /// Расшифровать (в основном для тестов на устройстве).
    static func decrypt(_ packet: Data, secret: Data) throws -> Data {
        let p = [UInt8](packet)
        guard p.count >= 5 + saltLen + 32 else { throw CryptoError.badFormat }
        guard Array(p[0..<4]) == magic else { throw CryptoError.badFormat }
        guard p[4] == version else { throw CryptoError.badVersion }

        let salt = Array(p[5..<(5 + saltLen)])
        let tag = Array(p[(p.count - 32)...])
        let cipher = Array(p[(5 + saltLen)..<(p.count - 32)])
        let header = Array(p[0..<(5 + saltLen)])

        let keys = derive(secret: [UInt8](secret), salt: salt)
        let expected = hmacSHA256(key: keys.kMac, message: header + cipher)
        guard constantTimeEqual(expected, tag) else { throw CryptoError.hmacMismatch }

        let inner = chacha20(key: keys.k2, nonce: keys.n2, data: cipher)
        let plain = chacha20(key: keys.k1, nonce: keys.n1, data: inner)
        return Data(plain)
    }

    // MARK: - Key derivation

    private struct Keys {
        let k1: [UInt8]; let n1: [UInt8]
        let k2: [UInt8]; let n2: [UInt8]
        let kMac: [UInt8]
    }

    private static func derive(secret: [UInt8], salt: [UInt8]) -> Keys {
        // HKDF-SHA256, 120 байт материала: k1|n1|k2|n2|kMac
        let material = hkdfSHA256(secret: secret, salt: salt, info: info, length: 32 + 12 + 32 + 12 + 32)
        return Keys(
            k1: Array(material[0..<32]),
            n1: Array(material[32..<44]),
            k2: Array(material[44..<76]),
            n2: Array(material[76..<88]),
            kMac: Array(material[88..<120])
        )
    }

    private static func hkdfSHA256(secret: [UInt8], salt: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        // extract
        let prk = HMAC<SHA256>.authenticationCode(
            for: Data(secret), using: SymmetricKey(data: Data(salt)))
        let prkKey = SymmetricKey(data: Data(prk))
        // expand
        var out = [UInt8]()
        var t = [UInt8]()
        var counter: UInt8 = 1
        while out.count < length {
            var block = t
            block.append(contentsOf: info)
            block.append(counter)
            let mac = HMAC<SHA256>.authenticationCode(for: Data(block), using: prkKey)
            t = [UInt8](mac)
            out.append(contentsOf: t)
            counter &+= 1
        }
        return Array(out[0..<length])
    }

    // MARK: - HMAC / ChaCha20

    private static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message), using: SymmetricKey(data: Data(key)))
        return [UInt8](mac)
    }

    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var r: UInt8 = 0
        for i in 0..<a.count { r |= a[i] ^ b[i] }
        return r == 0
    }

    // ChaCha20 (RFC 8439), начальный счётчик = 1. Собственная реализация,
    // чтобы гарантировать совместимость формата с Python/C++ (CryptoKit
    // отдаёт только AEAD-обёртку ChaChaPoly, не сырой keystream).
    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x << n) | (x >> (32 - n))
    }

    private static func chachaBlock(key: [UInt8], counter: UInt32, nonce: [UInt8]) -> [UInt8] {
        func load32(_ arr: [UInt8], _ i: Int) -> UInt32 {
            UInt32(arr[i]) | (UInt32(arr[i+1]) << 8) | (UInt32(arr[i+2]) << 16) | (UInt32(arr[i+3]) << 24)
        }
        var state: [UInt32] = [
            0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
            load32(key, 0), load32(key, 4), load32(key, 8), load32(key, 12),
            load32(key, 16), load32(key, 20), load32(key, 24), load32(key, 28),
            counter, load32(nonce, 0), load32(nonce, 4), load32(nonce, 8)
        ]
        var w = state
        func qr(_ a: Int, _ b: Int, _ c: Int, _ d: Int) {
            w[a] = w[a] &+ w[b]; w[d] = rotl(w[d] ^ w[a], 16)
            w[c] = w[c] &+ w[d]; w[b] = rotl(w[b] ^ w[c], 12)
            w[a] = w[a] &+ w[b]; w[d] = rotl(w[d] ^ w[a], 8)
            w[c] = w[c] &+ w[d]; w[b] = rotl(w[b] ^ w[c], 7)
        }
        for _ in 0..<10 {
            qr(0,4,8,12); qr(1,5,9,13); qr(2,6,10,14); qr(3,7,11,15)
            qr(0,5,10,15); qr(1,6,11,12); qr(2,7,8,13); qr(3,4,9,14)
        }
        var out = [UInt8]()
        out.reserveCapacity(64)
        for i in 0..<16 {
            let v = w[i] &+ state[i]
            out.append(UInt8(v & 0xff))
            out.append(UInt8((v >> 8) & 0xff))
            out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 24) & 0xff))
        }
        return out
    }

    private static func chacha20(key: [UInt8], nonce: [UInt8], data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count)
        var blk: UInt32 = 1
        var off = 0
        while off < data.count {
            let ks = chachaBlock(key: key, counter: blk, nonce: nonce)
            let take = min(64, data.count - off)
            for i in 0..<take { out[off + i] = data[off + i] ^ ks[i] }
            off += take
            blk &+= 1
        }
        return out
    }
}
