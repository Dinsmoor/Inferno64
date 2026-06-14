#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"ureg.h"
#include	"../port/error.h"

extern void	vectortab(void);	/* the 256 IDT stubs in l.S */
extern void	lidtload(void*);
extern void	clockintr(Ureg*);

typedef struct Handler Handler;
struct Handler {
	void	(*r)(Ureg*, void*);
	void	*a;
	char	name[KNAMELEN];
};

static Handler irqvec[NIRQ];
static Lock veclock;

extern char etext[];

/* ---- IDT ---- */

typedef struct Idtentry Idtentry;
struct Idtentry {
	u16int	offlo;
	u16int	sel;
	u8int	ist;
	u8int	attr;
	u16int	offmid;
	u32int	offhi;
	u32int	zero;
};

static Idtentry idt[256];
static struct {
	u16int	limit;
	u64int	base;
} __attribute__((packed)) idtptr;

static void
idtset(int v, uintptr h)
{
	Idtentry *e;

	e = &idt[v];
	e->offlo = h & 0xFFFF;
	e->sel = SEL_KCODE;
	e->ist = 0;
	e->attr = 0x8E;			/* present, DPL0, 64-bit interrupt gate */
	e->offmid = (h >> 16) & 0xFFFF;
	e->offhi = h >> 32;
	e->zero = 0;
}

void
trapinit(void)
{
	int i;
	uintptr base;

	base = (uintptr)vectortab;
	for(i = 0; i < 256; i++)
		idtset(i, base + i*16);	/* stubs are 16 bytes apart (l.S) */
	idtptr.limit = sizeof(idt) - 1;
	idtptr.base = (u64int)(uintptr)idt;
	lidtload(&idtptr);
}

static char *excname[] = {
	"divide error", "debug", "nmi", "breakpoint",
	"overflow", "bound", "invalid opcode", "device not available",
	"double fault", "coprocessor overrun", "invalid TSS", "segment not present",
	"stack fault", "general protection", "page fault", "reserved",
	"fp exception", "alignment check", "machine check", "simd fp exception",
};

static char*
trapname(int t)
{
	if(t >= 0 && t < nelem(excname))
		return excname[t];
	if(t >= VEC_IRQ0 && t < VEC_IRQ0+NIRQ)
		return "irq";
	return "unknown trap";
}

void
intrenable(int v, void (*f)(Ureg*, void*), void* a, int tbdf, char *name)
{
	Handler *h;

	USED(tbdf);
	if(v < 0 || v >= NIRQ)
		panic("intrenable: irq %d out of range", v);
	ilock(&veclock);
	h = &irqvec[v];
	if(h->r != nil)
		iprint("duplicate irq: %d (%s)\n", v, h->name);
	h->r = f;
	h->a = a;
	strncpy(h->name, name, KNAMELEN-1);
	h->name[KNAMELEN-1] = 0;
	ioapicenable(v, VEC_IRQ0 + v);
	iunlock(&veclock);
}

void
intrdisable(int v, void (*f)(Ureg*, void*), void* a, int tbdf, char *name)
{
	Handler *h;

	USED(tbdf); USED(name);
	if(v < 0 || v >= NIRQ)
		return;
	ilock(&veclock);
	h = &irqvec[v];
	if(h->r == f && h->a == a){
		h->r = nil;
		ioapicdisable(v);
	}
	iunlock(&veclock);
}

void
intrenablemsi(int intid, void (*f)(Ureg*, void*), void* a, char *name)
{
	USED(intid); USED(f); USED(a); USED(name);
	panic("intrenablemsi: PCI MSI not yet supported on amd64");
}

/* called per IOAPIC-delivered IRQ; v is the GSI */
void
dispatchirq(Ureg *ur, int v)
{
	Handler *h;

	if(v < 0 || v >= NIRQ){
		iprint("irq vector %d out of range\n", v);
		return;
	}
	h = &irqvec[v];
	if(h->r != nil)
		h->r(ur, h->a);
	else
		iprint("spurious irq %d\n", v);
}

