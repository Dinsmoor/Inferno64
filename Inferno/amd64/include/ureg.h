/*
 * amd64 trap/exception frame, built by the vector stubs in l.S.
 * Layout is known to l.S (UREG_* offsets) — keep them in sync.
 *
 * Low address first.  The general registers are pushed by the common
 * stub; type/error by the per-vector stub (error forced to 0 for the
 * vectors the CPU doesn't push one for); pc/cs/flags/sp/ss are pushed
 * by the CPU on the interrupt (long mode always pushes the full five,
 * even without a privilege change).
 */
typedef struct Ureg Ureg;
struct Ureg
{
	uvlong	ax;
	uvlong	bx;
	uvlong	cx;
	uvlong	dx;
	uvlong	si;
	uvlong	di;
	uvlong	bp;
	uvlong	r8;
	uvlong	r9;
	uvlong	r10;
	uvlong	r11;
	uvlong	r12;
	uvlong	r13;
	uvlong	r14;
	uvlong	r15;

	uvlong	type;		/* vector number */
	uvlong	error;		/* error code, or 0 */

	uvlong	pc;		/* ip (cpu-pushed) */
	uvlong	cs;		/* (cpu-pushed) */
	uvlong	flags;		/* rflags (cpu-pushed) */
	uvlong	sp;		/* rsp (cpu-pushed) */
	uvlong	ss;		/* (cpu-pushed) */
};
#define	UREGLINK(u)	((u)->pc)
