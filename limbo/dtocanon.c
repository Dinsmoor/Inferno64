#include "limbo.h"

void
dtocanon(double f, ulong v[])
{
	/*
	 * The union element MUST be 32-bit: on LP64 "ulong" is 8 bytes, so ul[0]
	 * would alias the whole double and ul[1] garbage, emitting the wrong two
	 * 32-bit words (every real constant then loaded as ~0).  "unsigned int"
	 * is 32-bit on both ILP32 and LP64.  Harmless on this 32-bit tree.
	 */
	union { double d; unsigned int ul[2]; } a;

	a.d = 1.;
	if(a.ul[0]){
		a.d = f;
		v[0] = a.ul[0];
		v[1] = a.ul[1];
	}else{
		a.d = f;
		v[0] = a.ul[1];
		v[1] = a.ul[0];
	}
}

double
canontod(ulong v[2])
{
	union { double d; unsigned int ul[2]; } a;	/* 32-bit halves; see dtocanon */

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
