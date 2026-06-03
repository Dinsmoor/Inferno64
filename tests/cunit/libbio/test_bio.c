/*
 * libbio buffered I/O.  Round-trips data through a temp file, and checks the
 * 64-bit file-position path (Bseek/Boffset are vlong) with an offset above
 * 2^32 -- on a sparse file that costs nothing but exercises the LP64 width.
 */
#include "lib9.h"
#include "bio.h"
#include "cunit.h"
#include <unistd.h>

static char path[64];

static void
test_write_read(void)
{
	Biobuf *b;
	char *ln;

	b = Bopen(path, OWRITE);
	CK(b != nil);
	if(b == nil) return;
	Bprint(b, "line one\n");
	Bwrite(b, "line two\n", 9);
	Bputc(b, 'X');
	Bterm(b);

	b = Bopen(path, OREAD);
	CK(b != nil);
	if(b == nil) return;
	ln = Brdline(b, '\n');
	CKEQ(Blinelen(b), 9);
	CK(ln != nil && strncmp(ln, "line one\n", 9) == 0);
	ln = Brdline(b, '\n');
	CK(ln != nil && strncmp(ln, "line two\n", 9) == 0);
	CKEQ(Bgetc(b), 'X');       /* last byte, no newline */
	CKEQ(Bgetc(b), Beof);
	CKEQ(Boffset(b), 19);      /* 9 + 9 + 1 bytes consumed */
	Bterm(b);
}

static void
test_seek_rune(void)
{
	Biobuf *b = Bopen(path, OREAD);
	Rune r;
	CK(b != nil);
	if(b == nil) return;
	Bseek(b, 5, 0);
	CKEQ(Boffset(b), 5);
	CKEQ(Bgetc(b), 'o');       /* "line one": index 5 == 'o' */

	/* a unicode round-trip through Bgetrune */
	Bseek(b, 0, 0);
	r = 0;
	CKEQ(Bgetrune(b), 'l');
	USED(r);
	Bterm(b);
}

static void
test_offset64(void)
{
	/* sparse seek well past 2^32: Bseek/Boffset are vlong and must not wrap */
	Biobuf *b = Bopen(path, OWRITE);
	vlong off = 0x1ffffffffLL;     /* ~8 GB, > 2^32 */
	CK(b != nil);
	if(b == nil) return;
	CKEQ(Bseek(b, off, 0), off);
	CKEQ(Boffset(b), off);
	Bputc(b, '!');
	CKEQ(Boffset(b), off + 1);
	Bterm(b);
}

int
main(void)
{
	cunit_fn tests[] = { test_write_read, test_seek_rune, test_offset64 };
	int i;
	snprint(path, sizeof path, "/tmp/cunit_bio_%d", (int)getpid());
	for(i = 0; i < (int)(sizeof tests/sizeof tests[0]); i++)
		tests[i]();
	remove(path);
	if(cunit_fail == 0){ printf("ALLPASS libbio/bio (%d checks)\n", cunit_pass); return 0; }
	printf("FAILED libbio/bio %d\n", cunit_fail); return 1;
}
