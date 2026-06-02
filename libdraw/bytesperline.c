#include "lib9.h"
#include "draw.h"

static
int
unitsperline(Rectangle r, int d, int bitsperunit)
{
	ulong l, t;

	if(r.min.x >= 0){
		l = (r.max.x*d+bitsperunit-1)/bitsperunit;
		l -= (r.min.x*d)/bitsperunit;
	}else{			/* make positive before divide */
		t = (-r.min.x*d+bitsperunit-1)/bitsperunit;
		l = t+(r.max.x*d+bitsperunit-1)/bitsperunit;
	}
	return l;
}

int
wordsperline(Rectangle r, int d)
{
	/*
	 * LP64: a draw "word" is fixed at 32 bits (u32int), matching the
	 * packed image layout used by the draw protocol, image files, fonts
	 * and the X11 backend.  It must NOT track sizeof(ulong), which is 8
	 * on LP64 and would double every scan-line stride.
	 */
	return unitsperline(r, d, 8*sizeof(u32int));
}

int
bytesperline(Rectangle r, int d)
{
	return unitsperline(r, d, 8);
}
