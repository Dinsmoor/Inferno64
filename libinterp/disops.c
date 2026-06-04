#include "lib9.h"

/*
 * Self-contained .dis decoding primitives, factored out of load.c so they can
 * be unit-tested in isolation (tests/cunit/libinterp) without dragging in the
 * whole module loader.  These are LP64-sensitive: the operand encoding is
 * signed and disw/canontod must keep their results a clean 32-bit width on a
 * host where `long` is 64-bit.
 */

/*
 * Decode one Dis operand from the byte stream and advance *p.
 *   00xx xxxx              -> 6-bit non-negative value
 *   01xx xxxx              -> 6-bit value, sign-extended (negative)
 *   10xx xxxx  bbbbbbbb    -> 14-bit value, sign-extended via bit 0x20
 *   11xx xxxx  b b b       -> 30-bit value, sign-extended via bit 0x20
 */
int
operand(uchar **p)
{
	int c;
	uchar *cp;

	cp = *p;
	c = cp[0];
	switch(c & 0xC0) {
	case 0x00:
		*p = cp+1;
		return c;
	case 0x40:
		*p = cp+1;
		return c|~0x7F;
	case 0x80:
		*p = cp+2;
		if(c & 0x20)
			c |= ~0x3F;
		else
			c &= 0x3F;
		/* shift in u32int: c is sign-extended (negative) here, and a
		 * left shift of a negative int is UB.  The bit pattern is the
		 * same; the (int) cast just makes it well-defined. */
		return (int)(((u32int)c<<8)|cp[1]);
	case 0xC0:
		*p = cp+4;
		if(c & 0x20)
			c |= ~0x3F;
		else
			c &= 0x3F;
		return (int)(((u32int)c<<24)|((u32int)cp[1]<<16)|((u32int)cp[2]<<8)|cp[3]);
	}
	return 0;
}

ulong
disw(uchar **p)
{
	ulong v;
	uchar *c;

	c = *p;
	/*
	 * Assemble as u32int: c[0]<<24 with c[0] promoted to int overflows on a
	 * high byte >= 0x80 and (being UB) sign-extends into bits 32..63 of the
	 * ulong on LP64.  Callers happen to truncate to 32-bit WORDs today, but
	 * keep the returned value a clean 32-bit quantity regardless.
	 */
	v  = (ulong)((u32int)c[0] << 24);
	v |= (u32int)c[1] << 16;
	v |= (u32int)c[2] << 8;
	v |= (u32int)c[3];
	*p = c + 4;
	return v;
}

double
canontod(ulong v[2])
{
	/*
	 * Reassemble an IEEE double from its two 32-bit halves.  The element
	 * type MUST be 32-bit: on LP64 "unsigned long" is 8 bytes, so ul[0]/ul[1]
	 * would no longer pack into the 8-byte double and every real constant in
	 * the .dis data section loaded as garbage.  "unsigned int" is 32-bit on
	 * both ILP32 and LP64 (cf. the same fix in libmath/dtoa.c).
	 */
	union { double d; unsigned int ul[2]; } a;
	a.d = 1.;
	if(a.ul[0]) {
		a.ul[0] = v[0];
		a.ul[1] = v[1];
	}
	else {
		a.ul[1] = v[0];
		a.ul[0] = v[1];
	}
	return a.d;
}
