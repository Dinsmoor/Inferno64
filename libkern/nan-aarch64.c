#include <lib9.h>

/*
 * LP64-clean NaN/Inf via FPdbleword.
 */

#define	NANEXP	(2047U<<20)
#define	NANMASK	(2047U<<20)
#define	NANSIGN	(1U<<31)

double
NaN(void)
{
	FPdbleword a;

	a.hi = NANEXP;
	a.lo = 1;
	return a.x;
}

int
isNaN(double d)
{
	FPdbleword a;

	a.x = d;
	return ((a.hi & NANMASK) == NANEXP) && ((a.hi & ~(NANSIGN|NANMASK)) != 0 || a.lo != 0);
}

double
Inf(int sign)
{
	FPdbleword a;

	a.hi = NANEXP;
	a.lo = 0;
	if(sign < 0)
		a.hi |= NANSIGN;
	return a.x;
}

int
isInf(double d, int sign)
{
	FPdbleword a;

	a.x = d;
	if((a.hi & ~NANSIGN) != NANEXP || a.lo != 0)
		return 0;
	if(sign == 0)
		return 1;
	if(sign > 0)
		return (a.hi & NANSIGN) == 0;
	return (a.hi & NANSIGN) != 0;
}
