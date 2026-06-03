/*
 * lib9 formatted print -- the prime LP64 hazard.  On LP64 `long`/`ulong` and
 * pointers are 64-bit while `int` stays 32-bit, so a verb that reads the wrong
 * width silently truncates.  These check the full-width verbs against
 * independently-known results.
 */
#include "lib9.h"
#include "cunit.h"

static char buf[256];

static void
test_int(void)
{
	snprint(buf, sizeof buf, "%d", -42);        CKSTR(buf, "-42");
	snprint(buf, sizeof buf, "%d", 2147483647); CKSTR(buf, "2147483647");
	snprint(buf, sizeof buf, "%ud", 4294967295U); CKSTR(buf, "4294967295");
	snprint(buf, sizeof buf, "%ux", 0xdeadbeefU); CKSTR(buf, "deadbeef");
	snprint(buf, sizeof buf, "%x", 0x4d2);        CKSTR(buf, "4d2");  /* signed verb, positive */
	snprint(buf, sizeof buf, "%05d", 42);        CKSTR(buf, "00042");
	snprint(buf, sizeof buf, "%-5d|", 42);       CKSTR(buf, "42   |");
}

static void
test_long(void)
{
	/*
	 * `long`/`ulong` width is ABI-dependent: 64-bit on LP64, 32-bit on
	 * ILP32.  Exercise %lud/%lux/%ld at whatever width this build uses, so
	 * the test is correct on both.  (Guaranteed-64-bit formatting is covered
	 * by test_vlong below.)
	 */
	if(sizeof(ulong) >= 8){
		ulong u = (ulong)0x1122334455667788UL;
		snprint(buf, sizeof buf, "%lud", u); CKSTR(buf, "1234605616436508552");
		snprint(buf, sizeof buf, "%lux", u); CKSTR(buf, "1122334455667788");
		snprint(buf, sizeof buf, "%ld", (long)-5000000000LL); CKSTR(buf, "-5000000000");
	}else{
		ulong u = (ulong)0x12345678UL;
		snprint(buf, sizeof buf, "%lud", u); CKSTR(buf, "305419896");
		snprint(buf, sizeof buf, "%lux", u); CKSTR(buf, "12345678");
		snprint(buf, sizeof buf, "%ld", (long)-2000000000L); CKSTR(buf, "-2000000000");
	}
}

static void
test_vlong(void)
{
	snprint(buf, sizeof buf, "%lld", (vlong)-9000000000LL);
	CKSTR(buf, "-9000000000");
	snprint(buf, sizeof buf, "%llud", (uvlong)18000000000ULL);
	CKSTR(buf, "18000000000");
	snprint(buf, sizeof buf, "%llux", (uvlong)0xfedcba9876543210ULL);
	CKSTR(buf, "fedcba9876543210");
}

static void
test_pointer(void)
{
	/* %p must render all 64 bits; parse it back rather than assume a prefix */
	void *p = (void*)0xdeadbeef12345678UL;
	char *end;
	uvlong v;
	snprint(buf, sizeof buf, "%p", p);
	v = strtoull(buf, &end, 16);
	CKEQX(v, (uvlong)(uintptr)p);

	/* a small pointer too (no leading-zero loss / sign issues) */
	p = (void*)0x400UL;
	snprint(buf, sizeof buf, "%p", p);
	v = strtoull(buf, &end, 16);
	CKEQX(v, (uvlong)0x400);
}

static void
test_str_rune(void)
{
	snprint(buf, sizeof buf, "%s", "hello");        CKSTR(buf, "hello");
	snprint(buf, sizeof buf, "[%5s]", "hi");        CKSTR(buf, "[   hi]");
	snprint(buf, sizeof buf, "[%-5s]", "hi");       CKSTR(buf, "[hi   ]");
	snprint(buf, sizeof buf, "%c%c%c", 'a','b','c'); CKSTR(buf, "abc");
	snprint(buf, sizeof buf, "%C", (Rune)0x40);     CKSTR(buf, "@");
}

static void
test_retval(void)
{
	/* snprint returns count of bytes placed (excluding the NUL) */
	int n = snprint(buf, sizeof buf, "%d", 12345);
	CKEQ(n, 5);
	/* truncation: returns bytes actually written into the n-1 budget */
	n = snprint(buf, 4, "%s", "abcdef");
	CKEQ(strlen(buf), 3);
}

CUNIT_MAIN("lib9/fmt",
	test_int, test_long, test_vlong, test_pointer, test_str_rune, test_retval)
