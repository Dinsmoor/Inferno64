#include	<sys/types.h>
#include	<time.h>
#include	<termios.h>
#include	<signal.h>
#include 	<pwd.h>
#include	<grp.h>
#include	<sched.h>
#include	<sys/resource.h>
#include	<sys/wait.h>
#include	<sys/time.h>

#include	<stdint.h>
#include	<unistd.h>
#include	<fcntl.h>
#include	<sys/mman.h>

#include	"dat.h"
#include	"fns.h"
#include	"error.h"
#include	"interp.h"

#include <semaphore.h>

#include	<raise.h>

/* glibc 2.3.3-NTPL messes up getpid() by trying to cache the result, so we'll do it ourselves */
#include	<sys/syscall.h>
#define	getpid()	syscall(SYS_getpid)

enum
{
	DELETE	= 0x7f,
	CTRLC	= 'C'-'@',
	CTRLBS	= '\\'-'@',	/* ^\ : force-quit emu (the old ^C behaviour) */
	NSTACKSPERALLOC = 16,
	X11STACK=	256*1024
};
char *hosttype = "Linux";

typedef sem_t	Sem;

extern int dflag;

/*
 * Memory-ordering barrier used by unlock() (emu/port/lock.c) as the release
 * fence between a critical section's stores and clearing the lock word.
 *
 * aarch64 is weakly ordered, so this MUST be a real barrier: without it the
 * next thread's _tas() can observe the lock free (its own dmb is only an
 * acquire fence) while the writes the lock protected are not yet visible,
 * leaving it to act on stale shared state -- e.g. the pool free-tree root/links
 * (emu/port/alloc.c), which surfaces as rare, flaky, layout-dependent heap
 * corruption.  __sync_synchronize() emits `dmb ish`.  On x86 (TSO) the store
 * ordering unlock needs is free, so nofence remains correct there.
 */
#ifdef LINUX_AARCH64
static void
fencecoherence(void)
{
	__sync_synchronize();
}
void (*coherence)(void) = fencecoherence;
#else
void (*coherence)(void) = nofence;
#endif

int	gidnobody = -1;
int	uidnobody = -1;
static struct 	termios tinit;

/*
 * ------------------------------------------------------------------
 * LP64 observability (see ref/AGENTS_DEBUGGING.md and the lp64 plan).
 *
 * A wide value truncated to 32 bits surfaces as a wild pointer that
 * faults far from its cause, or as a hang.  These routines turn both
 * into something readable: an async-signal-safe Dis backtrace printed
 * to the host's stderr (fd 2), optionally followed by a real core.
 *
 * Everything reachable from a signal handler here is async-signal-safe:
 * only write(2), no malloc/free, no locks, no stdio, no fmt.  Pointers
 * coming off a possibly-corrupt stack are validated with faultprobe()
 * before being dereferenced, and every walk is depth-bounded.
 * ------------------------------------------------------------------
 */

int	faultcrash;		/* EMUCRASH: wild-address fault -> dump + core */
int	faultmonsec;		/* EMUWATCHDOG: hang threshold (s), 0 disables */

static int faultnullfd = -1;	/* writable /dev/null, for faultprobe() */

static char *disstate[] = {	/* must track enum ProgState in interp.h */
	"alt", "send", "recv", "debug", "ready", "release", "exiting", "broken",
};

/* write the whole buffer; safe from a signal handler */
static void
aw(char *s, int n)
{
	long r;

	while(n > 0){
		r = write(2, s, n);
		if(r <= 0)
			break;
		s += r;
		n -= r;
	}
}

static void
aws(char *s)
{
	int n;

	if(s == nil){
		aws("<nil>");
		return;
	}
	for(n = 0; n < 4096 && s[n] != 0; n++)
		;
	aw(s, n);
}

static void
awu(uvlong v)
{
	char b[24];
	int i;

	i = sizeof(b);
	if(v == 0){
		aws("0");
		return;
	}
	while(v != 0 && i > 0){
		b[--i] = '0' + (int)(v % 10);
		v /= 10;
	}
	aw(b + i, sizeof(b) - i);
}

