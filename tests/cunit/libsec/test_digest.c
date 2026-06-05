/*
 * libsec message digests against published test vectors.  Digests are
 * byte-exact, so any width/blocking/length-counter mistake shows up as a
 * wrong hash.  Also checks streaming (two chunks) equals one-shot.
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
		b[2*i]   = x[d[i] >> 4];
		b[2*i+1] = x[d[i] & 15];
	}
	b[2*i] = 0;
	return b;
}

static void
test_md5(void)
{
	uchar d[MD5dlen];
	md5((uchar*)"", 0, d, nil);
	CKSTR(hex(d, MD5dlen), "d41d8cd98f00b204e9800998ecf8427e");
	md5((uchar*)"abc", 3, d, nil);
	CKSTR(hex(d, MD5dlen), "900150983cd24fb0d6963f7d28e17f72");
}

static void
test_sha1(void)
{
	uchar d[SHA1dlen];
	sha1((uchar*)"abc", 3, d, nil);
	CKSTR(hex(d, SHA1dlen), "a9993e364706816aba3e25717850c26c9cd0d89d");
	sha1((uchar*)"", 0, d, nil);
	CKSTR(hex(d, SHA1dlen), "da39a3ee5e6b4b0d3255bfef95601890afd80709");
}

static void
test_sha256(void)
{
	uchar d[SHA256dlen];
	sha256((uchar*)"abc", 3, d, nil);
	CKSTR(hex(d, SHA256dlen),
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}

static void
test_streaming(void)
{
	/* feeding "abc"+"def" incrementally must equal hashing "abcdef" once */
	uchar d1[SHA1dlen], d2[SHA1dlen];
	DigestState *s;
	sha1((uchar*)"abcdef", 6, d1, nil);
	s = sha1((uchar*)"abc", 3, nil, nil);   /* nil digest = keep going */
	sha1((uchar*)"def", 3, d2, s);          /* non-nil digest = finalize */
	CKMEM(d2, d1, SHA1dlen);
}

CUNIT_MAIN("libsec/digest", test_md5, test_sha1, test_sha256, test_streaming)
