#include "../port/portfns.h"

void	archconfinit(void);
void	archreboot(void);
void	archreset(void);
void	clockcheck(void);
void	clockinit(void);
void	clockpoll(void);
#define	coherence()	__asm__ __volatile__("dmb ish" ::: "memory")
void	delay(int);
void	dumpregs(Ureg*);
void	dumpstack(void);
int	fpiarm(Ureg*);
void	fpinit(void);
ulong	getfcr(void);
ulong	getfsr(void);
void	setfcr(ulong);
void	setfsr(ulong);
#define	getcallerpc(x)	((uintptr)__builtin_return_address(0))
#define	idlehands()	__asm__ __volatile__("wfe" ::: "memory")
void	intrenable(int, void (*)(Ureg*, void*), void*, int, char*);
void	intrdisable(int, void (*)(Ureg*, void*), void*, int, char*);

/*
 * interrupt-controller driver interface (gic-v2.c, someday gic-v3.c):
 * init, per-irq mask/unmask, and the claim/dispatch/eoi loop, which
 * calls back into trap.c's dispatchirq for each pending vector.
 */
void	intcinit(void);
void	intcenable(int);
void	intcdisable(int);
void	intcdispatch(Ureg*);
void	dispatchirq(Ureg*, int);

/*
 * board hooks (boards/$HWTARG/board.c): boardinit runs early, right
 * after the console uart is up; boardready runs after chandevreset,
 * when the kernel is fully able to host drivers.
 */
void	boardinit(void);
void	boardready(void);
ulong	rtctime(void);		/* epoch seconds, 0 if the board can't know */
void	links(void);
void	microdelay(int);
#define procsave(p)
#define procrestore(p)
uvlong	psci_call(ulong, uvlong, uvlong, uvlong);

/* PSCI 0.2+ function ids (conduit per board.h: hvc, or smc under TF-A) */
enum {
	PSCI_VERSION		= 0x84000000,
	PSCI_SYSTEM_OFF		= 0x84000008,
	PSCI_SYSTEM_RESET	= 0x84000009,
	PSCI_CPU_ON		= 0xC4000003,	/* SMP secondary bring-up (unused) */
};
uchar*	ramfbinit(int*, int*);
void	screeninit(void);
void	screensize(int*, int*);
void	virtioinputinit(void);
int	segflush(void*, ulong);
extern void	(*screenputs)(char*, int);
void	setpanic(void);
void	trapinit(void);
void	uartinit(void);
void	vectors(void);
void	virtiornginit(void);
int	virtiorngread(uchar*, int);
ulong	va2pa(void*);

/*
 * gcc must treat setlabel like setjmp or it will cache values
 * in registers across the second return.
 */
int	setlabel(Label*) __attribute__((returns_twice));

#define	waserror()	(up->nerrlab++, setlabel(&up->errlab[up->nerrlab-1]))

#define KADDR(p)	((void*)(p))
#define PADDR(v)	((uintptr)(v))

#define IOREG32(base, off)	(*(volatile u32int*)((uintptr)(base)+(off)))

#define	splfhi	splhi
#define	splflo	spllo
