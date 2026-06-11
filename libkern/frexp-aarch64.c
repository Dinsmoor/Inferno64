#include <lib9.h>

/*
 * LP64-clean frexp family: manipulate IEEE-754 doubles through
 * FPdbleword (u32int halves), not 32-bit `long` punning.
 */

#define	MASK	0x7ffU
#define	SHIFT	20
#define	BIAS	1022

double
frexp(double d, int *ep)
{
	FPdbleword x;

	if(d == 0.0){
		*ep = 0;
		return 0.0;
	}
	x.x = d;
	*ep = ((x.hi >> SHIFT) & MASK) - BIAS;
	x.hi = (x.hi & ~(MASK << SHIFT)) | (BIAS << SHIFT);
	return x.x;
}

double
ldexp(double d, int e)
{
	FPdbleword x;
	int exp;

	if(d == 0.0)
		return 0.0;
	x.x = d;
	exp = ((x.hi >> SHIFT) & MASK) + e;
	if(exp <= 0)
		return 0.0;
	if(exp >= (int)MASK){
		if(d < 0.0)
			return -1.79769313486231e308;
		return 1.79769313486231e308;
	}
	x.hi = (x.hi & ~(MASK << SHIFT)) | ((u32int)exp << SHIFT);
	return x.x;
}

double
modf(double d, double *ip)
{
	double f;
	FPdbleword x;
	int e;

	if(d < 1.0){
		if(d < 0.0){
			f = modf(-d, ip);
			*ip = -*ip;
			return -f;
		}
		*ip = 0.0;
		return d;
	}
	x.x = d;
	e = ((x.hi >> SHIFT) & MASK) - BIAS;
	if(e <= SHIFT+1){
		x.hi &= ~(0x1fffffU >> e);
		x.lo = 0;
	}else if(e <= SHIFT+33)
		x.lo &= ~(0xffffffffU >> (e-SHIFT-1));
	*ip = x.x;
	return d - x.x;
}
