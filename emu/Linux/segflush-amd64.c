#include <sys/types.h>
#include <sys/syscall.h>

#include "dat.h"

/*
 * x86 keeps the instruction cache coherent with data writes, so flushing
 * after generating native code is a no-op (as on the 386 build).  Relevant
 * only to the JIT, which is stubbed on this target.
 */
int
segflush(void *a, ulong n)
{
	USED(a); USED(n);
	return 0;
}
