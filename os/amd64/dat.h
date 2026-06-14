typedef struct Conf	Conf;
typedef struct FPenv	FPenv;
typedef struct FPU	FPU;
typedef struct Label	Label;
typedef struct Lock	Lock;
typedef struct Mach	Mach;
typedef struct Ureg	Ureg;
typedef struct ISAConf	ISAConf;

typedef uchar Instr;		/* x86 instructions are variable length */

#define ISAOPTLEN 16
#define NISAOPT 8
struct Conf
{
	ulong	nmach;			/* processors */
	ulong	nproc;			/* processes */
	ulong	npage0;			/* total physical pages of memory */
	ulong	npage1;			/* total physical pages of memory */
	uintptr	topofmem;		/* highest physical address + 1 */
	ulong	npage;			/* total physical pages of memory */
	uintptr	base0;			/* base of bank 0 */
	uintptr	base1;			/* base of bank 1 */
	ulong	ialloc;			/* max interrupt time allocation in bytes */
	ulong	cpuspeed;
};

struct ISAConf {
	char	type[KNAMELEN];
	ulong	port;
	ulong	irq;
	ulong	dma;
	ulong	mem;
	ulong	size;
	ulong	freq;

	int	nopt;
	char	opt[NISAOPT][ISAOPTLEN];
};

/* devsd's hot-config plumbing wants these complete (we never hot-config) */
typedef struct Devport Devport;
struct Devport {
	ulong	port;
	int	size;
};
struct DevConf {
	ulong	intnum;			/* interrupt number */
	char	*type;			/* card type, malloced */
	int	nports;			/* Number of ports */
	Devport	*ports;			/* The ports themselves */
};

/*
 * FPenv.status
 */
enum
{
	FPINIT,
	FPACTIVE,
	FPINACTIVE,
};

struct	FPenv
{
	ulong	status;			/* x87 status word (sticky exceptions) */
	ulong	control;		/* MXCSR (rounding + masks) */
};

/*
 * Per-Dis-thread FP state at a prog switch is just the control/status
 * words (MXCSR + x87 CW): live xmm/x87 values sit in Dis frames in
 * memory at the r->xec(r) call boundary (caller-saved), and the trap
 * stubs FXSAVE/FXRSTOR the full register file across interrupts.  The
 * same minimal-FPenv discipline as the aarch64 port — saving the whole
 * register file into this 16-byte struct would scribble the heap.
 */
struct	FPU
{
	FPenv	env;
};

/*
 * Layout known to setlabel/gotolabel in l.S.  gcc/SysV callee-saved
 * integer registers are rbx, rbp, r12-r15; no callee-saved xmm.
 */
struct Label
{
	uintptr	sp;
	uintptr	pc;		/* return address */
	uintptr	bx;
	uintptr	bp;
	uintptr	r12;
	uintptr	r13;
	uintptr	r14;
	uintptr	r15;
};

struct Lock
{
	ulong	key;
	ulong	sr;		/* saved RFLAGS across ilock (IF state) */
	uintptr	pc;
	int	pri;
};

#include "../port/portdat.h"

/*
 *  machine dependent definitions not used by ../port/portdat.h
 */
struct Mach
{
	ulong	ticks;			/* of the clock since boot time */
	Proc	*proc;			/* current process on this processor */
	Label	sched;			/* scheduler wakeup */
	Lock	alarmlock;		/* access to alarm list */
	void	*alarm;			/* alarms bound to this clock */
	int	machno;
	int	nrdy;
	uvlong	timerfreq;		/* LAPIC timer counts per second (calibrated) */
	uvlong	cpuhz;			/* TSC frequency (calibrated), for fastticks/delay */

	int	stack[1];
};

extern Mach Mach0;
#define MACHADDR	(&Mach0)
#define	MACHP(n)	((n) == 0 ? MACHADDR : (Mach*)0)

extern Mach *m;
extern Proc *up;

#define	swcursor	1
