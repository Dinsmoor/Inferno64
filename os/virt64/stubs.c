#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

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
 * compile with the VM scheduler released, so other Dis procs keep
 * running during the (CPU-bound) compile — $Loader's compilebg, used
 * by wm/warmup.  Mirrors emu/port/dis.c releasecompile().
 */
int
releasecompile(Module *m, int size, Modlink *ml)
{
	int r;

	release();
	if(waserror()){
		qunlock(&jitlock);
		acquire();
		return 0;
	}
	qlock(&jitlock);
	r = compile(m, size, ml);
	qunlock(&jitlock);
	poperror();
	acquire();
	return r;
}

/*
 * /dev/random: overrides the weak hook in port/random.c — virtio-rng
 * entropy when the device answers, else 0 so the (glacial) jitter
 * pool takes over.  Without this, /dev/random readers (e.g. lib
 * Random seeding the games' Rand) hang ~forever under qemu.
 */
int
hwrandomread(void *buf, ulong n)
{
	return virtiorngread(buf, n);
}

/*
 * /dev/notquiterandom + libsec's generator (signature per libsec.h —
 * mprand calls through a void(*)(uchar*,int) pointer): virtio-rng when
 * present (rng.c), else a weak xorshift PRNG.  The fallback is NOT
 * cryptographically secure; boot with `-device virtio-rng-device`.
 * Replaces libsec/port/genrandom.c (X9.17 over DES3) — real device
 * entropy beats a PRNG seeded from truerand's jitter pool.
 */
void
genrandom(uchar *buf, int n)
{
	static uvlong state;
	uvlong x;
	int i, got;
	uvlong rdcntvct(void);

	if(n <= 0)
		return;
	got = virtiorngread(buf, n);
	if(got >= n)
		return;
	if(got < 0)
		got = 0;

	if(state == 0){
		/* one-time seed: device entropy if any came through, else the counter */
		x = rdcntvct();
		if(got > 0)
			memmove(&x, buf, got > sizeof(x) ? (int)sizeof(x) : got);
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
}

/* (rand() for libsec's prng.c comes from devcons.c) */

/*
 * access(2) for the in-kernel libdraw (subfontname.c probes font
 * files with it): a kernel has no syscalls, so probe via kopen.
 */
extern int libopen(char*, int);
extern int libclose(int);

int
access(char *name, int mode)
{
	int fd;

	USED(mode);	/* AREAD/AEXIST both reduce to "can we open it" */
	fd = libopen(name, OREAD);
	if(fd < 0)
		return -1;
	libclose(fd);
	return 0;
}
