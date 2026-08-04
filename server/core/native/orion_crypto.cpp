// ╔══════════════════════════════════════════════════════════════╗
// ║  O.R.I.O.N. CASCADE CRYPTO — C++ core (fast path)            ║
// ║  Байт-в-байт совместим с core/crypto.py (эталон).            ║
// ╚══════════════════════════════════════════════════════════════╝
//
// Каскад: HKDF-SHA256 → 2×ChaCha20 → encrypt-then-HMAC-SHA256.
// Формат: MAGIC("ORNC") | VER(1) | SALT(16) | CIPHERTEXT | TAG(32).
//
// Экспортирует C-ABI для ctypes:
//   int orion_encrypt(pt, pt_len, secret, secret_len, salt16, out, out_cap)
//   int orion_decrypt(packet, packet_len, secret, secret_len, out, out_cap)
// Возвращает число записанных байт или -1.
//
// Зависимостей нет: SHA-256, HMAC, HKDF, ChaCha20 реализованы здесь.
// Сборка: см. CMakeLists.txt (cmake -B build && cmake --build build).

#include <cstdint>
#include <cstring>
#include <cstddef>
#include <vector>

#if defined(_WIN32)
#define ORION_API extern "C" __declspec(dllexport)
#else
#define ORION_API extern "C" __attribute__((visibility("default")))
#endif

namespace {

// ─────────────── SHA-256 ───────────────
struct SHA256 {
    uint32_t h[8];
    uint64_t len = 0;
    uint8_t buf[64];
    size_t buf_len = 0;

    static uint32_t rotr(uint32_t x, uint32_t n) { return (x >> n) | (x << (32 - n)); }

    SHA256() {
        static const uint32_t iv[8] = {
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
        std::memcpy(h, iv, sizeof(iv));
    }

    void block(const uint8_t* p) {
        static const uint32_t k[64] = {
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = (p[i*4] << 24) | (p[i*4+1] << 16) | (p[i*4+2] << 8) | p[i*4+3];
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = rotr(w[i-15],7) ^ rotr(w[i-15],18) ^ (w[i-15] >> 3);
            uint32_t s1 = rotr(w[i-2],17) ^ rotr(w[i-2],19) ^ (w[i-2] >> 10);
            w[i] = w[i-16] + s0 + w[i-7] + s1;
        }
        uint32_t a=h[0],b=h[1],c=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];
        for (int i = 0; i < 64; i++) {
            uint32_t S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = hh + S1 + ch + k[i] + w[i];
            uint32_t S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22);
            uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = S0 + maj;
            hh=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
        }
        h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d; h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh;
    }

    void update(const uint8_t* data, size_t n) {
        len += n;
        while (n > 0) {
            size_t take = 64 - buf_len;
            if (take > n) take = n;
            std::memcpy(buf + buf_len, data, take);
            buf_len += take; data += take; n -= take;
            if (buf_len == 64) { block(buf); buf_len = 0; }
        }
    }

    void final(uint8_t out[32]) {
        uint64_t bits = len * 8;
        uint8_t pad = 0x80;
        update(&pad, 1);
        uint8_t zero = 0;
        while (buf_len != 56) update(&zero, 1);
        uint8_t lenbuf[8];
        for (int i = 0; i < 8; i++) lenbuf[i] = (bits >> (56 - i*8)) & 0xff;
        update(lenbuf, 8);
        for (int i = 0; i < 8; i++) {
            out[i*4]   = (h[i] >> 24) & 0xff;
            out[i*4+1] = (h[i] >> 16) & 0xff;
            out[i*4+2] = (h[i] >> 8) & 0xff;
            out[i*4+3] = h[i] & 0xff;
        }
    }
};

void sha256(const uint8_t* d, size_t n, uint8_t out[32]) {
    SHA256 s; s.update(d, n); s.final(out);
}

// ─────────────── HMAC-SHA256 ───────────────
void hmac_sha256(const uint8_t* key, size_t key_len,
                 const uint8_t* msg, size_t msg_len, uint8_t out[32]) {
    uint8_t k[64] = {0};
    if (key_len > 64) { sha256(key, key_len, k); }
    else std::memcpy(k, key, key_len);
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; i++) { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c; }
    uint8_t inner[32];
    { SHA256 s; s.update(ipad, 64); s.update(msg, msg_len); s.final(inner); }
    { SHA256 s; s.update(opad, 64); s.update(inner, 32); s.final(out); }
}

