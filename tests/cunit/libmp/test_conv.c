/*
 * libmp conversions -- the LP64 hotspot.  vlong/uvlong are 64-bit on BOTH
 * ABIs, so vtomp/mptov and uvtomp/mptouv must move all 64 bits regardless of
 * how wide a host `long` or mpdigit is.  Also covers int, ascii and byte-array
 * round-trips.
 */
#include "lib9.h"
#include "mp.h"
#include "cunit.h"

static void
test_int(void)
{
	mpint *m = mpnew(0);
	int v[] = { 0, 1, -1, 42, -42, 2147483647, -2147483647-1 };
	int i;
	for(i = 0; i < nelem(v); i++){
		itomp(v[i], m);
		CKEQ(mptoi(m), v[i]);
	}
	uitomp(4294967295U, m);
	CKEQX(mptoui(m), 4294967295U);
	mpfree(m);
}

static void
test_vlong(void)
{
	mpint *m = mpnew(0);
	vlong v[] = { 0, 1, -1, 0x100000000LL, -0x100000000LL,
		0x7fffffffffffffffLL, -0x7fffffffffffffffLL,
		0x123456789abcdefLL };
	int i;
	for(i = 0; i < nelem(v); i++){
		vtomp(v[i], m);
		CKEQ(mptov(m), v[i]);          /* full 64-bit round-trip */
	}
	mpfree(m);
}

static void
test_uvlong(void)
{
	mpint *m = mpnew(0);
	uvlong v[] = { 0, 1, 0x100000000ULL, 0xdeadbeef12345678ULL,
		0xffffffffffffffffULL };
	int i;
	for(i = 0; i < nelem(v); i++){
		uvtomp(v[i], m);
		CKEQX(mptouv(m), v[i]);
	}
	mpfree(m);
}

static void
test_ascii(void)
{
	char buf[128];
	char *big = "123456789012345678901234567890";
	mpint *m = strtomp(big, nil, 10, nil);
	mptoa(m, 10, buf, sizeof buf);
	CKSTR(buf, big);

	strtomp("deadBEEF", nil, 16, m);
	mptoa(m, 16, buf, sizeof buf);
	CKSTR(buf, "DEADBEEF");                 /* mptoa uses upper-case hex */

	strtomp("-255", nil, 10, m);
	mptoa(m, 16, buf, sizeof buf);
	CKSTR(buf, "-FF");
	mpfree(m);
}

static void
test_bytes(void)
{
	/* big-endian byte array <-> mpint round-trip */
	uchar in[] = { 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef };
	uchar out[16];
	char buf[64];
	int n;
	mpint *m = betomp(in, sizeof in, nil);
	mptoa(m, 16, buf, sizeof buf);
	CKSTR(buf, "123456789ABCDEF");          /* leading zero nibble dropped */
	n = mptobe(m, out, sizeof out, nil);
	CKEQ(n, 8);
	CKMEM(out, in, 8);

	/* little-endian view of the same number is byte-reversed */
	n = mptole(m, out, sizeof out, nil);
	CKEQ(n, 8);
	CKEQX(out[0], 0xef); CKEQX(out[7], 0x01);
	mpfree(m);
}

CUNIT_MAIN("libmp/conv",
	test_int, test_vlong, test_uvlong, test_ascii, test_bytes)
