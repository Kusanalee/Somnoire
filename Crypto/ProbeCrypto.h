#ifndef SOMNOIRE_PROBE_CRYPTO_H
#define SOMNOIRE_PROBE_CRYPTO_H
#include <stddef.h>
#include <stdint.h>
typedef struct SNProbeCrypto SNProbeCrypto;
SNProbeCrypto *sn_probe_create(uint8_t public_key[40]);
int sn_probe_accept_peer(SNProbeCrypto *context, const uint8_t peer[40]);
int sn_probe_validate_info(SNProbeCrypto *context, const uint8_t *ciphertext, size_t length);
int sn_probe_derive_session(SNProbeCrypto *context, const uint8_t *ciphertext, size_t length,
    const uint8_t *table, size_t table_length);
int sn_probe_status_request(SNProbeCrypto *context, uint8_t ciphertext[32]);
// -1: malformed, 0: valid unrelated packet, 1: matching status reply.
int sn_probe_status_reply(SNProbeCrypto *context, const uint8_t *ciphertext, size_t length);
void sn_probe_destroy(SNProbeCrypto *context);
#ifdef DEBUG
SNProbeCrypto *sn_probe_test_create(const uint8_t private_key[21], uint8_t public_key[40]);
int sn_probe_test_shared(const uint8_t private_key[21], const uint8_t peer[40], uint8_t secret[20]);
int sn_probe_test_session_key(SNProbeCrypto *context, uint8_t key[16]);
int sn_probe_test_offset(uint8_t first, uint8_t second, size_t *offset);
void sn_probe_test_rng_failure(int fail);
#endif
#endif
