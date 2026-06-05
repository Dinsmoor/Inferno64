/* lib9 string helpers: cleanname, cistr*, strecpy. */
#include "lib9.h"
#include "cunit.h"

static char*
clean(char *s)		/* cleanname rewrites in place; copy into a writable buf */
{
	static char b[256];
	strecpy(b, b+sizeof b, s);
	return cleanname(b);
}

static void
test_cleanname(void)
{
	CKSTR(clean("/usr/./lib/../inferno"), "/usr/inferno");
	CKSTR(clean("a/b/../../c"), "c");
	CKSTR(clean("a//b/"), "a/b");
	CKSTR(clean("a/./b"), "a/b");
	CKSTR(clean(""), ".");
	CKSTR(clean("."), ".");
	CKSTR(clean("/"), "/");
	CKSTR(clean("/.."), "/");          /* can't ascend above root */
	CKSTR(clean(".."), "..");          /* relative, preserved */
}

static void
test_cistr(void)
{
	CKEQ(cistrcmp("Hello", "hello"), 0);
	CK(cistrcmp("abc", "abd") < 0);
	CK(cistrcmp("abd", "abc") > 0);
	CKEQ(cistrncmp("HELLOxxx", "hello", 5), 0);
	CK(cistrncmp("abc", "abd", 3) != 0);
	CKSTR(cistrstr("a Quick BROWN fox", "brown"), "BROWN fox");
	CK(cistrstr("abc", "xyz") == nil);
}

static void
test_strecpy(void)
{
	char b[8];
	char *e = strecpy(b, b+sizeof b, "hello");
	CKSTR(b, "hello");
	CKEQ(e - b, 5);            /* returns pointer to the NUL */
	/* truncation: never writes past the end, always NUL-terminates */
	strecpy(b, b+sizeof b, "0123456789");
	CKEQ(strlen(b), 7);
	CKEQ(b[7], 0);
}

CUNIT_MAIN("lib9/str", test_cleanname, test_cistr, test_strecpy)
