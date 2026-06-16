/*
 * disptr.h -- Dis / userspace address-space tagging for sparse.
 *
 * The hosted emu runs every Dis proc in ONE host address space over ONE shared
 * Dis heap.  There is no hardware boundary between a Limbo app and the C kernel
 * that serves it, so an address the kernel obtains from VM-controlled data -- a
 * debugger /prog heap query, a Styx read/write offset, a frame slot reachable
 * from userspace -- is NOT a trusted host pointer.  Dereferencing such an
 * address directly is the mechanism by which a userspace logic error reaches
 * across and corrupts shared kernel state (the class behind the LP64 heap
 * corruptions).  C's type system cannot see the distinction: a trusted host
 * pointer and an untrusted VM-supplied address are both just `void *`.
 *
 * __dis makes the distinction visible to sparse.  Under __CHECKER__ it is a
 * distinct address space marked `noderef`, so sparse reports:
 *
 *   * a direct dereference of a __dis pointer        -> "dereference of noderef expression"
 *   * mixing a __dis pointer with a host pointer      -> "different address spaces"
 *
 * The only sanctioned way to turn a __dis address into a host pointer is the
 * audited choke point disptr() (validate, then launder).  Every such laundering
 * is then grep-able and reviewable, and any NEW unvalidated use fails `make
 * sparse`.  This mirrors Linux's __user / sparse address-space model.
 *
 * Outside sparse the tags expand to nothing: zero representation or codegen
 * change.  Apply __dis incrementally at the trust boundaries (see
 * docs/ON_SPARSE.md); the VM core, which legitimately owns Dis memory, stays
 * untagged.
 */
#ifndef _DISPTR_H_
#define _DISPTR_H_

#ifdef __CHECKER__
#define __dis     __attribute__((noderef, address_space(__dis)))
#define __dforce  __attribute__((force))
#else
#define __dis
#define __dforce
#endif

/*
 * disptr -- the single sanctioned boundary where a Dis/userspace address (a)
 * becomes a trusted host pointer.  `ok` must be the caller's prior bounds /
 * validity check on a; this function only documents and launders the cast so
 * sparse stops flagging it.  Returns nil if the address was rejected.
 *
 * Usage:
 *      void __dis *a = hq->addr;            // tagged at the boundary
 *      if(!disok(a, n)) error(Ebadctl);     // validate first
 *      WORD *w = disptr(a);                 // launder; sparse-clean
 */
static __inline void *
disptr(void __dis *a)
{
	return (void __dforce *)a;
}

#endif /* _DISPTR_H_ */
