typedef struct Conf	Conf;
typedef struct FPenv	FPenv;
typedef struct FPU	FPU;
typedef struct Label	Label;
typedef struct Lock	Lock;
typedef struct Mach	Mach;
typedef struct Ureg	Ureg;
typedef struct ISAConf	ISAConf;

typedef u32int Instr;		/* aarch64 instructions are fixed 32-bit */

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
	ulong	status;
	ulong	control;
};

/*
 * This structure must agree with FPsave/FPrestore in l.S:
 * 32 q registers then fpcr, fpsr.
 */
struct	FPU
{
	uvlong	vregs[64];	/* q0-q31 */
	u32int	fpcr;
	u32int	fpsr;
	FPenv	env;
};

/*
 * Layout known to setlabel/gotolabel in l.S.
 * gcc has callee-saved registers (unlike kencc), so a Label
 * holds x19-x29 and d8-d15 as well as sp/pc.
 */
struct Label
{
	uintptr	sp;
	uintptr	pc;		/* really lr */
	uintptr	regs[11];	/* x19-x29 */
	uvlong	fpregs[8];	/* d8-d15 */
};

struct Lock
{
	ulong	key;
	ulong	sr;
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
	uvlong	timerfreq;		/* CNTFRQ_EL0 */

	int	stack[1];
};

extern Mach Mach0;
#define MACHADDR	(&Mach0)
#define	MACHP(n)	((n) == 0 ? MACHADDR : (Mach*)0)

extern Mach *m;
extern Proc *up;

#define	swcursor	1
