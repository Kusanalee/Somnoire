#define __STDC_WANT_LIB_EXT1__ 1
#include "ProbeCrypto.h"
#include "../Vendor/micro-ecc/uECC.h"
#include <Security/SecRandom.h>
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <string.h>

// Secret values never enter Swift Data, diagnostics, files, or subprocesses.
struct SNProbeCrypto {
    uint8_t private_key[21];
    uint8_t key[16];
    uint8_t iv[16];
    int ready;
};
#ifdef DEBUG
static int force_rng_failure;
void sn_probe_test_rng_failure(int fail) { force_rng_failure = fail; }
#endif
static void wipe(void *memory, size_t size) { (void)memset_s(memory, size, 0, size); }
static int secure_random(uint8_t *dest, unsigned size) {
#ifdef DEBUG
    if (force_rng_failure) return 0;
#endif
    return SecRandomCopyBytes(kSecRandomDefault, size, dest) == errSecSuccess;
}
static void initialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ uECC_set_rng(secure_random); });
}
SNProbeCrypto *sn_probe_create(uint8_t public_key[40]) {
    initialize();
    SNProbeCrypto *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    if (!uECC_make_key(public_key, c->private_key, uECC_secp160r1())) {
        sn_probe_destroy(c); wipe(public_key, 40); return NULL;
    }
    return c;
}
int sn_probe_accept_peer(SNProbeCrypto *c, const uint8_t peer[40]) {
    if (!c || c->ready || !uECC_valid_public_key(peer, uECC_secp160r1())) return 0;
    uint8_t secret[20] = {0};
    int ok = uECC_shared_secret(peer, c->private_key, secret, uECC_secp160r1());
    wipe(c->private_key, sizeof(c->private_key));
    if (ok) {
        memcpy(c->key, secret, sizeof(c->key));
        // MD5 is prescribed by this legacy device protocol, not chosen for new security.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CC_MD5(secret, sizeof(secret), c->iv);
#pragma clang diagnostic pop
        c->ready = 1;
    }
    wipe(secret, sizeof(secret));
    return ok;
}
int sn_probe_validate_info(SNProbeCrypto *c, const uint8_t *ciphertext, size_t length) {
    if (!c || c->ready != 1 || !ciphertext || length != 32) return 0;
    uint8_t plaintext[32] = {0};
    size_t written = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        c->key, sizeof(c->key), c->iv, ciphertext, length,
        plaintext, sizeof(plaintext), &written);
    int valid = status == kCCSuccess && written == 18;
    wipe(plaintext, sizeof(plaintext));
    return valid;
}