static void
awx(uvlong v)
{
	char b[16];
	int i;

	aws("0x");
	i = sizeof(b);
	if(v == 0){
		aws("0");
		return;
	}
	while(v != 0 && i > 0){
		b[--i] = "0123456789abcdef"[v & 0xf];
		v >>= 4;
	}
	aw(b + i, sizeof(b) - i);
}

/*
 * Is the n-byte range at p readable without faulting?  Ask the kernel by
 * trying to write it to /dev/null: a bad pointer fails with EFAULT rather
 * than crashing us.  Async-signal-safe.  Without /dev/null, fall back to a
 * cheap heuristic and rely on the depth cap.
 */
int
faultprobe(void *p, int n)
{
	if(p == nil)
		return 0;
	if(faultnullfd < 0)
		return (uintptr_t)p >= 4096;
	return write(faultnullfd, p, n) == n;
}

/*
 * Walk a Dis frame chain (REGLINK/REGFP/REGMOD, see struct Frame) emitting
 * module/pc/op per frame.  Mirrors the unwinding in libinterp/xec and
 * exception.c, but takes no locks and validates every pointer first, so it
 * is safe to run from a fault or from an arbitrary thread on USR2.
 */
void
disbacktrace(REG *r)
{
	Frame *f;
	uchar *fp;
	Modlink *m;
	Module *mm;
	Inst *pc;
	int depth;

	if(r == nil || !faultprobe(r, sizeof(REG))){
		aws("\t<no register set>\n");
		return;
	}
	m = r->M;
	pc = r->PC;
	fp = r->FP;
	for(depth = 0; depth < 64; depth++){
		mm = nil;
		if(m != H && faultprobe(m, sizeof(Modlink)))
			mm = m->m;
		aws("\t");
		if(mm != nil && faultprobe(mm, sizeof(Module)) && mm->name != nil)
			aws(mm->name);
		else
			aws("?");
		aws(" pc=");
		if(mm != nil && !m->compiled && pc != nil && m->prog != nil)
			awu((uvlong)(pc - m->prog));
		else
			awx((uvlong)(uintptr_t)pc);
		aws(" op=");
		if(pc != nil && faultprobe(pc, sizeof(Inst)))
			awu((uvlong)pc->op);
		else
			aws("?");
		aws("\n");

		if(fp == nil || !faultprobe(fp, sizeof(Frame)))
			break;
		f = (Frame*)fp;
		pc = f->lr;
		if(f->mr != nil)
			m = f->mr;
		if((uchar*)f->fp == fp)		/* no progress: stop */
			break;
		fp = f->fp;
	}
}

/*
 * Dump every Dis prog: pid, scheduler state, and a backtrace.  The running
 * prog's live registers are in the global R; blocked progs carry their own
 * saved R.  Uses the public progn()/nprog() accessors and bounds the walk so
 * a corrupt run list can't loop us.
 */
void
dumpallprogs(char *why)
{
	Prog *p, *run;
	REG *r;
	int i, n;

	aws("\n=== Dis proc dump");
	if(why != nil){
		aws(" (");
		aws(why);
		aws(")");
	}
	aws(" ===\n");

	run = currun();
	n = nprog();
	if(n < 0 || n > 100000)
		n = 100000;
	for(i = 0; i < n; i++){
		p = progn(i);
		if(p == nil || !faultprobe(p, sizeof(Prog)))
			break;
		aws("prog ");
		awu((uvlong)(ulong)p->pid);
		aws(" [");
		if((int)p->state >= 0 && (int)p->state < 8)
			aws(disstate[p->state]);
		else
			aws("?");
		aws("]\n");
		r = (p == run) ? &R : &p->R;
		disbacktrace(r);
	}
	aws("=== end dump ===\n");
}

/*
 * Hang watchdog.  The scheduler bumps schedprogress every time it runs a
 * prog.  If progress stops advancing while a prog is still on the run queue,
 * a prog entered the interpreter and never returned (a C-level infinite loop
 * or a lock cycle) -- a genuine hang, distinct from a system idle on I/O
 * (run queue empty).  Report it, and in crash mode abort() for a core.
 */
