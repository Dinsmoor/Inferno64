/*
 * libsec symmetric crypto: AES-CBC encrypt/decrypt round-trip and HMAC-SHA1
 * against an RFC 2202 vector.  Byte-exact, so a width or block-index slip
 * shows up immediately.
 */
#include "lib9.h"
#include "libsec.h"
#include "cunit.h"

static char*
hex(uchar *d, int n)
{
	static char b[129];
	static char *x = "0123456789abcdef";
	int i;
	for(i = 0; i < n && i < 64; i++){
		b[2*i] = x[d[i] >> 4];
		b[2*i+1] = x[d[i] & 15];
	}
	b[2*i] = 0;
	return b;
}

static void
test_aes_cbc(void)
{
	uchar key[16] = { 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15 };
	uchar iv0[AESbsize] = { 0 };
	uchar iv[AESbsize];
	AESstate s;
	uchar buf[32], orig[32];
	int i;

	for(i = 0; i < (int)sizeof buf; i++)
		buf[i] = orig[i] = (uchar)(i * 3 + 1);

	/* encrypt in place (fresh IV copy: setupAESstate consumes ivec) */
	memmove(iv, iv0, sizeof iv);
	setupAESstate(&s, key, sizeof key, iv);
	aesCBCencrypt(buf, sizeof buf, &s);
	CK(memcmp(buf, orig, sizeof buf) != 0);    /* actually scrambled */

	/* decrypt with the same key/IV -> original */
	memmove(iv, iv0, sizeof iv);
	setupAESstate(&s, key, sizeof key, iv);
	aesCBCdecrypt(buf, sizeof buf, &s);
	CKMEM(buf, orig, sizeof buf);
}

static void
test_hmac_sha1(void)
{
	/* RFC 2202 test case 2 */
	uchar dig[SHA1dlen];
	hmac_sha1((uchar*)"what do ya want for nothing?", 28,
		(uchar*)"Jefe", 4, dig, nil);
	CKSTR(hex(dig, SHA1dlen), "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79");
}

CUNIT_MAIN("libsec/cipher", test_aes_cbc, test_hmac_sha1)
