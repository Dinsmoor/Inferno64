/*
 * aarch64 exception frame, built by the vector stubs in l.S.
 * Layout is known to l.S — keep them in sync.
 */
typedef struct Ureg Ureg;
struct Ureg
{
	uvlong	r[31];		/* x0-x30; r[30] is the link register */
	uvlong	sp;		/* SP at time of trap (== &ureg+1 for kernel traps) */
	uvlong	pc;		/* ELR_EL1 */
	uvlong	psr;		/* SPSR_EL1 */
	uvlong	type;		/* vector index: 0 sync, 1 irq, 2 fiq, 3 serror */
	uvlong	esr;		/* ESR_EL1 */
	uvlong	far;		/* FAR_EL1 */
	uvlong	pad;		/* keep 16-byte stack alignment */
};
#define	UREGLINK(u)	((u)->r[30])
