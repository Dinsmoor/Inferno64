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
 * Here it draws from xalloc: all RAM is below 2GB on qemu -M virt, so
 * the JIT's low-address requirement (32-bit jump-table slots) is free.
 * Returning MAP_FAILED on exhaustion makes compile() fall back to the
 * interpreter instead of panicking.
 */
void*
mmap(void *addr, unsigned long len, int prot, int flags, int fd, long off)
{
	uchar *p;

	USED(addr); USED(prot); USED(flags); USED(fd); USED(off);
	p = xallocz(len + 64, 0);
	if(p == nil)
		return (void*)-1;
	return (void*)(((uintptr)p + 63) & ~63UL);
}

int
munmap(void *addr, unsigned long len)
{
	/*
	 * only reachable from jitcode()'s landed-too-high path, which
	 * cannot happen with sub-2GB RAM; leak by design (the aligned
	 * pointer can't go back to xfree anyway).
	 */
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
 * /dev/notquiterandom: virtio-rng when present (rng.c), else a weak
 * xorshift PRNG.  The fallback is NOT cryptographically secure; boot
 * with `-device virtio-rng-device` for real entropy.
 */
ulong
genrandom(uchar *buf, ulong n)
{
	static uvlong state;
	uvlong x;
	ulong i;
	int got;
	uvlong rdcntvct(void);

	got = virtiorngread(buf, n);
	if(got >= n)
		return n;

	if(state == 0){
		/* one-time seed: device entropy if any came through, else the counter */
		x = rdcntvct();
		if(got > 0)
			memmove(&x, buf, got > sizeof(x) ? sizeof(x) : got);
		state = x | 1;
	}
	x = state;
	for(i = got; i < n; i++){
		x ^= x << 13;
		x ^= x >> 7;
		x ^= x << 17;
		buf[i] = x ^ (x >> 32);
	}
	state = x;
	return n;
}
