/* Kernir-local helper: 7-Zip AES-256 key derivation and AES-256-CBC (CommonCrypto). */
#include <stdlib.h>
#include <string.h>
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonCryptor.h>

#include "kernir_7zaes.h"

int
kernir_7zaes_parse_props(const uint8_t *props, size_t size, struct kernir_7zaes_params *out)
{
	size_t salt, iv;

	memset(out, 0, sizeof(*out));
	if (size < 1)
		return -1;
	out->cycles_power = props[0] & 0x3F;
	if ((props[0] & 0xC0) == 0) {
		if (size != 1)
			return -1;
	} else {
		if (size < 2)
			return -1;
		salt = ((props[0] >> 7) & 1) + (props[1] >> 4);
		iv = ((props[0] >> 6) & 1) + (props[1] & 0x0F);
		if (salt > 16 || iv > 16 || size != 2 + salt + iv)
			return -1;
		memcpy(out->salt, props + 2, salt);
		out->salt_size = salt;
		memcpy(out->iv, props + 2 + salt, iv);
	}
	if (out->cycles_power > 24 && out->cycles_power != 0x3F)
		return -2;
	return 0;
}

size_t
kernir_7zaes_encode_props(const struct kernir_7zaes_params *p, uint8_t out[34])
{
	size_t n = 2;

	out[0] = (uint8_t)(p->cycles_power & 0x3F);
	out[1] = 0;
	if (p->salt_size > 0) {
		out[0] |= 0x80;
		out[1] |= (uint8_t)((p->salt_size - 1) << 4);
		memcpy(out + n, p->salt, p->salt_size);
		n += p->salt_size;
	}
	out[0] |= 0x40;
	out[1] |= 0x0F;
	memcpy(out + n, p->iv, 16);
	return n + 16;
}

/* UTF-8 -> UTF-16LE bytes. Returns length in bytes, or -1 on invalid input. */
static long
utf8_to_utf16le(const char *s, uint8_t *out)
{
	const unsigned char *u = (const unsigned char *)s;
	long n = 0;

	while (*u) {
		uint32_t cp;
		int extra;
		if (*u < 0x80) { cp = *u; extra = 0; }
		else if (*u >= 0xC2 && *u <= 0xDF) { cp = *u & 0x1F; extra = 1; }
		else if (*u >= 0xE0 && *u <= 0xEF) { cp = *u & 0x0F; extra = 2; }
		else if (*u >= 0xF0 && *u <= 0xF4) { cp = *u & 0x07; extra = 3; }
		else return -1;
		u++;
		for (int i = 0; i < extra; i++, u++) {
			if ((*u & 0xC0) != 0x80)
				return -1;
			cp = (cp << 6) | (*u & 0x3F);
		}
		if ((extra == 2 && cp < 0x800) || (extra == 3 && cp < 0x10000) ||
		    cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
			return -1;
		if (cp >= 0x10000) {
			uint32_t v = cp - 0x10000;
			uint16_t hi = (uint16_t)(0xD800 + (v >> 10));
			uint16_t lo = (uint16_t)(0xDC00 + (v & 0x3FF));
			if (out) {
				out[n] = hi & 0xFF; out[n + 1] = hi >> 8;
				out[n + 2] = lo & 0xFF; out[n + 3] = lo >> 8;
			}
			n += 4;
		} else {
			if (out) { out[n] = cp & 0xFF; out[n + 1] = (uint8_t)(cp >> 8); }
			n += 2;
		}
	}
	return n;
}

int
kernir_7zaes_derive_key(const struct kernir_7zaes_params *p, const char *passphrase_utf8, uint8_t key[32])
{
	long pwlen = utf8_to_utf16le(passphrase_utf8, NULL);
	size_t prefix, i;
	uint8_t *buf;

	if (pwlen < 0)
		return -1;
	prefix = p->salt_size + (size_t)pwlen;
	buf = malloc(prefix + 8);
	if (buf == NULL)
		return -1;
	memcpy(buf, p->salt, p->salt_size);
	utf8_to_utf16le(passphrase_utf8, buf + p->salt_size);

	if (p->cycles_power == 0x3F) {
		memset(key, 0, 32);
		memcpy(key, buf, prefix < 32 ? prefix : 32);
	} else {
		CC_SHA256_CTX ctx;
		uint64_t rounds = (uint64_t)1 << p->cycles_power, r;
		CC_SHA256_Init(&ctx);
		for (r = 0; r < rounds; r++) {
			for (i = 0; i < 8; i++)
				buf[prefix + i] = (uint8_t)(r >> (8 * i));
			CC_SHA256_Update(&ctx, buf, (CC_LONG)(prefix + 8));
		}
		CC_SHA256_Final(key, &ctx);
	}
	memset(buf, 0, prefix + 8);
	free(buf);
	return 0;
}

int
kernir_7zaes_cbc_init(struct kernir_7zaes_cbc *c, int encrypt, const uint8_t key[32], const uint8_t iv[16])
{
	CCCryptorRef ref = NULL;

	c->ref = NULL;
	if (CCCryptorCreate(encrypt ? kCCEncrypt : kCCDecrypt, kCCAlgorithmAES, 0,
	    key, KERNIR_7ZAES_KEY_SIZE, iv, &ref) != kCCSuccess)
		return -1;
	c->ref = ref;
	return 0;
}

int
kernir_7zaes_cbc_update(struct kernir_7zaes_cbc *c, const uint8_t *in, size_t len, uint8_t *out)
{
	size_t moved = 0;

	if (c->ref == NULL || len % KERNIR_7ZAES_BLOCK_SIZE != 0)
		return -1;
	if (len == 0)
		return 0;
	if (CCCryptorUpdate((CCCryptorRef)c->ref, in, len, out, len, &moved) != kCCSuccess || moved != len)
		return -1;
	return 0;
}

void
kernir_7zaes_cbc_release(struct kernir_7zaes_cbc *c)
{
	if (c->ref != NULL) {
		CCCryptorRelease((CCCryptorRef)c->ref);
		c->ref = NULL;
	}
}
