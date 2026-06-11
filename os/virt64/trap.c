#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"ureg.h"
#include	"../port/error.h"

typedef struct Handler Handler;
struct Handler {
	void	(*r)(Ureg*, void*);
	void	*a;
	char	name[KNAMELEN];
};

static Handler irqvec[NIRQ];
static Lock veclock;

extern char etext[];

static char *trapnames[] = {
	"synchronous exception",
	"irq",
	"fiq",
	"serror",
	"exception from lower EL (sync)",
	"exception from lower EL (irq)",
	"exception from lower EL (fiq)",
	"exception from lower EL (serror)",
	"exception with SP_EL0 (sync)",
	"exception with SP_EL0 (irq)",
	"exception with SP_EL0 (fiq)",
	"exception with SP_EL0 (serror)",
};

static char*
trapname(int t)
{
	if(t < 0 || t >= nelem(trapnames))
		return "unknown trap";
	return trapnames[t];
}

static void
gicenable(int irq)
{
	IOREG32(GICD_PHYS, GICD_ISENABLER + 4*(irq/32)) = 1u << (irq%32);
}

static void
gicdisable(int irq)
{
	IOREG32(GICD_PHYS, GICD_ICENABLER + 4*(irq/32)) = 1u << (irq%32);
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
	gicenable(v);
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
		gicdisable(v);
	}
	iunlock(&veclock);
}

void
trapinit(void)
{
	int i;

	/* distributor: everything off, route to cpu0, lowest priority threshold */
	IOREG32(GICD_PHYS, GICD_CTLR) = 0;
	for(i = 0; i < NIRQ; i += 32){
		IOREG32(GICD_PHYS, GICD_ICENABLER + 4*(i/32)) = ~0u;
		IOREG32(GICD_PHYS, GICD_ICPENDR + 4*(i/32)) = ~0u;
	}
	for(i = 0; i < NIRQ; i += 4){
		IOREG32(GICD_PHYS, GICD_IPRIORITYR + i) = 0xa0a0a0a0;
		if(i >= 32)
			IOREG32(GICD_PHYS, GICD_ITARGETSR + i) = 0x01010101;
	}
	IOREG32(GICD_PHYS, GICD_CTLR) = 1;

	/* cpu interface */
	IOREG32(GICC_PHYS, GICC_PMR) = 0xff;
	IOREG32(GICC_PHYS, GICC_CTLR) = 1;
}

static void
irq(Ureg *ur)
{
	u32int iar, v;
	Handler *h;

	for(;;){
		iar = IOREG32(GICC_PHYS, GICC_IAR);
		v = iar & 0x3ff;
		if(v == GICSPURIOUS)
			break;
		h = &irqvec[v];
		if(h->r != nil)
			h->r(ur, h->a);
		else
			iprint("spurious irq %ud\n", v);
		IOREG32(GICC_PHYS, GICC_EOIR) = iar;
	}
}

void
dumpregs(Ureg *ur)
{
	int i;

	print("TRAP: %s\n", trapname(ur->type));
	print("ESR %.8llux FAR %.16llux PSR %.8llux\n", ur->esr, ur->far, ur->psr);
	print("PC %.16llux SP %.16llux LR %.16llux\n", ur->pc, ur->sp, ur->r[30]);
	for(i = 0; i < 30; i += 3)
		print("R%-2d %.16llux R%-2d %.16llux R%-2d %.16llux\n",
			i, ur->r[i], i+1, ur->r[i+1], i+2, ur->r[i+2]);
	if(up != nil)
		print("up=%p text=%s pc=%#lux\n", up, up->text, up->pc);
}

static void
faultarm64(Ureg *ur)
{
	char buf[ERRMAX];

	spllo();
	if(ur->far < BY2PG)
		disfault(ur, "dereference of nil");
	snprint(buf, sizeof(buf), "sys: trap: fault pc=%#llux addr=%#llux esr=%#llux",
		ur->pc, ur->far, ur->esr);
	disfault(ur, buf);
}

void
trap(Ureg *ur)
{
	int t, ec;

	switch((int)ur->type){
	case 1:		/* irq */
		t = m->ticks;
		up = nil;	/* no process at interrupt level */
		irq(ur);
		up = m->proc;
		preemption(m->ticks - t);
		break;

	case 0:		/* synchronous */
		ec = (ur->esr >> 26) & 0x3f;
		switch(ec){
		case 0x20: case 0x21:	/* instruction abort */
		case 0x24: case 0x25:	/* data abort */
			if(up != nil && up->type == Interp){
				faultarm64(ur);
				/* notreached */
			}
			break;
		}
		/* fall through to panic */
	default:
		setpanic();
		dumpregs(ur);
		panic("%s pc=%#llux", trapname(ur->type), ur->pc);
	}

	splhi();
	if(up)
		up->dbgreg = 0;
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

/*
 * Fill in enough of Ureg to get a stack trace, and call a function.
 */
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