void
faultmon(void *a)
{
	uvlong last, cur;
	int tick, stalled;

	USED(a);

	tick = faultmonsec / 6;		/* sample several times per threshold */
	if(tick < 1)
		tick = 1;
	last = schedprogress;
	stalled = 0;
	for(;;){
		osmillisleep(tick * 1000);
		cur = schedprogress;
		if(cur == last && schedbusy()){
			stalled += tick;
			if(stalled >= faultmonsec){
				iprint("\nHANG: no VM progress for %ds with work queued; "
					"dumping all Dis procs (kill -USR2 %d to repeat)\n",
					stalled, (int)getpid());
				dumpallprogs("hang");
				if(faultcrash)
					abort();	/* core for offline analysis */
				stalled = 0;	/* dumped; keep watching */
			}
		}else
			stalled = 0;
		last = cur;
	}
}

/*
 * On-demand thread dump: kill -USR2 <emu>.  (SIGUSR1 is reserved for
 * unblocking interruptible host I/O, so the dump uses USR2.)  Best-effort:
 * other threads keep running, but every pointer is validated before use.
 */
static void
trapUSR2(int signo)
{
	USED(signo);
	dumpallprogs("SIGUSR2");
}

/*
 * LIMBRUL electric-fence quarantine allocator (debug; Linux host).
 *
 * Routes one pool size class (LIMBRULFENCEMEMSIZE = the rounded pool block size,
 * e.g. 128) through a reserved-VA arena instead of the shared pool: each block
 * gets its own page(s), placed END-flush against a trailing PROT_NONE guard page
 * (a write past the block faults), and on free the block's pages are
 * mprotect(PROT_NONE)'d -- quarantine, so a use-after-free read/write faults
 * SYNCHRONOUSLY at the offending instruction (run under gdb for the writer's
 * stack). Unlike the lazy EMUPOOLPARANOID audit this needs no bit-36 arming: it
 * traps the bad access itself, so a deterministic ASLR-off run suffices.
 * Off unless LIMBRULFENCEMEMSIZE is set; zero behaviour change otherwise.
 */
ulong	poolfencesize;

static struct {
	Lock	l;
	uchar	*lo;
	uchar	*hi;
	uchar	*next;
	long	ps;
} efence;

