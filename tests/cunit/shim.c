/*
 * shim.c -- minimal host implementations of the kernel/emu allocation hooks
 * that some libraries (libmp, libsec, ...) call but lib9 does not provide.
 * Linked into every cunit test; harmless for sections that never call them.
 */
#include "lib9.h"

/* Inferno's allocate-and-maybe-zero.  In emu this comes from the pool
 * allocator; for a host unit test plain malloc + memset is exactly right. */
void*
mallocz(ulong size, int clr)
{
	void *p = malloc(size);
	if(p != nil && clr)
		memset(p, 0, size);
	return p;
}

/* IEEE special values; in emu these live in libmath's FP support.  charstod
 * (lib9) calls NaN() on a malformed number. */
double
NaN(void)
{
	static const uvlong qnan = 0x7ff8000000000000ULL;
	double d;
	memmove(&d, &qnan, sizeof d);
	return d;
}

double
Inf(int sign)
{
	uvlong inf = 0x7ff0000000000000ULL;
	double d;
	if(sign < 0)
		inf |= 0x8000000000000000ULL;
	memmove(&d, &inf, sizeof d);
	return d;
}
