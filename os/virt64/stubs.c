#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

/*
 * no devmnt in the minimal configuration
 */
void
muxclose(Mnt *m)
{
	USED(m);
}

Chan*
mntauth(Chan *c, char *spec)
{
	USED(c); USED(spec);
	error(Enodev);
	return nil;
}

long
mntversion(Chan *c, char *v, int msize, int returnlen)
{
	USED(c); USED(v); USED(msize); USED(returnlen);
	error(Enodev);
	return 0;
}

/* (memcpy comes from libkern/memmove.c, which defines both) */

#include "interp.h"

/*
 * module signing: not enforced on this kernel (no keyset devices yet)
 */
int
mustbesigned(char *path, uchar *code, ulong length, Dir *dir)
{
	USED(path); USED(code); USED(length); USED(dir);
	return 0;
}

int
verifysigner(uchar *sign, int len, uchar *data, ulong ndata)
{
	USED(sign); USED(len); USED(data); USED(ndata);
	return 1;
}

/*
 * pool integrity audit (emu/port/alloc.c has the real one; os/port's
 * allocator predates it).  No-op until ported.
 */
int poolcheckfreq = 0;
void
poolcheck(void)
{
}

/*
 * no DLMs in the native kernel
 */
Module*
newdyncode(int fd, char *path, Dir *dir)
{
	USED(fd); USED(path); USED(dir);
	error("dynamic modules not supported");
	return nil;
}

void
newdyndata(Modlink *ml)
{
	USED(ml);
}

void
freedyncode(Module *m)
{
	USED(m);
}

void
freedyndata(Modlink *ml)
{
	USED(ml);
}

/*
 * The aarch64 JIT allocates its code arena with mmap on the hosted emu.
 * Always fail here: the kernel runs interpreted (cflag=0); a real JIT
 * arena can come from xspanalloc when the JIT is brought up natively.
 */
void*
mmap(void *addr, unsigned long len, int prot, int flags, int fd, long off)
{
	USED(addr); USED(len); USED(prot); USED(flags); USED(fd); USED(off);
	return (void*)-1;
}

int
munmap(void *addr, unsigned long len)
{
	USED(addr); USED(len);
	return 0;
}

/*
 * serialized compile() (see emu/port/dis.c) — the JIT compiler is not
 * reentrant.  Kept even though cflag=0 so devprog's compile ctl works
 * if anyone flips it on.
 */
static QLock jitlock;

int
lockedcompile(Module *m, int size, Modlink *ml)
{
	int r;

	qlock(&jitlock);
	if(waserror()){
		qunlock(&jitlock);
		nexterror();
	}
	r = compile(m, size, ml);
	poperror();
	qunlock(&jitlock);
	return r;
}

/*
 * weak PRNG for /dev/random until a real entropy source is wired up
 * (virtio-rng is the obvious candidate).  NOT cryptographically secure.
 */
ulong
genrandom(uchar *buf, ulong n)
{
	static uvlong state;
	uvlong x;
	ulong i;
	uvlong rdcntvct(void);

	if(state == 0)
		state = rdcntvct() | 1;
	x = state;
	for(i = 0; i < n; i++){
		x ^= x << 13;
		x ^= x >> 7;
		x ^= x << 17;
		buf[i] = x ^ (x >> 32);
	}
	state = x;
	return n;
}
