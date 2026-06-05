/* lib9 number/base conversions: charstod, enc16/dec16, enc32/dec32. */
#include "lib9.h"
#include "cunit.h"

/* charstod pulls characters through a callback; feed it from a string. */
static char *cdp;
static int
getc_str(void *v)
{
	USED(v);
	if(*cdp == 0)
		return -1;
	return *cdp++;
}

static double
parse(char *s)
{
	cdp = s;
	return charstod(getc_str, nil);
}

static int
near(double g, double w)
{
	double d = g - w;
	return (d < 0 ? -d : d) <= 1e-9;
}

static void
test_charstod(void)
{
	CK(near(parse("3.14"), 3.14));
	CK(near(parse("-0.5"), -0.5));
	CK(near(parse("100"), 100.0));
	CK(near(parse("1.5e3"), 1500.0));
	CK(near(parse("0"), 0.0));
}

static void
test_hex16(void)
{
	char e[32];
	uchar d[16];
	int n;
	n = enc16(e, sizeof e, (uchar*)"\xde\xad\xbe\xef", 4);
	CK(n > 0); CKSTR(e, "DEADBEEF");
	n = dec16(d, sizeof d, "deadBEEF", 8);   /* case-insensitive decode */
	CKEQ(n, 4);
	CKEQX(d[0], 0xde); CKEQX(d[1], 0xad); CKEQX(d[2], 0xbe); CKEQX(d[3], 0xef);
}

static void
test_b32(void)
{
	/* enc32/dec32 round-trip (base32) */
	uchar in[10], back[10];
	char enc[32];
	int i, n;
	for(i = 0; i < (int)sizeof in; i++)
		in[i] = (uchar)(i * 11 + 3);
	n = enc32(enc, sizeof enc, in, sizeof in);
	CK(n > 0);
	n = dec32(back, sizeof back, enc, n);
	CKEQ(n, sizeof in);
	CKMEM(back, in, sizeof in);
}

CUNIT_MAIN("lib9/numconv", test_charstod, test_hex16, test_b32)
