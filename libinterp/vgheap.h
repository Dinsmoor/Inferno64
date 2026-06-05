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

/* The pool's Bhdr header (magic,size) lives immediately BEFORE B2D == h and is
 * read by the D2B consistency check everywhere (destroy/poolfree/...), in plain
 * mutator context (not inside an MM bracket).  We only MALLOCLIKE the object
 * (from h), so Valgrind treats those header bytes as "before the block" and a
 * D2B read trips -- benignly, since D2B verified MAGIC_A.  Mark the header
 * DEFINED on alloc so D2B reads are clean, WITHOUT un-poisoning any object
 * bytes: a destroy() that reads a genuinely-freed child's ref (offset 0 of the
 * poisoned object) still fires -- that is the real dangling-pointer signal. */
#define VGHEAP_HDR(h)	((void*)((char*)(h) - (ulong)(((Bhdr*)0)->u.data)))
/* h: Heap* just returned by poolalloc(heapmem, sizeof(Heap)+objsize).  Register
 * the block's FULL usable size (poolmsize), not the requested sizeof(Heap)+n:
 * a String/Array's real extent (incl. the C-string null terminator written at
 * s->Sascii[s->len]) runs to the rounded block end, so registering the smaller
 * requested size made those legitimate end-of-object reads/writes look like
 * "N bytes after the block".  The pool block is always >= the object, so a
 * use-after-free of any meaningful object byte is still caught. */
#define VGHEAP_ALLOC(h, n) do { \
		USED(n); \
		VALGRIND_MALLOCLIKE_BLOCK((h), poolmsize(heapmem, (h)), 0, 0); \
		VALGRIND_MAKE_MEM_DEFINED(VGHEAP_HDR(h), (ulong)(((Bhdr*)0)->u.data)); \
	} while(0)

/* h: Heap* about to be returned to the pool via poolfree(heapmem, h) */
#define VGHEAP_FREE(h) \
	VALGRIND_FREELIKE_BLOCK((h), 0)

/*
 * GC-phase awareness.  Inferno is a hybrid refcount + incremental mark-sweep
 * collector, so the memory manager itself legitimately READS freed-but-not-yet-
 * reused memory: the mark phase (markheap) follows pointers into objects the
 * refcount path may already have reclaimed; the refcount free-cascade
 * (freeptrs/destroy) walks a dying subtree; and the pool reads its in-band
 * free-tree node / Btail of neighbouring free blocks while coalescing.  By
 * memory access alone these are indistinguishable from a real dangling-pointer
 * use-after-free -- the ONLY difference is WHO reads: the collector/allocator
 * (legitimate) vs. the mutator (a bug).  So bracket the manager's execution
 * with VG_MM_BEGIN/VG_MM_END: while it runs, freed-memory reads are not
 * reported, but the object stays FREELIKE-poisoned, so a *mutator* read of it
 * (the actual UAF the isptr=0 tptr/tbig slots can cause) is still caught
 * outside the bracket.  This is phase-based, not frame-based: it covers the
 * t->mark callbacks (markheap/markarray/marklist) too, which have their own top
 * frames.  Nestable -- VALGRIND_{DISABLE,ENABLE}_ERROR_REPORTING is a counter.
 */
#define VG_MM_BEGIN	VALGRIND_DISABLE_ERROR_REPORTING
#define VG_MM_END	VALGRIND_ENABLE_ERROR_REPORTING

#else

#define VGHEAP_ALLOC(h, n) do { } while(0)
#define VGHEAP_FREE(h)     do { } while(0)
#define VG_MM_BEGIN        do { } while(0)
#define VG_MM_END          do { } while(0)

#endif /* VALGRIND */

#endif /* VGHEAP_H */
