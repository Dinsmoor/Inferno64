#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "io.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"
#include "version.h"

Mach Mach0;
Mach *m = &Mach0;
Proc *up = 0;
Conf conf;
void (*screenputs)(char*, int);	/* no screen on this board */

extern ulong kerndate;
extern int cflag;
extern ulong jitarenasize;
extern int jitsinglearena;
extern int consoleprint;
extern int main_pool_pcnt;
extern int heap_pool_pcnt;
extern int image_pool_pcnt;

extern char end[];

int
segflush(void *p, ulong l)
{
	/*
	 * flush dcache to PoU + invalidate icache for newly written code.
	 * With MMU/caches off this is belt and braces, but the JIT will
	 * need it once caches are on.
	 */
	uintptr a, e;

	e = (uintptr)p + l;
	for(a = (uintptr)p & ~63UL; a < e; a += 64)
		__asm__ __volatile__("dc cvau, %0" :: "r"(a) : "memory");
	__asm__ __volatile__("dsb ish" ::: "memory");
	for(a = (uintptr)p & ~63UL; a < e; a += 64)
		__asm__ __volatile__("ic ivau, %0" :: "r"(a) : "memory");
	__asm__ __volatile__("dsb ish; isb" ::: "memory");
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
	psci_call(PSCI_SYSTEM_OFF, 0, 0, 0);	/* qemu exits */
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
	uartputs("inferno: early boot\n", 20);
	machinit();
	confinit();
	xinit();
	poolinit();
	poolsizeinit();
	trapinit();
	clockinit();
	printinit();
	quotefmtinstall();	/* %q: sh and the wm window protocol depend on it */
	uartinit();
	screeninit();	/* ramfb, if qemu was given -device ramfb */
	procinit();
	links();
	chandevreset();
	virtiornginit();	/* optional: -device virtio-rng-device */
	virtioinputinit();	/* optional: -device virtio-keyboard-device / virtio-tablet-device */

	/* Dis JIT: one modest xalloc arena (see jitcode in comp-aarch64.c) */
	cflag = 1;
	jitarenasize = 4*1024*1024;
	jitsinglearena = 1;

	eve = strdup("inferno");

	print("\nInferno %s\n", VERSION);
	print("conf %s (%lud) jit %d\n", conffile, kerndate, cflag);
	{
		uvlong v = psci_call(PSCI_VERSION, 0, 0, 0);
		print("psci %lld.%lld\n\n", v>>16, v&0xffff);
	}
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

	/*
	 * These are o.k. because rootinit is null.
	 * Then early kproc's will have a root and dot.
	 */
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
	 * Kernel Stack
	 */
	p->sched.pc = (uintptr)init0;
	p->sched.sp = (uintptr)p->kstack+KSTACK-32;

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
	print("rebooting via psci\n");
	psci_call(PSCI_SYSTEM_RESET, 0, 0, 0);
	/* unreachable unless the conduit is missing */
	print("(reboot: psci failed, spinning)\n");
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
	p->sched.sp = (uintptr)p->kstack+KSTACK-32;

	p->kpfun = func;
	p->arg = arg;
}

void
fpinit(void)
{
	setfcr(0);	/* RN, no traps */
	setfsr(0);
}

ulong
va2pa(void *v)
{
	return (ulong)v;
}

void
idlehands_(void)
{
}
