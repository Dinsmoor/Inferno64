#include <stdint.h>
#include <libkern/OSCacheControl.h>

#include "dat.h"

/*
 * Make freshly generated JIT code visible to instruction fetch.  On macOS
 * arm64 the JIT arena is mmap(MAP_JIT) memory (libinterp/comp-aarch64.c),
 * so no mprotect is needed (or allowed: W^X is per-thread, toggled with
 * pthread_jit_write_protect_np); just invalidate the I-cache.
 */
int
segflush(void *a, ulong n)
{
	if(n != 0)
		sys_icache_invalidate(a, n);
	return 0;
}