// ─────────────── HKDF-SHA256 ───────────────
void hkdf_sha256(const uint8_t* secret, size_t secret_len,
                 const uint8_t* salt, size_t salt_len,
                 const uint8_t* info, size_t info_len,
                 uint8_t* out, size_t length) {
    uint8_t prk[32];
    hmac_sha256(salt, salt_len, secret, secret_len, prk);   // extract
    uint8_t t[32];
    size_t t_len = 0, done = 0;
    uint8_t counter = 1;
    while (done < length) {                                  // expand
        std::vector<uint8_t> in;
        in.insert(in.end(), t, t + t_len);
        in.insert(in.end(), info, info + info_len);
        in.push_back(counter);
        hmac_sha256(prk, 32, in.data(), in.size(), t);
        t_len = 32;
        size_t take = (length - done < 32) ? (length - done) : 32;
        std::memcpy(out + done, t, take);
        done += take; counter++;
    }
}

// ─────────────── ChaCha20 (RFC 8439) ───────────────
inline uint32_t rotl32(uint32_t x, int n) { return (x << n) | (x >> (32 - n)); }
inline uint32_t load32(const uint8_t* p) {
    return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24);
}

void chacha20_block(const uint8_t key[32], uint32_t counter, const uint8_t nonce[12], uint8_t out[64]) {
    uint32_t state[16] = {
        0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
        load32(key),    load32(key+4),  load32(key+8),  load32(key+12),
        load32(key+16), load32(key+20), load32(key+24), load32(key+28),
        counter, load32(nonce), load32(nonce+4), load32(nonce+8)};
    uint32_t w[16];
    std::memcpy(w, state, sizeof(w));
    auto QR = [&](int a, int b, int c, int d) {
        w[a] += w[b]; w[d] = rotl32(w[d] ^ w[a], 16);
        w[c] += w[d]; w[b] = rotl32(w[b] ^ w[c], 12);
        w[a] += w[b]; w[d] = rotl32(w[d] ^ w[a], 8);
        w[c] += w[d]; w[b] = rotl32(w[b] ^ w[c], 7);
    };
    for (int i = 0; i < 10; i++) {
        QR(0,4,8,12); QR(1,5,9,13); QR(2,6,10,14); QR(3,7,11,15);
        QR(0,5,10,15); QR(1,6,11,12); QR(2,7,8,13); QR(3,4,9,14);
    }
    for (int i = 0; i < 16; i++) {
        uint32_t v = w[i] + state[i];
        out[i*4] = v & 0xff; out[i*4+1] = (v>>8)&0xff;
        out[i*4+2] = (v>>16)&0xff; out[i*4+3] = (v>>24)&0xff;
    }
}

void chacha20_xor(const uint8_t key[32], const uint8_t nonce[12],
                  const uint8_t* in, uint8_t* out, size_t len, uint32_t counter) {
    uint8_t ks[64];
    size_t off = 0; uint32_t blk = counter;
    while (off < len) {
        chacha20_block(key, blk, nonce, ks);
        size_t take = (len - off < 64) ? (len - off) : 64;
        for (size_t i = 0; i < take; i++) out[off+i] = in[off+i] ^ ks[i];
        off += take; blk++;
    }
}

// ─────────────── Каскад ───────────────
constexpr size_t SALT_LEN = 16, TAG_LEN = 32;
const uint8_t MAGIC[4] = {'O','R','N','C'};
constexpr uint8_t VERSION = 1;

struct Keys { uint8_t k1[32], n1[12], k2[32], n2[12], kmac[32]; };

void derive(const uint8_t* secret, size_t secret_len, const uint8_t* salt, Keys& out) {
    uint8_t mat[120];
    const char* info = "orion-cascade-v1";
    hkdf_sha256(secret, secret_len, salt, SALT_LEN,
                (const uint8_t*)info, std::strlen(info), mat, 120);
    std::memcpy(out.k1, mat, 32);
    std::memcpy(out.n1, mat+32, 12);
    std::memcpy(out.k2, mat+44, 32);
    std::memcpy(out.n2, mat+76, 12);
    std::memcpy(out.kmac, mat+88, 32);
}

