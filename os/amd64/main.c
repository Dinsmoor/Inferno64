#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "version.h"

Mach Mach0;
Mach *m = &Mach0;
Proc *up = 0;
Conf conf;
void (*screenputs)(char*, int);	/* set by screen.c if there's a framebuffer */

extern ulong kerndate;
extern int cflag;
extern ulong jitarenasize;
extern int jitsinglearena;
extern int consoleprint;
extern int main_pool_pcnt;
extern int heap_pool_pcnt;
extern int image_pool_pcnt;

extern char end[];
extern ulong boottime;	/* devcons.c: epoch seconds at boot; 0 = clock starts at 1970 */

int
segflush(void *p, ulong l)
{
	/* x86 keeps the instruction cache coherent with stores; the JIT
	 * needs only a compiler/serialization barrier before executing
	 * freshly written code. */
	USED(p); USED(l);
	__asm__ __volatile__("mfence" ::: "memory");
	return 0;
}

static void
poolsizeinit(void)
{
	ulong nb;

	nb = conf.npage*BY2PG;
	poolsize(mainmem, (nb*main_pool_pcnt)/100, 0);
	poolsize(heapmem, (nb*heap_pool_pcnt)/100, 0);
	poolsize(imagmem, (nb*image_pool_pcnt)/100, 1);
}

void
reboot(void)
{
	exit(0);
}

void
halt(void)
{
	spllo();
	print("cpu halted\n");
	for(;;)
		idlehands();
}

void
confinit(void)
{
	uintptr base;

	conf.topofmem = KZERO + MEMSIZE;

	base = PGROUND((uintptr)end);
	conf.base0 = base;
	conf.base1 = 0;
	conf.npage1 = 0;
	conf.npage0 = (conf.topofmem - base)/BY2PG;
	conf.npage = conf.npage0 + conf.npage1;
	conf.ialloc = (((conf.npage*main_pool_pcnt)/100)/2)*BY2PG;

	conf.nproc = 100;
	conf.nmach = 1;
}

void
machinit(void)
{
	memset(m, 0, sizeof(Mach));
}

void
main(void)
{
	uartinit();
	machinit();
	confinit();
	xinit();
	poolinit();
	poolsizeinit();
	trapinit();
	clockinit();
	boottime = rtctime();	/* 0 = clock starts at 1970 */
	printinit();
	quotefmtinstall();	/* %q: sh and the wm window protocol depend on it */
	boardinit();		/* early board hook: framebuffer etc. */
	procinit();
	links();
	chandevreset();
	boardready();		/* late board hook: remaining device probes */

	/*
	 * Dis JIT: one xalloc arena (see jitcode in comp-amd64.c).  When it
	 * fills, later modules run interpreted — correct but slow.  Start
	 * interpreted (cflag=0) during bring-up; flip to 1 once the JIT is
	 * validated on amd64.
	 */
	cflag = 0;
	jitarenasize = 16*1024*1024;
	jitsinglearena = 1;

	eve = strdup("inferno");

	print("\nInferno %s\n", VERSION);
	print("conf %s (%lud) jit %d\n\n", conffile, kerndate, cflag);
	userinit();
	schedinit();
	panic("schedinit returned");
}

void
init0(void)
{
	Osenv *o;

	up->nerrlab = 0;
	spllo();
	if(waserror())
		panic("init0 %r");

	o = up->env;
	o->pgrp->slash = namec("#/", Atodir, 0, 0);
	cnameclose(o->pgrp->slash->name);
	o->pgrp->slash->name = newcname("/");
	o->pgrp->dot = cclone(o->pgrp->slash);

	chandevinit();
	poperror();

	disinit("/osinit.dis");
}

void
userinit(void)
{
	Proc *p;
	Osenv *o;

	p = newproc();
	o = p->env;

	o->fgrp = newfgrp(nil);
	o->pgrp = newpgrp();
	kstrdup(&o->user, eve);

	strcpy(p->text, "interp");

	p->fpstate = FPINIT;

	/*
	 * Kernel Stack.  gotolabel enters init0 with a `jmp`, so we must
	 * fabricate the post-`call` stack state SysV expects: rsp ≡ 8 (mod 16)
	 * at function entry, or gcc's aligned SSE (movdqa) on locals faults.
	 */
	p->sched.pc = (uintptr)init0;
	p->sched.sp = (((uintptr)p->kstack+KSTACK-32) & ~15UL) - 8;

	ready(p);
}

void
exit(int inpanic)
{
	up = 0;
	chandevshutdown();

	if(inpanic){
		print("waiting for reset\n");
		for(;;)
			idlehands();
	}
	archreboot();
}

void
archreboot(void)
{
	int i;

	print("rebooting\n");
	/* pulse the 0xcf9 reset control port (qemu / ICH9) */
	outb(0xcf9, 0x02);
	outb(0xcf9, 0x06);
	/* fall back to a triple fault via a null IDT */
	for(i = 0; i < 100; i++)
		delay(10);
	for(;;)
		idlehands();
}

static void
linkproc(void)
{
	spllo();
	if(waserror())
		print("error() underflow: %r\n");
	else
		(*up->kpfun)(up->arg);
	pexit("end proc", 1);
}

void
kprocchild(Proc *p, void (*func)(void*), void *arg)
{
	p->sched.pc = (uintptr)linkproc;
	p->sched.sp = (((uintptr)p->kstack+KSTACK-32) & ~15UL) - 8;	/* SysV: rsp ≡ 8 (mod 16) */

	p->kpfun = func;
	p->arg = arg;
}

void
fpinit(void)
{
	__asm__ __volatile__("fninit");
	setfcr(0x1f80);		/* MXCSR: all exceptions masked, round to nearest */
	setfsr(0);
}

ulong
va2pa(void *v)
{
	return (ulong)(uintptr)v;
}

void
idlehands_(void)
{
}
