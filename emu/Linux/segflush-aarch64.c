#include "dat.h"

int
segflush(void *a, ulong n)
{
	if(n)
		__builtin___clear_cache((char*)a, (char*)a + n);
	return 0;
}
