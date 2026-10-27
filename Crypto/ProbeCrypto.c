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
    int credential_check_sent;
    int credential_authenticated;
};
struct SNProbeCredential { uint8_t token[32]; };
#ifdef DEBUG
static int force_rng_failure;
void sn_probe_test_rng_failure(int fail) { force_rng_failure = fail; }
#endif
static void wipe(void *memory, size_t size) { (void)memset_s(memory, size, 0, size); }
SNProbeCredential *sn_probe_credential_create(const uint8_t *user_id, size_t user_id_length,
    const uint8_t *serial, size_t serial_length) {
    if (!user_id || !user_id_length || user_id_length > 32 || !serial || serial_length != 16 ||
        memcmp(serial, "P512", 4)) return NULL;
    for (size_t i = 0; i < user_id_length; ++i)
        if (user_id[i] < '0' || user_id[i] > '9') return NULL;
    for (size_t i = 0; i < serial_length; ++i)
        if (!((serial[i] >= '0' && serial[i] <= '9') || (serial[i] >= 'A' && serial[i] <= 'Z'))) return NULL;
    SNProbeCredential *credential = calloc(1, sizeof(*credential));
    if (!credential) return NULL;
    uint8_t digest[CC_MD5_DIGEST_LENGTH] = {0};
    CC_MD5_CTX md5;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5_Init(&md5);
    CC_MD5_Update(&md5, user_id, (CC_LONG)user_id_length);
    CC_MD5_Update(&md5, serial, (CC_LONG)serial_length);
    CC_MD5_Final(digest, &md5);
#pragma clang diagnostic pop
    static const char hex[] = "0123456789ABCDEF";
    for (size_t i = 0; i < sizeof(digest); ++i) {
        credential->token[2*i] = hex[digest[i] >> 4];
        credential->token[2*i+1] = hex[digest[i] & 15];
    }
    wipe(digest, sizeof(digest)); wipe(&md5, sizeof(md5));
    return credential;
}
void sn_probe_credential_destroy(SNProbeCredential *credential) {
    if (credential) { wipe(credential, sizeof(*credential)); free(credential); }
}
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
// Explicit PKCS#7 validation also rejects a zero padding count. Do not rely
// on the platform's legacy padding tolerance to establish packet validity.
static int decrypt_cbc_strict(SNProbeCrypto *c, const uint8_t *ciphertext, size_t length,
    uint8_t *plaintext, size_t capacity, size_t *written) {
    *written = 0;
    size_t count = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES, 0,
        c->key, sizeof(c->key), c->iv, ciphertext, length, plaintext, capacity, &count);
    if (status != kCCSuccess || !count || count != length) return 0;
    uint8_t padding = plaintext[count - 1], mismatch = 0;
    if (!padding || padding > 16 || padding > count) return 0;
    for (size_t i = count - padding; i < count; ++i) mismatch |= plaintext[i] ^ padding;
    if (mismatch) return 0;
    *written = count - padding;
    return 1;
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
    int valid = decrypt_cbc_strict(c, ciphertext, length, plaintext, sizeof(plaintext), &written) && written == 18;
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
    valid = decrypt_cbc_strict(c, ciphertext, length, plaintext, sizeof(plaintext), &written) &&
        written == 18 && table_offset(plaintext[16], plaintext[17], &offset);
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
int sn_probe_credential_request(SNProbeCrypto *c, SNProbeCredential *credential, uint8_t ciphertext[64]) {
    if (!ciphertext) return 0;
    wipe(ciphertext, 64);
    if (!c || c->ready != 2 || c->credential_check_sent || !credential) return 0;
    uint8_t packet[52] = {0xaa, 3, 32, 0, 0, 0x0d, 2, 0, 0, 0, 0, 0,
        0x21, 0x35, 1, 1, 0x35, 0x86};
    memcpy(packet + 18, credential->token, 32);
    packet[4] = crc8(packet, 4);
    uint16_t checksum = crc16(packet, 50);
    packet[50] = checksum & 255; packet[51] = checksum >> 8;
    size_t written = 0;
    CCCryptorStatus status = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        c->key, sizeof(c->key), c->iv, packet, sizeof(packet), ciphertext, 64, &written);
    wipe(packet, sizeof(packet));
    if (status != kCCSuccess || written != 64) { wipe(ciphertext, 64); return 0; }
    c->credential_check_sent = 1;
    return 1;
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
static int decrypt_packet(SNProbeCrypto *c, const uint8_t *ciphertext, size_t length,
    uint8_t packet[1024], size_t *written, uint8_t *failure, int allow_v19) {
    if (failure) *failure = 1;
    if (!c || c->ready != 2 || !ciphertext || !length || length % 16 || length > 1008) return 0;
    if (!decrypt_cbc_strict(c, ciphertext, length, packet, 1024, written)) return 0;
    if (failure) *failure = 2;
    if (*written < 20 || packet[0] != 0xaa) return 0;
    if (failure) *failure = 3;
    if (crc8(packet, 4) != packet[4]) return 0;
    if (packet[1] == 0x13 && allow_v19) {
        // Installed official app: getV3Data (0x99470) counts payload + 20;
        // process (0x9bcdc) XORs payload only for enc_type=1, using seq[0].
        // getV3Data separates encoding bits 5...6 and check bits 2...4.
        size_t declared = (size_t)packet[2] + ((size_t)packet[3] << 8);
        if (failure) *failure = 8;
        if (declared > 984 || *written != 20 + declared) return 0;
        if (failure) *failure = 9;
        unsigned encoding = (packet[5] >> 5) & 3;
        unsigned check = (packet[5] >> 2) & 7;
        uint16_t trailer = (uint16_t)packet[*written - 2] | ((uint16_t)packet[*written - 1] << 8);
        if (encoding > 1 || check > 3) return 0;
        // App accepts no-check modes 0/1; mode 2 accepts CRC8 or CRC16;
        // mode 3 requires CRC16. Never infer integrity from a BB sentinel.
        if (check == 3 && crc16(packet, *written - 2) != trailer) return 0;
        if (check == 2 && crc8(packet, *written - 2) != trailer &&
            crc16(packet, *written - 2) != trailer) return 0;
        if (encoding == 1)
            for (size_t i = 18; i < 18 + declared; ++i) packet[i] ^= packet[6];
        if (failure) *failure = 0;
        return 1;
    }
    if (failure) *failure = packet[1] == 0x13 ? 5 : 4;
    if (packet[1] != 3) return 0;
    if (failure) *failure = 6;
    if (*written != 20 + (size_t)packet[2] + ((size_t)packet[3] << 8)) return 0;
    if (failure) *failure = 7;
    if (crc16(packet, *written - 2) != ((uint16_t)packet[*written - 2] | ((uint16_t)packet[*written - 1] << 8))) return 0;
    if (failure) *failure = 0;
    return 1;
}
static void packet_metadata(const uint8_t *packet, size_t written, SNSessionPacketMetadata *m) {
    m->version = packet[1];
    m->source = packet[12]; m->destination = packet[13];
    m->device_source = packet[14]; m->device_destination = packet[15];
    m->command_set = packet[16]; m->command = packet[17];
    m->sequence = (uint32_t)packet[6] | ((uint32_t)packet[7] << 8) |
        ((uint32_t)packet[8] << 16) | ((uint32_t)packet[9] << 24);
    m->payload_length = written - 20;
}
static int status_route(const SNSessionPacketMetadata *m) {
    return m->source == 0x35 && m->destination == 0x21 &&
        m->device_source == 1 && m->device_destination == 1 &&
        m->command_set == 0x35 && m->command == 0x89 && m->sequence == 0;
}
int sn_probe_inspect_packet(SNProbeCrypto *c, const uint8_t *ciphertext, size_t length,
    SNSessionPacketMetadata *metadata) {
    if (!metadata) return -1;
    memset(metadata, 0, sizeof(*metadata));
    uint8_t packet[1024] = {0}; size_t written = 0;
    int valid = decrypt_packet(c, ciphertext, length, packet, &written, NULL, 0);
    if (valid) packet_metadata(packet, written, metadata);
    wipe(packet, sizeof(packet));
    return valid ? 1 : -1;
}
int sn_probe_display_request(SNProbeCrypto *c, uint8_t ciphertext[32]) {
    if (!ciphertext) return 0;
    wipe(ciphertext, 32);
    if (!c || c->ready != 2) return 0;
    // Request a full display report, without setting any cfg_* or auth field.
    uint8_t packet[23] = {0xaa, 3, 3, 0, 0, 0x0d, 1, 0, 0, 0, 0, 0,
        0x21, 2, 1, 1, 0xfe, 0x11, 0xb8, 4, 1, 0, 0};
    packet[4] = crc8(packet, 4);
    uint16_t checksum = crc16(packet, 21);
    packet[21] = checksum & 255; packet[22] = checksum >> 8;
    size_t written = 0;
    CCCryptorStatus status = CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
        c->key, sizeof(c->key), c->iv, packet, sizeof(packet), ciphertext, 32, &written);
    wipe(packet, sizeof(packet));
    if (status != kCCSuccess || written != 32) { wipe(ciphertext, 32); return 0; }
    return 1;
}
int sn_probe_access_reply(SNProbeCrypto *c, const uint8_t *ciphertext, size_t length,
    SNAccessReply *reply, uint8_t *telemetry, size_t capacity, size_t *telemetry_length) {
    if (reply) memset(reply, 0, sizeof(*reply));
    if (telemetry_length) *telemetry_length = 0;
    if (telemetry && capacity <= 984) wipe(telemetry, capacity);
    if (!reply || !telemetry_length || !telemetry || capacity > 984) return -1;
    uint8_t packet[1024] = {0}; size_t written = 0;
    int result = -1; uint8_t failure = 0;
    // The response control byte need not equal the request's 0x0d. It is not a
    // framing marker. V19 access frames are allowed only after credential success;
    // status and credential replies themselves remain strictly V3.
    if (decrypt_packet(c, ciphertext, length, packet, &written, &failure,
        c && c->credential_authenticated)) {
        packet_metadata(packet, written, &reply->metadata);
        const SNSessionPacketMetadata *m = &reply->metadata;
        result = 0;
        if (packet[1] == 3 && status_route(m)) {
            result = 1;
            if (m->payload_length == 2) {
                if (packet[18] <= 1) reply->auth_action = packet[18] == 0 ? 1 : 2;
                if (packet[19] <= 1) reply->auth_mode = packet[19] == 0 ? 1 : 2;
            }
        } else if (packet[1] == 3 && c->credential_check_sent && m->source == 0x35 && m->destination == 0x21 &&
            m->device_source == 1 && m->device_destination == 1 &&
            m->command_set == 0x35 && m->command == 0x86 && m->sequence == 2) {
            // App's normal helper rejects empty payloads and interprets the first
            // result byte: zero is success, every nonzero value is rejection.
            if (!m->payload_length) result = -1;
            else {
                reply->credential_accepted = packet[18] == 0;
                c->credential_authenticated = reply->credential_accepted;
                result = 4;
            }
        } else if (m->source == 2 && m->destination == 0x21 && m->command_set == 0xfe) {
            if (m->command == 0x11 && m->sequence == 1 &&
                m->device_source == 1 && m->device_destination == 1) result = 2;
            else if (m->command == 0x15 &&
                ((m->device_source == 0 && m->device_destination == 0) ||
                 (m->device_source == 1 && m->device_destination == 1) ||
                 // Actual 0.5.5 bank uploads, after accepted credential check.
                 // Keep this additional route out of V3/account-free probes.
                 (c->credential_authenticated && packet[1] == 0x13 &&
                  m->device_source == 1 && m->device_destination == 0))) {
                if (m->payload_length <= capacity) {
                    memcpy(telemetry, packet + 18, m->payload_length);
                    *telemetry_length = m->payload_length; result = 3;
                } else result = -1;
            }
        }
    }
    uint16_t observed = 0, declared = 0; uint8_t markers = 0;
    if (result < 0 && (failure == 8 || failure == 9)) {
        observed = (uint16_t)written;
        declared = (uint16_t)packet[2] | ((uint16_t)packet[3] << 8);
        if (packet[written - 2] == 0xbb && packet[written - 1] == 0xbb) markers |= 1;
        if ((packet[written - 2] ^ packet[6]) == 0xbb &&
            (packet[written - 1] ^ packet[6]) == 0xbb) markers |= 2;
    }
    wipe(packet, sizeof(packet));
    if (result < 0) {
        memset(reply, 0, sizeof(*reply)); reply->validation_failure = failure;
        reply->observed_inner_length = observed; reply->declared_payload_length = declared;
        reply->v19_marker_flags = markers;
        wipe(telemetry, capacity); *telemetry_length = 0;
    }
    return result;
}
int sn_probe_status_reply(SNProbeCrypto *c, const uint8_t *ciphertext, size_t length) {
    SNSessionPacketMetadata metadata;
    if (sn_probe_inspect_packet(c, ciphertext, length, &metadata) != 1) return -1;
    return status_route(&metadata) ? 1 : 0;
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