void
poolfenceinit(void)
{
	char *e;
	uvlong arena;

	e = getenv("LIMBRULFENCEMEMSIZE");
	if(e == nil)
		return;
	poolfencesize = atoi(e);
	if(poolfencesize == 0)
		return;
	efence.ps = sysconf(_SC_PAGESIZE);
	arena = (uvlong)16*1024*1024*1024;		/* 16 GiB reserved VA (PROT_NONE) */
	efence.lo = mmap(nil, arena, PROT_NONE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if(efence.lo == MAP_FAILED){
		print("LIMBRUL: arena reserve failed; fence disabled\n");
		poolfencesize = 0;
		return;
	}
	efence.hi = efence.lo + arena;
	efence.next = efence.lo;
	print("LIMBRUL: electric-fence on size-%lud blocks (arena %#p..%#p)\n",
		poolfencesize, efence.lo, efence.hi);
}

int
poolfenceowns(void *v)
{
	return poolfencesize && (uchar*)v >= efence.lo && (uchar*)v < efence.hi;
}

Bhdr*
poolfencealloc(ulong blocksize)
{
	uchar *base, *guard;
	uvlong datalen, total;
	Bhdr *b;

	datalen = (blocksize + efence.ps - 1) & ~((uvlong)efence.ps - 1);
	total = datalen + efence.ps;			/* + trailing guard page */
	lock(&efence.l);
	if(efence.next + total > efence.hi){		/* arena exhausted */
		unlock(&efence.l);
		return nil;
	}
	base = efence.next;
	efence.next += total;
	unlock(&efence.l);
	if(mprotect(base, datalen, PROT_READ|PROT_WRITE) != 0)
		return nil;
	guard = base + datalen;				/* stays PROT_NONE from the reserve */
	b = (Bhdr*)(guard - blocksize);			/* block END flush to the guard */
	b->magic = MAGIC_A;
	b->size = blocksize;
	B2T(b)->hdr = b;
	return b;
}

void
poolfencefree(Bhdr *b)
{
	uchar *guard, *base;
	uvlong datalen;

	guard = (uchar*)b + b->size;			/* page-aligned (block was flush) */
	datalen = (b->size + efence.ps - 1) & ~((uvlong)efence.ps - 1);
	base = guard - datalen;
	mprotect(base, datalen, PROT_NONE);		/* quarantine: UAF access -> SIGSEGV */
}

/*
 * Wire up the observability features from the environment.  Called from
 * libinit before any Dis runs.
 *   EMUCRASH       wild-address faults dump then drop a core; hang -> abort.
 *                  Off by default in release builds; ON by default in debug
 *                  builds (-DEMU_DEBUG_DEFAULTS), where EMUCRASH=0 opts out.
 *   EMUWATCHDOG=N  hang threshold in seconds (default 60; 0 disables)
 */
static void
faultmoninit(void)
{
	struct sigaction act;
	char *e;

	faultnullfd = open("/dev/null", O_WRONLY);

	e = getenv("EMUCRASH");
	faultcrash = e != nil;
#ifdef EMU_DEBUG_DEFAULTS
	/* debug build: crash-dump + core on by default; EMUCRASH=0 opts out. */
	if(e == nil)
		faultcrash = 1;
	else if(strcmp(e, "0") == 0)
		faultcrash = 0;
#endif

	faultmonsec = 60;
	e = getenv("EMUWATCHDOG");
	if(e != nil)
		faultmonsec = atoi(e);

	e = getenv("EMUPOOLCHECK");	/* free-tree audit cadence (GCs); 0 disables */
	if(e != nil)
		poolcheckfreq = atoi(e);

	e = getenv("EMUPOOLPARANOID");	/* free-tree audit on EVERY alloc/free op */
	if(e != nil)
		poolparanoid = atoi(e);

	poolfenceinit();		/* LIMBRULFENCEMEMSIZE electric-fence (debug) */

	memset(&act, 0, sizeof(act));
	act.sa_handler = trapUSR2;
	sigaction(SIGUSR2, &act, nil);
}

static void
sysfault(char *what, void *addr)
{
	char buf[64];
	char mbuf[128];
	ulong pc;

	pc = modstatus(&R, mbuf, sizeof(mbuf));
	print("LP64 fault: %s%#p in %s pc=%lud op=%d\n", what, addr, mbuf, pc,
		R.PC ? R.PC->op : -1);
	snprint(buf, sizeof(buf), "sys: %s%#p", what, addr);
	disfault(nil, buf);
}

/*
 * Crash-hard path for a wild-address fault under EMUCRASH.  Emit the one-line
 * diagnostic and a full Dis backtrace of every prog, then restore the default
 * disposition and return: the faulting instruction re-executes and the OS
 * drops a core at the exact C site, so `gdb emu core` shows the truncating op
 * handler.  Async-signal-safe (no print/snprint).
 */
static void
syscrash(int signo, char *what, void *addr)
{
	struct sigaction act;

	aws("\nLP64 fault: ");
	aws(what);
	awx((uvlong)(uintptr_t)addr);
	aws("\n");
	dumpallprogs("fault");
	aws("re-raising for core...\n");

	memset(&act, 0, sizeof(act));
	act.sa_handler = SIG_DFL;
	sigaction(signo, &act, nil);
	/* return: faulting instruction re-executes -> core dumped */
}

static void
trapILL(int signo, siginfo_t *si, void *a)
{
	USED(a);
	if(faultcrash)
		syscrash(signo, "illegal instruction pc=", si->si_addr);
	else
		sysfault("illegal instruction pc=", si->si_addr);
}

static int
isnilref(siginfo_t *si)
{
	return si != 0 && (si->si_addr == (void*)~(uintptr_t)0 || (uintptr_t)si->si_addr < 512);
}

static void
trapmemref(int signo, siginfo_t *si, void *a)
{
	USED(a);	/* ucontext_t*, could fetch pc in machine-dependent way */
	if(isnilref(si))
		disfault(nil, exNilref);	/* ordinary Limbo nil deref: stays an exception */
	else if(signo == SIGBUS){
		if(faultcrash)
			syscrash(signo, "bad address addr=", si->si_addr);
		else
			sysfault("bad address addr=", si->si_addr);	/* eg, misaligned */
	}else{
		if(faultcrash)
			syscrash(signo, "segmentation violation addr=", si->si_addr);
		else
			sysfault("segmentation violation addr=", si->si_addr);
	}
}

static void
trapFPE(int signo, siginfo_t *si, void *a)
{
	char buf[64];

	USED(signo);
	USED(a);
	snprint(buf, sizeof(buf), "sys: fp: exception status=%.4lux pc=%#p", getfsr(), si->si_addr);
	disfault(nil, buf);
}

static void
trapUSR1(int signo)
{
	int intwait;

	USED(signo);

	intwait = up->intwait;
	up->intwait = 0;	/* clear it to let proc continue in osleave */

	if(up->type != Interp)		/* Used to unblock pending I/O */
		return;

	if(intwait == 0)		/* Not posted so it's a sync error */
		disfault(nil, Eintr);	/* Should never happen */
}

void
oslongjmp(void *regs, osjmpbuf env, int val)
{
	USED(regs);
	siglongjmp(env, val);
}

static void
termset(void)
{
	struct termios t;

	tcgetattr(0, &t);
	tinit = t;
	t.c_lflag &= ~(ICANON|ECHO|ISIG);
	t.c_cc[VMIN] = 1;
	t.c_cc[VTIME] = 0;
	tcsetattr(0, TCSANOW, &t);
}

static void
termrestore(void)
{
	tcsetattr(0, TCSANOW, &tinit);
}

void
cleanexit(int x)
{
	USED(x);

	if(up->intwait) {
		up->intwait = 0;
		return;
	}

	if(dflag == 0)
		termrestore();

	kill(0, SIGKILL);
	exit(0);
}

void
osreboot(char *file, char **argv)
{
	if(dflag == 0)
		termrestore();
	execvp(file, argv);
	error("reboot failure");
}

/*
 * NSS-free user/group lookups.
 *
 * emu interposes the C malloc/free symbols with its own pool allocator.  That
 * is incompatible with glibc's own allocator (its tcache and _int_malloc/free
 * assume the glibc chunk layout), and the standard getpwXXX/getgrXXX entry
 * points drag that allocator in: getpwnam(3) dlopens NSS service modules
 * (libnss_systemd and friends) that allocate and free across the boundary,
 * which corrupts our pool and crashes during startup.
 *
 * Inferno only needs a login name and the numeric uid/gid for file ownership,
 * so we shadow the lookups with self-contained versions that never touch NSS.
 * Names come from the environment when available; ids come from the kernel via
 * getuid()/getgid().  Host file owners therefore appear as the invoking user
 * or as numeric ids, which is sufficient for hosted Inferno.
 */
static struct passwd*
synth_passwd(const char *name, uid_t uid, gid_t gid)
{
	static struct passwd pw;
	static char namebuf[64];

	if(name == nil || *name == 0){
		name = getenv("USER");
		if(name == nil || *name == 0)
			name = getenv("LOGNAME");
		if(name == nil || *name == 0)
			name = "inferno";
	}
	strncpy(namebuf, name, sizeof(namebuf)-1);
	namebuf[sizeof(namebuf)-1] = 0;
	memset(&pw, 0, sizeof(pw));
	pw.pw_name = namebuf;
	pw.pw_passwd = "";
	pw.pw_uid = uid;
	pw.pw_gid = gid;
	pw.pw_dir = "/";
	pw.pw_shell = "";
	return &pw;
}

struct passwd*
getpwnam(const char *name)
{
	if(name != nil && strcmp(name, "nobody") == 0)
		return nil;	/* leave uidnobody/gidnobody unset, as before */
	return synth_passwd(name, getuid(), getgid());
}

struct passwd*
getpwuid(uid_t uid)
{
	return synth_passwd(nil, uid, getgid());
}

static struct group*
synth_group(const char *name, gid_t gid)
{
	static struct group gr;
	static char gnamebuf[64];
	static char *nomembers[] = { nil };

	if(name == nil || *name == 0)
		name = "inferno";
	strncpy(gnamebuf, name, sizeof(gnamebuf)-1);
	gnamebuf[sizeof(gnamebuf)-1] = 0;
	memset(&gr, 0, sizeof(gr));
	gr.gr_name = gnamebuf;
	gr.gr_passwd = "";
	gr.gr_gid = gid;
	gr.gr_mem = nomembers;
	return &gr;
}

struct group*
getgrgid(gid_t gid)
{
	return synth_group(nil, gid);
}

struct group*
getgrnam(const char *name)
{
	return synth_group(name, getgid());
}

void
libinit(char *imod)
{
	struct sigaction act;
	struct passwd *pw;
	Proc *p;
	char sys[64];

	setsid();

	gethostname(sys, sizeof(sys));
	kstrdup(&ossysname, sys);
	pw = getpwnam("nobody");
	if(pw != nil) {
		uidnobody = pw->pw_uid;
		gidnobody = pw->pw_gid;
	}

	if(dflag == 0) {
		termset();
		/*
		 * ^C is passed through to Inferno as a normal byte, so it is not
		 * a host kill; tell the user the escape hatch (^\, CTRLBS) that
		 * tears emu down from this console.
		 */
		fprint(2, "emu: to shut down, type ^\\ (Ctrl-\\) at this console\n");
	}

	memset(&act, 0, sizeof(act));
	act.sa_handler = trapUSR1;
	sigaction(SIGUSR1, &act, nil);

	act.sa_handler = SIG_IGN;
	sigaction(SIGCHLD, &act, nil);

	/*
	 * For the correct functioning of devcmd in the
	 * face of exiting slaves
	 */
	signal(SIGPIPE, SIG_IGN);
	if(signal(SIGTERM, SIG_IGN) != SIG_IGN)
		signal(SIGTERM, cleanexit);
	if(signal(SIGINT, SIG_IGN) != SIG_IGN)
		signal(SIGINT, cleanexit);

	if(sflag == 0) {
		act.sa_flags = SA_SIGINFO;
		act.sa_sigaction = trapILL;
		sigaction(SIGILL, &act, nil);
		act.sa_sigaction = trapFPE;
		sigaction(SIGFPE, &act, nil);
		act.sa_sigaction = trapmemref;
		sigaction(SIGBUS, &act, nil);
		sigaction(SIGSEGV, &act, nil);
		act.sa_flags &= ~SA_SIGINFO;
	}

	faultmoninit();

	p = newproc();
	kprocinit(p);

	pw = getpwuid(getuid());
	if(pw != nil)
		kstrdup(&eve, pw->pw_name);
	else
		print("cannot getpwuid\n");

	p->env->uid = getuid();
	p->env->gid = getgid();

	emuinit(imod);
}

int
readkbd(void)
{
	int n;
	char buf[1];

	n = read(0, buf, sizeof(buf));
	if(n < 0)
		print("keyboard close (n=%d, %s)\n", n, strerror(errno));
	if(n <= 0)
		pexit("keyboard thread", 0);

	switch(buf[0]) {
	case '\r':
		buf[0] = '\n';
		break;
	case DELETE:
		buf[0] = 'H' - '@';
		break;
	case CTRLBS:
		/* hard kill of the whole emu, the escape hatch that ^C used
		 * to provide. */
		cleanexit(0);
		break;
	/*
	 * ^C is intentionally NOT a hard kill any more: it is passed through
	 * as a normal byte so the interactive shell/line-editor can treat it
	 * like bash does (cancel the current input line).
	 */
	}
	return buf[0];
}

/*
 * Return an abitrary millisecond clock time
 */
long
osmillisec(void)
{
	static long sec0 = 0, usec0;
	struct timeval t;

	if(gettimeofday(&t,(struct timezone*)0)<0)
		return 0;

	if(sec0 == 0) {
		sec0 = t.tv_sec;
		usec0 = t.tv_usec;
	}
	return (t.tv_sec-sec0)*1000+(t.tv_usec-usec0+500)/1000;
}

/*
 * Return the time since the epoch in nanoseconds and microseconds
 * The epoch is defined at 1 Jan 1970
 */
vlong
osnsec(void)
{
	struct timeval t;

	gettimeofday(&t, nil);
	return (vlong)t.tv_sec*1000000000L + t.tv_usec*1000;
}

vlong
osusectime(void)
{
	struct timeval t;
 
	gettimeofday(&t, nil);
	return (vlong)t.tv_sec * 1000000 + t.tv_usec;
}

int
osmillisleep(ulong milsec)
{
	struct  timespec time;

	time.tv_sec = milsec/1000;
	time.tv_nsec= (milsec%1000)*1000000;
	nanosleep(&time, NULL);
	return 0;
}

int
limbosleep(ulong milsec)
{
	return osmillisleep(milsec);
}
