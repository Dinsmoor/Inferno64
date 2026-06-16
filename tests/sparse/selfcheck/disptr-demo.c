/*
 * disptr-demo.c -- self-check for the __dis address-space gate (include/disptr.h).
 *
 * tests/sparse/selfcheck.sh runs sparse over this file and asserts that the
 * BAD functions WARN and the GOOD ones do not.  If sparse or the annotation
 * ever stops catching an unvalidated userspace-address use, this check fails --
 * so the gate that protects the kernel from userspace is itself tested.
 *
 * Not part of any build; sparse-only.
 */
#include "disptr.h"

/* BAD: dereference a Dis/userspace-supplied address directly.
 * Expect sparse: "dereference of noderef expression". */
int deref_bad(int __dis *a);
int
deref_bad(int __dis *a)
{
	return *a;
}

/* BAD: leak a __dis pointer out as a trusted host pointer.
 * Expect sparse: "different address spaces". */
int *escape_bad(int __dis *a);
int *
escape_bad(int __dis *a)
{
	return a;
}

/* GOOD: launder through the audited choke point, then use.
 * Expect sparse: clean. */
int deref_good(int __dis *a);
int
deref_good(int __dis *a)
{
	int *w = disptr(a);
	return *w;
}
