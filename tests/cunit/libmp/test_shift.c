/*
 * libmp bit-shifts and modular exponentiation.  Shifts that cross mpdigit
 * boundaries (e.g. <<64, <<96) are where a digit-width slip would corrupt the
 * result, so check against exact decimal values past 2^64.
 */
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
test_left(void)
{
	mpint *one = strtomp("1", nil, 10, nil);
	mpint *r = mpnew(0);
	mpleft(one, 64, r);  CKSTR(str(r), "18446744073709551616");        /* 2^64 */
	mpleft(one, 96, r);  CKSTR(str(r), "79228162514264337593543950336"); /* 2^96 */
	mpleft(one, 1, r);   CKSTR(str(r), "2");
	mpfree(one); mpfree(r);
}

static void
test_right(void)
{
	mpint *b = strtomp("79228162514264337593543950336", nil, 10, nil); /* 2^96 */
	mpint *r = mpnew(0);
	mpright(b, 64, r);   CKSTR(str(r), "4294967296");                  /* 2^32 */
	mpright(b, 96, r);   CKSTR(str(r), "1");
	mpright(b, 200, r);  CKSTR(str(r), "0");                           /* shift past top */
	mpfree(b); mpfree(r);
}

static void
test_exp(void)
{
	mpint *b = strtomp("2", nil, 10, nil);
	mpint *e = strtomp("100", nil, 10, nil);
	mpint *r = mpnew(0);
	mpexp(b, e, nil, r);     /* 2^100, no modulus */
	CKSTR(str(r), "1267650600228229401496703205376");

	strtomp("7", nil, 10, b);
	strtomp("13", nil, 10, e);
	mpexp(b, e, nil, r);     /* 7^13 = 96889010407 */
	CKSTR(str(r), "96889010407");
	mpfree(b); mpfree(e); mpfree(r);
}

static void
test_expmod(void)
{
	/* 4^13 mod 497 = 445 (a classic modpow example) */
	mpint *b = strtomp("4", nil, 10, nil);
	mpint *e = strtomp("13", nil, 10, nil);
	mpint *m = strtomp("497", nil, 10, nil);
	mpint *r = mpnew(0);
	mpexp(b, e, m, r);
	CKSTR(str(r), "445");
	mpfree(b); mpfree(e); mpfree(m); mpfree(r);
}

CUNIT_MAIN("libmp/shift", test_left, test_right, test_exp, test_expmod)
