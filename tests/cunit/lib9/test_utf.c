/* lib9 UTF-8 / Rune routines. */
#include "lib9.h"
#include "cunit.h"

static void
test_chartorune(void)
{
	Rune r;
	uchar *s;

	s = (uchar*)"A";              /* U+0041, 1 byte */
	CKEQ(chartorune(&r, (char*)s), 1);  CKEQX(r, 0x41);
	s = (uchar*)"\xc3\xa9";       /* U+00E9 e-acute, 2 bytes */
	CKEQ(chartorune(&r, (char*)s), 2);  CKEQX(r, 0xE9);
	s = (uchar*)"\xe2\x82\xac";   /* U+20AC euro, 3 bytes */
	CKEQ(chartorune(&r, (char*)s), 3);  CKEQX(r, 0x20AC);
}

static void
test_runetochar(void)
{
	char b[UTFmax+1];
	int n;

	n = runetochar(b, (Rune[]){0x41});    CKEQ(n, 1); b[n]=0; CKSTR(b, "A");
	n = runetochar(b, (Rune[]){0xE9});    CKEQ(n, 2); CKEQX((uchar)b[0],0xc3); CKEQX((uchar)b[1],0xa9);
	n = runetochar(b, (Rune[]){0x20AC});  CKEQ(n, 3); CKEQX((uchar)b[0],0xe2);
}

static void
test_runelen(void)
{
	CKEQ(runelen(0x41), 1);
	CKEQ(runelen(0xE9), 2);
	CKEQ(runelen(0x20AC), 3);
}

static void
test_utflen(void)
{
	/* "h" + e-acute + "llo" : 5 runes, 6 bytes */
	char *s = "h\xc3\xa9llo";
	CKEQ(strlen(s), 6);
	CKEQ(utflen(s), 5);
	CKEQ(utfnlen(s, 3), 2);   /* first 3 bytes = 'h' + 2-byte rune = 2 runes */
}

static void
test_utfrune(void)
{
	char *s = "ab\xc3\xa9z";
	CKSTR(utfrune(s, 0xE9), "\xc3\xa9z");   /* find the multibyte rune */
	CKSTR(utfrune(s, 'z'), "z");
	CK(utfrune(s, 'Q') == nil);
	CKSTR(utfrrune("a/b/c", '/'), "/c");    /* last occurrence */
}

CUNIT_MAIN("lib9/utf",
	test_chartorune, test_runetochar, test_runelen, test_utflen, test_utfrune)
