/*
 * Memory and machine-specific definitions.  Used in C and assembler.
 * Board-specific facts (RAM base/size, load address, MMU map) come
 * from board.h, found via the board include path the Makefile sets up.
 */

/*
 * Sizes
 */
#define _K_		1024
#define _M_		1048576
#define _G_		1073741824
#define	BI2BY		8			/* bits per byte */
#define BI2WD		64			/* bits per word */
#define	BY2WD		8			/* bytes per word */
#define	BY2V		8			/* bytes per double word */
#define	BY2PG		4096			/* bytes per page */
#define	WD2PG		(BY2PG/BY2WD)		/* words per page */
#define	PGSHIFT		12			/* log(BY2PG) */
#define ROUND(s, sz)	(((s)+(sz-1))&~(sz-1))
#define PGROUND(s)	ROUND(s, BY2PG)
#define BIT(n)		(1<<n)
#define BITS(a,b)	((1<<(b+1))-(1<<a))

#define	MAXMACH		1			/* max # cpus system can run */

/*
 * Time
 */
#define	HZ		(100)			/* clock frequency */
#define	MS2HZ		(1000/HZ)		/* millisec per clock tick */
#define	TK2SEC(t)	((t)/HZ)		/* ticks to seconds */
#define	MS2TK(t)	((t)/MS2HZ)		/* milliseconds to ticks */

#define KSTACK		16384			/* kernel stack size (gcc frames are fat) */

/* KZERO, KTZERO, MEMSIZE, the MMU L1 map, the PSCI conduit */
#include "board.h"
