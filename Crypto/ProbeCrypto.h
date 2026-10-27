#ifndef SOMNOIRE_PROBE_CRYPTO_H
#define SOMNOIRE_PROBE_CRYPTO_H
#include <stddef.h>
#include <stdint.h>
typedef struct SNProbeCrypto SNProbeCrypto;
// Opaque, volatile token. No raw token getter or provisioning API exists.
typedef struct SNProbeCredential SNProbeCredential;
SNProbeCredential *sn_probe_credential_create(const uint8_t *user_id, size_t user_id_length,
    const uint8_t *serial, size_t serial_length);
void sn_probe_credential_destroy(SNProbeCredential *credential);
// Fixed 35/86 existing-credential check, sequence 2, 32 ASCII uppercase hex bytes.
int sn_probe_credential_request(SNProbeCrypto *context, SNProbeCredential *credential,
    uint8_t ciphertext[64]);
SNProbeCrypto *sn_probe_create(uint8_t public_key[40]);
int sn_probe_accept_peer(SNProbeCrypto *context, const uint8_t peer[40]);
int sn_probe_validate_info(SNProbeCrypto *context, const uint8_t *ciphertext, size_t length);
int sn_probe_derive_session(SNProbeCrypto *context, const uint8_t *ciphertext, size_t length,
    const uint8_t *table, size_t table_length);
int sn_probe_status_request(SNProbeCrypto *context, uint8_t ciphertext[32]);
// -1: malformed, 0: valid unrelated packet, 1: matching status reply.
int sn_probe_status_reply(SNProbeCrypto *context, const uint8_t *ciphertext, size_t length);
// Validated header metadata only; never returns packet payloads or session material.
typedef struct {
    uint8_t source, destination, device_source, device_destination, command_set, command;
    uint8_t version;
    uint32_t sequence;
    size_t payload_length;
} SNSessionPacketMetadata;
// -1: malformed; 1: valid V3 packet. Output is zeroed on failure.
int sn_probe_inspect_packet(SNProbeCrypto *context, const uint8_t *ciphertext, size_t length,
    SNSessionPacketMetadata *metadata);
// Fixed one-shot display report request: FE/11, only protobuf field 71=true.
// This display API accepts no caller-supplied command, settings or authentication payload.
int sn_probe_display_request(SNProbeCrypto *context, uint8_t ciphertext[32]);
typedef struct {
    SNSessionPacketMetadata metadata;
    // 0 unknown; action 1=set credential, 2=check existing credential.
    // Mode 1=normal, 2=OMOS. These describe the app's next action, not ownership.
    uint8_t auth_action, auth_mode;
    uint8_t credential_accepted;
    // Sanitized parser category only; no raw packet bytes leave C on failure.
    // 0=unspecified, 1=decrypt/padding, 2=prefix/short, 3=header CRC,
    // 4=unsupported version, 5=V19 before authentication, 6=V3 length,
    // 7=V3 CRC16, 8=V19 length, 9=V19 checksum/encoding.
    uint8_t validation_failure;
    // Present only for authenticated, header-CRC-valid V19 layout failures.
    // Marker flags: bit 0=raw BB BB, bit 1=BB BB after sequence-byte XOR.
    uint16_t observed_inner_length, declared_payload_length;
    uint8_t v19_marker_flags;
} SNAccessReply;
// -1 malformed; 0 unrelated; 1 status; 2 report reply; 3 display; 4 credential reply.
// Credential replies are recognized only after this context issues a check.
// Only allowlisted display bodies can leave C. Every other output body is empty.
int sn_probe_access_reply(SNProbeCrypto *context, const uint8_t *ciphertext, size_t length,
    SNAccessReply *reply, uint8_t *telemetry, size_t capacity, size_t *telemetry_length);
void sn_probe_destroy(SNProbeCrypto *context);
#ifdef DEBUG
SNProbeCrypto *sn_probe_test_create(const uint8_t private_key[21], uint8_t public_key[40]);
int sn_probe_test_shared(const uint8_t private_key[21], const uint8_t peer[40], uint8_t secret[20]);
int sn_probe_test_session_key(SNProbeCrypto *context, uint8_t key[16]);
int sn_probe_test_offset(uint8_t first, uint8_t second, size_t *offset);
void sn_probe_test_rng_failure(int fail);
#endif
#endif
