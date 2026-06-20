/*
 * ffalloc.c -- allocator bridge between FFmpeg and the Inferno emu pool.
 *
 * The problem this solves
 * -----------------------
 * emu defines its OWN global malloc/free/realloc/calloc (emu/port/alloc.c): a
 * pool allocator over a private arena that has nothing to do with libc's heap.
 * FFmpeg's objects call bare libc allocator functions -- specifically
 * posix_memalign() to allocate (av_malloc), and free()/realloc() to release and
 * grow.  At link time those bare references would bind to whatever the link
 * provides.  posix_memalign() is NOT one of emu's symbols, so it resolves to
 * libc and returns libc-heap memory; free()/realloc() DO resolve to emu's pool
 * allocator -- so FFmpeg allocates from libc and frees into emu's pool, which
 * promptly panics ("alloc:D2B ... not in pools") because the pointer was never
 * a pool block.  (Caught exactly there: av_malloc -> posix_memalign [libc] ...
 * av_free -> free [emu pool] -> D2B panic.)
 *
 * The fix
 * -------
 * Route ALL of FFmpeg's allocation through emu's pool, so allocate and free are
 * always paired in the same heap.  buildffmpeg.sh rewrites the three libc
 * allocator symbols FFmpeg references -- posix_memalign, free, realloc -- to the
 * ffshim_* names below (objcopy --redefine-sym, applied to the merged FFmpeg
 * objects only).  Every av_malloc/av_free/av_realloc, and the few bare
 * free()/realloc() calls outside libavutil/mem.c, then land here.
 *
 * Why a wrapper and not just emu's malloc directly: emu's pool only guarantees
 * 8-byte alignment on most hosts (emu/port/alloc.c rounds to 8; only __NetBSD__
 * gets 16), but FFmpeg's av_malloc promises 16-byte alignment (ALIGN in
 * libavutil/mem.c).  So we over-allocate, hand back a 16-aligned pointer, and
 * stash a small header (the real emu-pool base + the payload size) in the words
 * just before it so ffshim_free/ffshim_realloc can recover both.  This is
 * portable to every host emu runs on: it leans only on emu's own malloc/free,
 * never on libc heap internals or dlsym/RTLD_NEXT.
 *
 * This file is plain ISO C (like ffwrap.c) and must NOT include lib9.h.  It
 * declares emu's malloc/free prototypes itself; they are ordinary global C
 * symbols resolved at the emu link.
 */

#include <stddef.h>
#include <string.h>
#include <errno.h>

/* emu's pool allocator (emu/port/alloc.c).  Declared here, not via a header,
 * so this TU stays free of lib9.h -- the same discipline as ffwrap.c. */
extern void *malloc(size_t);
extern void  free(void *);

#define FF_ALIGN 16	/* matches libavutil/mem.c ALIGN for a no-SIMD build */

/*
 * Header carried in front of every returned (aligned) user pointer:
 *
 *     [ emu-pool block .................................................. ]
 *     ^base                       ^hdr        ^user (aligned)
 *
 * `user[-1]` (a Hdr) records the real emu-pool base (to free) and the payload
 * size (so realloc copies exactly min(old,new)).  We over-allocate
 * size + align + sizeof(Hdr) so there is always room to place the Hdr directly
 * before an `align`-aligned user pointer.
 */
typedef struct Hdr Hdr;
struct Hdr {
	void	*base;	/* pointer returned by emu malloc() */
	size_t	size;	/* payload bytes the caller asked for */
};

static void *
ffshim_memalign(size_t align, size_t size)
{
	unsigned char *base, *user;
	size_t need;

	if(align < FF_ALIGN)
		align = FF_ALIGN;
	if(align & (align - 1))		/* not a power of two */
		return NULL;
	if(size == 0)
		size = 1;

	need = size + align + sizeof(Hdr);
	if(need < size)			/* size_t overflow */
		return NULL;
	base = (unsigned char *)malloc(need);
	if(base == NULL)
		return NULL;

	/* leave room for the Hdr, then round the user pointer up to `align` */
	user = base + sizeof(Hdr);
	user = (unsigned char *)(((size_t)user + (align - 1)) & ~(size_t)(align - 1));
	((Hdr *)user)[-1].base = base;
	((Hdr *)user)[-1].size = size;
	return user;
}

int
ffshim_posix_memalign(void **ptr, size_t align, size_t size)
{
	void *p;

	if(align & (align - 1))		/* POSIX: align must be a power of two */
		return EINVAL;
	p = ffshim_memalign(align, size);
	if(p == NULL)
		return ENOMEM;
	*ptr = p;
	return 0;
}

void
ffshim_free(void *p)
{
	if(p == NULL)
		return;
	free(((Hdr *)p)[-1].base);
}

void *
ffshim_realloc(void *p, size_t size)
{
	void *np;
	size_t old;

	if(p == NULL)
		return ffshim_memalign(FF_ALIGN, size);
	if(size == 0){
		ffshim_free(p);
		return NULL;
	}
	np = ffshim_memalign(FF_ALIGN, size);
	if(np == NULL)
		return NULL;			/* old block left intact, per realloc contract */
	old = ((Hdr *)p)[-1].size;
	memcpy(np, p, old < size ? old : size);
	ffshim_free(p);
	return np;
}
