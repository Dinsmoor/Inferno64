/* libmp arithmetic: add/sub/mul/div/mod/cmp, including past-64-bit operands. */
#include "lib9.h"
#include "mp.h"
#include "cunit.h"

static char buf[256];

static char*
str(mpint *m)
{
	mptoa(m, 10, buf, sizeof buf);
	return buf;
}

static void
test_addsub(void)
{
	mpint *a = strtomp("100000000000000000000", nil, 10, nil);
	mpint *b = strtomp("1", nil, 10, nil);
	mpint *r = mpnew(0);
	mpadd(a, b, r); CKSTR(str(r), "100000000000000000001");
	mpsub(a, b, r); CKSTR(str(r),  "99999999999999999999");
	mpsub(b, a, r); CKSTR(str(r), "-99999999999999999999");
	mpfree(a); mpfree(b); mpfree(r);
}

static void
test_mul(void)
{
	/* (2^64) * (2^64) = 2^128, well past any single word */
	mpint *a = strtomp("18446744073709551616", nil, 10, nil);  /* 2^64 */
	mpint *r = mpnew(0);
	mpmul(a, a, r);
	CKSTR(str(r), "340282366920938463463374607431768211456");   /* 2^128 */
	mpfree(a); mpfree(r);
}

static void
test_divmod(void)
{
	mpint *a = strtomp("1000000000000000000000", nil, 10, nil);
	mpint *b = strtomp("7", nil, 10, nil);
	mpint *q = mpnew(0), *rem = mpnew(0);
	mpdiv(a, b, q, rem);
	CKSTR(str(q), "142857142857142857142");
	CKSTR(str(rem), "6");      /* 142857142857142857142*7 + 6 == a */
	mpfree(a); mpfree(b); mpfree(q); mpfree(rem);
}

static void
test_cmp(void)
{
	mpint *a = strtomp("123456789012345678901", nil, 10, nil);
	mpint *b = strtomp("123456789012345678902", nil, 10, nil);
	CK(mpcmp(a, b) < 0);
	CK(mpcmp(b, a) > 0);
	CKEQ(mpcmp(a, a), 0);
	mpfree(a); mpfree(b);
}

static void
test_signif(void)
{
	mpint *m = strtomp("255", nil, 10, nil);   /* 0xff -> 8 bits */
	CKEQ(mpsignif(m), 8);
	strtomp("256", nil, 10, m);                /* 0x100 -> 9 bits */
	CKEQ(mpsignif(m), 9);
	mpfree(m);
}

CUNIT_MAIN("libmp/arith",
	test_addsub, test_mul, test_divmod, test_cmp, test_signif)