static uintptr
getcr2(void)
{
	uintptr v;
	__asm__ __volatile__("movq %%cr2, %0" : "=r"(v));
	return v;
}

void
dumpregs(Ureg *ur)
{
	print("TRAP: %s error %#llux\n", trapname((int)ur->type), ur->error);
	print("PC %.16llux SP %.16llux FLAGS %.16llux\n", ur->pc, ur->sp, ur->flags);
	print("AX %.16llux BX %.16llux CX %.16llux DX %.16llux\n", ur->ax, ur->bx, ur->cx, ur->dx);
	print("SI %.16llux DI %.16llux BP %.16llux\n", ur->si, ur->di, ur->bp);
	print("R8 %.16llux R9 %.16llux R10 %.16llux R11 %.16llux\n", ur->r8, ur->r9, ur->r10, ur->r11);
	print("R12 %.16llux R13 %.16llux R14 %.16llux R15 %.16llux\n", ur->r12, ur->r13, ur->r14, ur->r15);
	if((int)ur->type == 14)
		print("CR2 %.16lux\n", getcr2());
	if(up != nil)
		print("up=%p text=%s pc=%#lux\n", up, up->text, up->pc);
}

static void
faultamd64(Ureg *ur)
{
	char buf[ERRMAX];
	uintptr addr;

	addr = getcr2();
	spllo();
	if(addr < BY2PG)
		disfault(ur, "dereference of nil");
	snprint(buf, sizeof(buf), "sys: trap: fault pc=%#llux addr=%#lux",
		ur->pc, addr);
	disfault(ur, buf);
}

void
trap(Ureg *ur)
{
	int v, t;

	v = (int)ur->type;

	if(v == VEC_TIMER){
		t = m->ticks;
		up = nil;
		clockintr(ur);
		lapiceoi();
		up = m->proc;
		preemption(m->ticks - t);
		return;
	}
	if(v >= VEC_IRQ0 && v < VEC_IRQ0+NIRQ){
		t = m->ticks;
		up = nil;
		dispatchirq(ur, v - VEC_IRQ0);
		lapiceoi();
		up = m->proc;
		preemption(m->ticks - t);
		return;
	}
	if(v == VEC_SPURIOUS)
		return;

	if(v == 14){			/* page fault */
		if(up != nil && up->type == Interp){
			faultamd64(ur);
			return;		/* notreached */
		}
	}

	setpanic();
	dumpregs(ur);
	panic("%s pc=%#llux", trapname(v), ur->pc);
}

void
setpanic(void)
{
	spllo();
	consoleprint = 1;
	serwrite = uartputs;
}

int
isvalid_va(void *v)
{
	return (uintptr)v >= KZERO && (uintptr)v < conf.topofmem;
}

void
callwithureg(void (*fn)(Ureg*))
{
	Ureg ureg;

	memset(&ureg, 0, sizeof ureg);
	ureg.pc = getcallerpc(&fn);
	ureg.sp = (uintptr)&fn;
	fn(&ureg);
}

static void
_dumpstack(Ureg *ur)
{
	uintptr *l, *estack, v;

	print("ktrace pc=%#llux sp=%#llux\n", ur->pc, ur->sp);
	l = (uintptr*)ur->sp;
	if(!isvalid_va(l))
		return;
	if(up != nil && (char*)l >= up->kstack && (char*)l < up->kstack+KSTACK)
		estack = (uintptr*)(up->kstack+KSTACK);
	else
		estack = (uintptr*)PGROUND((uintptr)l);
	for(; l < estack; l++){
		v = *l;
		if(v >= KTZERO && v < (uintptr)etext)
			print("  %#lux=%#lux\n", (uintptr)l, v);
	}
}

void
dumpstack(void)
{
	callwithureg(_dumpstack);
}
