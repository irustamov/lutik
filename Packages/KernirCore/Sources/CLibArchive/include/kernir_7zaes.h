/* Kernir-local helper: 7-Zip AES-256 (7zAES) key derivation and AES-256-CBC.
 * Plain C types only; CommonCrypto is used inside kernir_7zaes.c. */
#ifndef KERNIR_7ZAES_H
#define KERNIR_7ZAES_H

#include <stddef.h>
#include <stdint.h>

#define KERNIR_7ZAES_KEY_SIZE   32
#define KERNIR_7ZAES_BLOCK_SIZE 16

struct kernir_7zaes_params {
	unsigned cycles_power;      /* props[0] & 0x3F */
	uint8_t  salt[16]; size_t salt_size;
	uint8_t  iv[16];            /* zero-padded to 16 */
};

/* 0 ok; -1 malformed (size mismatch, salt or IV > 16); -2 unsupported cost (cycles_power > 24 and != 0x3F). */
int  kernir_7zaes_parse_props(const uint8_t *props, size_t size, struct kernir_7zaes_params *out);
/* Encodes params as 7-Zip writes them (bits 7/6 of byte 0, nibbles in byte 1); always writes a 16-byte IV.
 * Returns the length written (<= 34). */
size_t kernir_7zaes_encode_props(const struct kernir_7zaes_params *p, uint8_t out[34]);
/* 0 ok; -1 invalid UTF-8 or no memory. Passphrase is UTF-8 and is encoded as UTF-16LE (surrogate pairs, no BOM, no NUL). */
int  kernir_7zaes_derive_key(const struct kernir_7zaes_params *p, const char *passphrase_utf8, uint8_t key[32]);

struct kernir_7zaes_cbc { void *ref; };  /* CCCryptorRef */
int  kernir_7zaes_cbc_init(struct kernir_7zaes_cbc *c, int encrypt, const uint8_t key[32], const uint8_t iv[16]);
/* len must be a multiple of 16; chains across calls; returns 0 or -1. */
int  kernir_7zaes_cbc_update(struct kernir_7zaes_cbc *c, const uint8_t *in, size_t len, uint8_t *out);
void kernir_7zaes_cbc_release(struct kernir_7zaes_cbc *c);

#endif
