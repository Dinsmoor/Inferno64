/*
 * lib9 Rune-string routines.  Only runestrlen and runestrchr are built into
 * lib9 on this platform (the other runestr* are declared in lib9.h but have no
 * implementation here), so we test those two.
 */
#include "lib9.h"
#include "cunit.h"

static Rune hello[] = { 'h','e','l','l','o', 0 };

static void
test_runestrlen(void)
{
	CKEQ(runestrlen(hello), 5);
	CKEQ(runestrlen((Rune[]){0}), 0);
	CKEQ(runestrlen((Rune[]){'x','y',0}), 2);
}

static void
test_runestrchr(void)
{
	CK(runestrchr(hello, 'h') == &hello[0]);
	CK(runestrchr(hello, 'l') == &hello[2]);   /* first occurrence */
	CK(runestrchr(hello, 'o') == &hello[4]);
	CK(runestrchr(hello, 'z') == nil);
	CK(runestrchr(hello, 0) == &hello[5]);     /* matches terminator */
}

CUNIT_MAIN("lib9/runestr", test_runestrlen, test_runestrchr)
