/*
 * lib9 9P/Styx marshalling: convS2M/convM2S (Fcall) and convD2M/convM2D (Dir).
 * The wire format carries 64-bit fields -- Fcall.offset (vlong), Qid.path
 * (uvlong), Dir.length (vlong) -- so a round-trip with values above 2^32 is a
 * direct test that the packers move all 64 bits on both ABIs.
 */
#include "lib9.h"
#include "fcall.h"
#include "cunit.h"

static void
test_tread(void)
{
	Fcall t, r;
	uchar buf[256];
	uint n, m;

	memset(&t, 0, sizeof t);
	t.type = Tread;
	t.tag = 0x1234;
	t.fid = 0xdeadbeef;
	t.offset = 0x0123456789abcdefLL;   /* 64-bit offset */
	t.count = 8192;

	n = convS2M(&t, buf, sizeof buf);
	CK(n > 0);
	m = convM2S(buf, n, &r);
	CKEQ(m, n);
	CKEQ(r.type, Tread);
	CKEQX(r.tag, 0x1234);
	CKEQX(r.fid, 0xdeadbeef);
	CKEQX(r.offset, 0x0123456789abcdefLL);
	CKEQ(r.count, 8192);
}

static void
test_rattach_qid(void)
{
	Fcall t, r;
	uchar buf[256];
	uint n;

	memset(&t, 0, sizeof t);
	t.type = Rattach;
	t.tag = 1;
	t.qid.path = 0xcafebabedeadbeefULL;   /* 64-bit qid path */
	t.qid.vers = 7;
	t.qid.type = 0x80;

	n = convS2M(&t, buf, sizeof buf);
	CK(n > 0);
	convM2S(buf, n, &r);
	CKEQX(r.qid.path, 0xcafebabedeadbeefULL);
	CKEQ(r.qid.vers, 7);
	CKEQ(r.qid.type, 0x80);
}

static void
test_dir(void)
{
	Dir d, e;
	uchar buf[256];
	char strs[128];
	uint n, m;

	memset(&d, 0, sizeof d);
	d.type = 0;
	d.dev = 0;
	d.qid.path = 0x1122334455667788ULL;
	d.qid.vers = 1;
	d.qid.type = QTDIR;
	d.mode = DMDIR | 0755;
	d.atime = 1000;
	d.mtime = 2000;
	d.length = 0x7fffffff12345678LL;    /* 64-bit length */
	d.name = "file";
	d.uid = "user";
	d.gid = "grp";
	d.muid = "mod";

	n = convD2M(&d, buf, sizeof buf);
	CK(n > 0);
	m = convM2D(buf, n, &e, strs);
	CKEQ(m, n);
	CKEQX(e.qid.path, 0x1122334455667788ULL);
	CKEQ(e.length, 0x7fffffff12345678LL);
	CKEQX(e.mode, (ulong)(DMDIR | 0755));
	CKSTR(e.name, "file");
	CKSTR(e.uid, "user");
	CKSTR(e.muid, "mod");
}

CUNIT_MAIN("lib9/fcall", test_tread, test_rattach_qid, test_dir)
