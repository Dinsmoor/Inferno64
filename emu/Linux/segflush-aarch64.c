#include <stdint.h>
#include <unistd.h>
#include <sys/mman.h>

#include "dat.h"

/*
 * Flush the I-cache for a region of freshly generated JIT code and make it
 * executable.  The Dis JIT (libinterp/comp-aarch64.c) writes native code into
 * pool-allocated (heap) memory, which Linux maps non-executable; without the
 * mprotect below the CPU faults on the first instruction fetch.  __builtin___
 * clear_cache handles the D-cache->I-cache coherency (see AGENTS_AARCH64.md).
 */
int
segflush(void *a, ulong n)
{
	uintptr_t start, end, pg;

	if(n == 0)
		return 0;

	pg = sysconf(_SC_PAGESIZE);
	start = (uintptr_t)a & ~(pg-1);
	end = ((uintptr_t)a + n + pg-1) & ~(pg-1);
	mprotect((void*)start, end - start, PROT_READ|PROT_WRITE|PROT_EXEC);

	__builtin___clear_cache((char*)a, (char*)a + n);
	return 0;
}