bool ct_equal(const uint8_t* a, const uint8_t* b, size_t n) {
    uint8_t r = 0;
    for (size_t i = 0; i < n; i++) r |= a[i] ^ b[i];
    return r == 0;
}

} // namespace

ORION_API int orion_encrypt(const char* pt, size_t pt_len,
                            const char* secret, size_t secret_len,
                            const char* salt16,
                            char* out, size_t out_cap) {
    size_t total = 4 + 1 + SALT_LEN + pt_len + TAG_LEN;
    if (out_cap < total) return -1;
    Keys keys;
    derive((const uint8_t*)secret, secret_len, (const uint8_t*)salt16, keys);

    std::vector<uint8_t> inner(pt_len), cipher(pt_len);
    chacha20_xor(keys.k1, keys.n1, (const uint8_t*)pt, inner.data(), pt_len, 1);
    chacha20_xor(keys.k2, keys.n2, inner.data(), cipher.data(), pt_len, 1);

    uint8_t* o = (uint8_t*)out;
    std::memcpy(o, MAGIC, 4);
    o[4] = VERSION;
    std::memcpy(o+5, salt16, SALT_LEN);
    std::memcpy(o+5+SALT_LEN, cipher.data(), pt_len);

    size_t header_ct = 5 + SALT_LEN + pt_len;
    uint8_t tag[32];
    hmac_sha256(keys.kmac, 32, o, header_ct, tag);
    std::memcpy(o + header_ct, tag, TAG_LEN);
    return (int)total;
}

ORION_API int orion_decrypt(const char* packet, size_t packet_len,
                            const char* secret, size_t secret_len,
                            char* out, size_t out_cap) {
    if (packet_len < 5 + SALT_LEN + TAG_LEN) return -1;
    const uint8_t* p = (const uint8_t*)packet;
    if (std::memcmp(p, MAGIC, 4) != 0) return -1;
    if (p[4] != VERSION) return -1;
    const uint8_t* salt = p + 5;
    size_t ct_len = packet_len - 5 - SALT_LEN - TAG_LEN;
    if (out_cap < ct_len) return -1;
    const uint8_t* cipher = p + 5 + SALT_LEN;
    const uint8_t* tag = p + packet_len - TAG_LEN;

    Keys keys;
    derive((const uint8_t*)secret, secret_len, salt, keys);
    uint8_t expected[32];
    hmac_sha256(keys.kmac, 32, p, 5 + SALT_LEN + ct_len, expected);
    if (!ct_equal(expected, tag, TAG_LEN)) return -1;

    std::vector<uint8_t> inner(ct_len);
    chacha20_xor(keys.k2, keys.n2, cipher, inner.data(), ct_len, 1);
    chacha20_xor(keys.k1, keys.n1, inner.data(), (uint8_t*)out, ct_len, 1);
    return (int)ct_len;
}

// Небольшой self-test при сборке как исполняемого файла (cmake target orion_crypto_test).
#ifdef ORION_CRYPTO_MAIN
#include <cstdio>
int main() {
    const char* secret = "a-very-long-random-shared-secret-32b!!";
    uint8_t salt[16]; for (int i = 0; i < 16; i++) salt[i] = i;
    const char* msg = "hello";
    char enc[128];
    int n = orion_encrypt(msg, 5, secret, std::strlen(secret), (char*)salt, enc, sizeof(enc));
    printf("encrypted %d bytes: ", n);
    for (int i = 0; i < n; i++) printf("%02x", (uint8_t)enc[i]);
    printf("\n");
    char dec[128];
    int m = orion_decrypt(enc, n, secret, std::strlen(secret), dec, sizeof(dec));
    printf("decrypted %d bytes: %.*s\n", m, m, dec);
    // Ожидаемый вектор из core/crypto.py:
    // 4f524e4301000102030405060708090a0b0c0d0e0fd6c35058b3eca03cb3dc6b5a740f64798517d4712202401525a1a8caec2f82c6bce605be54
    return (m == 5 && std::memcmp(dec, "hello", 5) == 0) ? 0 : 1;
}
#endif