static int table_offset(uint8_t first, uint8_t second, size_t *offset) {
    size_t pos = (size_t)first * 16 + (size_t)((second - 1) & 0xff) * 256;
    if (pos > 65280 - 16) return 0;
    *offset = pos;
    return 1;
}
int sn_probe_derive_session(SNProbeCrypto *c, const uint8_t *ciphertext, size_t length,
    const uint8_t *table, size_t table_length) {
    if (!c || c->ready != 1 || !ciphertext || length != 32 || !table || table_length != 65280) return 0;
    static const uint8_t expected[32] = {
        0x3d,0x1b,0xa5,0x9b,0x40,0xc4,0x6b,0xc8,0x6b,0xa3,0x5f,0xa2,0x31,0xa3,0xdb,0x19,
        0x6b,0x44,0x8b,0xbd,0xfb,0x16,0x35,0xc8,0x8d,0xdd,0x42,0xf2,0x4a,0xbd,0x4b,0x2a
    };
    uint8_t digest[32];
    CC_SHA256(table, (CC_LONG)table_length, digest);
    int valid = memcmp(digest, expected, sizeof(digest)) == 0;
    wipe(digest, sizeof(digest));
    if (!valid) return 0;
    uint8_t plaintext[32] = {0}, material[32] = {0};
    size_t written = 0, offset = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        c->key, sizeof(c->key), c->iv, ciphertext, length, plaintext, sizeof(plaintext), &written);
    valid = status == kCCSuccess && written == 18 && table_offset(plaintext[16], plaintext[17], &offset);
    if (valid) {
        memcpy(material, table + offset, 16);
        memcpy(material + 16, plaintext, 16);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CC_MD5(material, sizeof(material), c->key);
#pragma clang diagnostic pop
        c->ready = 2;
    }
    wipe(plaintext, sizeof(plaintext)); wipe(material, sizeof(material));
    return valid;
}
static uint16_t crc16(const uint8_t *data, size_t length) {
    uint16_t crc = 0;
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (int bit = 0; bit < 8; ++bit) crc = (crc & 1) ? (crc >> 1) ^ 0xa001 : crc >> 1;
    }
    return crc;
}
static uint8_t crc8(const uint8_t *data, size_t length) {
    uint8_t crc = 0;
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (int bit = 0; bit < 8; ++bit) crc = (crc & 0x80) ? (crc << 1) ^ 7 : crc << 1;
    }
    return crc;
}
int sn_probe_status_request(SNProbeCrypto *c, uint8_t ciphertext[32]) {
    if (!c || c->ready != 2 || !ciphertext) return 0;
    uint8_t packet[20] = {0xaa, 3, 0, 0, 0, 0x0d, 0, 0, 0, 0, 0, 0, 0x21, 0x35, 1, 1, 0x35, 0x89, 0, 0};
    packet[4] = crc8(packet, 4);
    uint16_t crc = crc16(packet, 18);
    packet[18] = crc & 255; packet[19] = crc >> 8;
    size_t written = 0;
    CCCryptorStatus status = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        c->key, sizeof(c->key), c->iv, packet, sizeof(packet), ciphertext, 32, &written);
    wipe(packet, sizeof(packet));
    if (status != kCCSuccess || written != 32) { wipe(ciphertext, 32); return 0; }
    return 1;
}
int sn_probe_status_reply(SNProbeCrypto *c, const uint8_t *ciphertext, size_t length) {
    if (!c || c->ready != 2 || !ciphertext || !length || length % 16 || length > 1008) return -1;
    uint8_t packet[1024] = {0};
    size_t written = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        c->key, sizeof(c->key), c->iv, ciphertext, length, packet, sizeof(packet), &written);
    int result = -1;
    if (status == kCCSuccess && written >= 20 && packet[0] == 0xaa && packet[1] == 3 &&
        written == 20 + (size_t)packet[2] + ((size_t)packet[3] << 8) &&
        crc8(packet, 4) == packet[4] &&
        crc16(packet, written - 2) == ((uint16_t)packet[written - 2] | ((uint16_t)packet[written - 1] << 8))) {
        result = packet[12] == 0x35 && packet[13] == 0x21 && packet[14] == 1 && packet[15] == 1 &&
            packet[16] == 0x35 && packet[17] == 0x89 &&
            packet[6] == 0 && packet[7] == 0 && packet[8] == 0 && packet[9] == 0 ? 1 : 0;
    }
    wipe(packet, sizeof(packet));
    return result;
}
void sn_probe_destroy(SNProbeCrypto *c) {
    if (c) { wipe(c, sizeof(*c)); free(c); }
}
#ifdef DEBUG
int sn_probe_test_session_key(SNProbeCrypto *c, uint8_t key[16]) {
    if (!c || c->ready != 2) return 0;
    memcpy(key, c->key, 16); return 1;
}
int sn_probe_test_offset(uint8_t first, uint8_t second, size_t *offset) { return table_offset(first, second, offset); }
SNProbeCrypto *sn_probe_test_create(const uint8_t private_key[21], uint8_t public_key[40]) {
    initialize();
    SNProbeCrypto *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    memcpy(c->private_key, private_key, 21);
    if (!uECC_compute_public_key(c->private_key, public_key, uECC_secp160r1())) {
        sn_probe_destroy(c); return NULL;
    }
    return c;
}
int sn_probe_test_shared(const uint8_t private_key[21], const uint8_t peer[40], uint8_t secret[20]) {
    initialize();
    return uECC_valid_public_key(peer, uECC_secp160r1()) &&
        uECC_shared_secret(peer, private_key, secret, uECC_secp160r1());
}
#endif
