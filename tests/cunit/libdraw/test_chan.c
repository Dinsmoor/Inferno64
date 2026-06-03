/* libdraw channel descriptors: strtochan / chantostr / chantodepth (chan.c). */
#include "lib9.h"
#include "draw.h"
#include "cunit.h"

static void
test_roundtrip(void)
{
	char buf[32];
	ulong c = strtochan("r8g8b8a8");
	CK(c != 0);
	chantostr(buf, c);
	CKSTR(buf, "r8g8b8a8");

	c = strtochan("k8");
	chantostr(buf, c);
	CKSTR(buf, "k8");

	c = strtochan("m8");
	chantostr(buf, c);
	CKSTR(buf, "m8");
}

static void
test_depth(void)
{
	CKEQ(chantodepth(strtochan("r8g8b8a8")), 32);
	CKEQ(chantodepth(strtochan("r8g8b8")), 24);
	CKEQ(chantodepth(strtochan("r5g6b5")), 16);
	CKEQ(chantodepth(strtochan("k8")), 8);
	CKEQ(chantodepth(strtochan("k1")), 1);
}

CUNIT_MAIN("libdraw/chan", test_roundtrip, test_depth)
