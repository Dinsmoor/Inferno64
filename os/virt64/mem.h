/*
 * Memory and machine-specific definitions.  Used in C and assembler.
 * qemu -M virt, aarch64: RAM starts at 1GB.
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

/*
 *  Address spaces.  Identity-mapped (or MMU off): virtual == physical.
 */
#define KZERO		0x40000000UL		/* base of RAM on qemu virt */
#define KTZERO		0x40200000UL		/* kernel text load address */
#define KSTACK		16384			/* kernel stack size (gcc frames are fat) */

/* boot defaults; confinit may someday read the DTB instead */
#define MEMSIZE		(256*_M_)
