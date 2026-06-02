/*
 * vgheap.h — optional Valgrind/Memcheck instrumentation of the Dis heap.
 *
 * The Dis garbage-collected heap lives inside emu's own pool allocator
 * (emu/port/alloc.c).  To Valgrind that pool is a handful of giant mmap'd
 * superblocks, so every Dis object is "one allocation" and a use-after-free of
 * a collected object — e.g. a dangling pointer left in an isptr=0 (untraced)
 * slot — is invisible.  This header teaches Memcheck about object granularity:
 * each Dis object is reported as a MALLOCLIKE block when allocated and a
 * FREELIKE block when the GC (or refcount) reclaims it.  After a FREELIKE the
 * object's bytes are poisoned NOACCESS, so reading a reclaimed object becomes
 * an immediate "Invalid read ... block was freed by <stack>" with BOTH the
 * allocation and the free/GC stacks — exactly the tool for confirming and
 * locating a GC dangling-pointer / use-after-free.
 *
 * This is OFF unless the runtime is built with -DVALGRIND (and valgrind's
 * headers are installed).  When off, the macros vanish to nothing, so the
 * production allocator is byte-for-byte unchanged.  Enable per the recipe in
 * ref/AGENTS_DEBUGGING.md ("Sanitizer builds").
 *
 * Granularity note: the block is registered at the Heap* (header + object), so
 * accesses to H2D(h) (the object, where Dis pointers point) are in-range while
 * live and out-of-range once freed.  Redzones are 0 because the pool packs
 * blocks adjacently; this catches use-after-free and uninitialised reads, not
 * adjacent-block overruns.  Pool block coalescing can occasionally make
 * Memcheck's view of a reused region approximate — acceptable for a clear UAF.
 */
#ifndef VGHEAP_H
#define VGHEAP_H

#ifdef VALGRIND

#include <valgrind/memcheck.h>

/* h: Heap* just returned by poolalloc(heapmem, sizeof(Heap)+objsize)
 * n: the object size (bytes after the Heap header) */
#define VGHEAP_ALLOC(h, n) \
	VALGRIND_MALLOCLIKE_BLOCK((h), sizeof(Heap) + (ulong)(n), 0, 0)

/* h: Heap* about to be returned to the pool via poolfree(heapmem, h) */
#define VGHEAP_FREE(h) \
	VALGRIND_FREELIKE_BLOCK((h), 0)

#else

#define VGHEAP_ALLOC(h, n) do { } while(0)
#define VGHEAP_FREE(h)     do { } while(0)

#endif /* VALGRIND */

#endif /* VGHEAP_H */
