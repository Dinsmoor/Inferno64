#include "../port/portfns.h"

void	archconfinit(void);
void	archreboot(void);
void	archreset(void);
void	clockcheck(void);
void	clockinit(void);
void	clockpoll(void);
#define	coherence()	__asm__ __volatile__("mfence" ::: "memory")
void	delay(int);
void	dumpregs(Ureg*);
void	dumpstack(void);
void	fpinit(void);
ulong	getfcr(void);
ulong	getfsr(void);
void	setfcr(ulong);
void	setfsr(ulong);
#define	getcallerpc(x)	((uintptr)__builtin_return_address(0))
#define	idlehands()	__asm__ __volatile__("sti; hlt" ::: "memory")
void	intrenable(int, void (*)(Ureg*, void*), void*, int, char*);
void	intrdisable(int, void (*)(Ureg*, void*), void*, int, char*);
void	intrenablemsi(int, void (*)(Ureg*, void*), void*, char*);

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

/* x86 port I/O */
uchar	inb(int port);
ushort	ins(int port);
ulong	inl(int port);
void	outb(int port, uchar v);
void	outs(int port, ushort v);
void	outl(int port, ulong v);
void	insb(int port, void *buf, int n);
void	outsb(int port, void *buf, int n);

/* MSRs and cpuid (arch.c / l.S) */
uvlong	rdmsr(ulong);
void	wrmsr(ulong, uvlong);
void	cpuid(ulong ax, ulong cx, ulong regs[4]);
uvlong	rdtsc(void);

/* local APIC / IO APIC (arch.c) */
void	lapicinit(void);
void	lapiceoi(void);
void	lapictimerset(uvlong);
ulong	lapicid(void);
void	ioapicinit(void);
void	ioapicenable(int irq, int vec);
void	ioapicdisable(int irq);
void	i8259init(void);
void	i8042init(void);

uchar*	ramfbinit(int*, int*);
uchar*	vgpuinit(int*, int*);
void	vgpustart(void);
void	virtioinputinit(void);
void	virtiornginit(void);
int	virtiorngread(uchar*, int);
void	pciscan(void);
void	screeninit(void);
void	screensize(int*, int*);
int	segflush(void*, ulong);
extern int	hostcursor;	/* an absolute-pointer driver sets 1: suppress the software cursor */
extern void	(*screenputs)(char*, int);
void	setpanic(void);
void	trapinit(void);
void	uartinit(void);
void	uartconsole(void);
void	uartputs(char*, int);
ulong	va2pa(void*);

/*
 * gcc must treat setlabel like setjmp or it will cache values
 * in registers across the second return.
 */
int	setlabel(Label*) __attribute__((returns_twice));

#define	waserror()	(up->nerrlab++, setlabel(&up->errlab[up->nerrlab-1]))

#define KADDR(p)	((void*)(uintptr)(p))
#define PADDR(v)	((uintptr)(v))

#define IOREG32(base, off)	(*(volatile u32int*)((uintptr)(base)+(off)))

#define	splfhi	splhi
#define	splflo	spllo
