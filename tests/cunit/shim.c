/*
 * shim.c -- minimal host implementations of the kernel/emu allocation hooks
 * that some libraries (libmp, libsec, ...) call but lib9 does not provide.
 * Linked into every cunit test; harmless for sections that never call them.
 */
#include "lib9.h"
#include "pool.h"
#include <stdio.h>

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

/* lib9's assert() macro expands to _assert(); the real one lives in the
 * kernel/emu.  Abort loudly so a tripped assertion fails the test. */
void
_assert(char *s)
{
	fprintf(stderr, "assert failed: %s\n", s);
	abort();
}

/* test-and-set behind Lock; emu uses an arch asm version.  cunit tests are
 * single-threaded, so a plain non-atomic test-set is correct here. */
int
_tas(int *p)
{
	int old = *p;
	*p = 1;
	return old;
}

/*
 * Image memory pool.  In emu libmemdraw allocates pixel storage from the
 * emu pool `imagmem`; for host tests a malloc-backed stub is equivalent.
 * poolname() returns a real name (memimageinit strcmps it un-guarded);
 * poolsetcompact is a no-op since we never relocate. imagmem is only ever
 * passed straight back to these stubs.
 */
Pool *imagmem;

void*
poolalloc(Pool *p, ulong n)
{
	USED(p);
	return malloc(n);
}

void
poolfree(Pool *p, void *v)
{
	USED(p);
	free(v);
}

char*
poolname(Pool *p)
{
	USED(p);
	return "image";
}

void
poolsetcompact(Pool *p, void (*mv)(void*, void*))
{
	USED(p); USED(mv);
}
