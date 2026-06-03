/* lib9 field splitting: getfields, tokenize. */
#include "lib9.h"
#include "cunit.h"

static void
test_getfields(void)
{
	char buf[64];
	char *a[8];
	int n;

	strecpy(buf, buf+sizeof buf, "a:b:c");
	n = getfields(buf, a, nelem(a), 0, ":");
	CKEQ(n, 3); CKSTR(a[0], "a"); CKSTR(a[1], "b"); CKSTR(a[2], "c");

	/* multiflag=1 collapses runs of delimiters into one split */
	strecpy(buf, buf+sizeof buf, "a:::b");
	n = getfields(buf, a, nelem(a), 1, ":");
	CKEQ(n, 2); CKSTR(a[0], "a"); CKSTR(a[1], "b");

	/* multiflag=0 keeps empty fields */
	strecpy(buf, buf+sizeof buf, "a::b");
	n = getfields(buf, a, nelem(a), 0, ":");
	CKEQ(n, 3); CKSTR(a[1], "");

	/* respects the max-fields cap */
	strecpy(buf, buf+sizeof buf, "1 2 3 4 5");
	n = getfields(buf, a, 2, 1, " ");
	CKEQ(n, 2); CKSTR(a[0], "1");
}

static void
test_tokenize(void)
{
	char buf[64];
	char *a[8];
	int n;

	strecpy(buf, buf+sizeof buf, "  one\ttwo   three ");
	n = tokenize(buf, a, nelem(a));
	CKEQ(n, 3); CKSTR(a[0], "one"); CKSTR(a[1], "two"); CKSTR(a[2], "three");

	strecpy(buf, buf+sizeof buf, "   ");
	CKEQ(tokenize(buf, a, nelem(a)), 0);
}

CUNIT_MAIN("lib9/getfields", test_getfields, test_tokenize)
