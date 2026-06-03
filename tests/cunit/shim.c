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
