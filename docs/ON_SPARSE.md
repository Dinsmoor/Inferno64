# Static analysis with sparse — the LP64 pointer / Dis-address-space gate

`make sparse` runs Linus Torvalds' [sparse](https://sparse.docs.kernel.org/)
over the emu/libinterp C with the *real* per-file compile flags, looking for two
bug classes that the normal compiler and `make lint` do not catch:

1. **Pointer↔WORD truncation in *cast* form.** Inferno64 is LP64: a host pointer
   is 8 bytes (`IBY2PTR`), a Dis `WORD` is 4 (`IBY2WD`). `make lint`'s
   `-Wshorten-64-to-32` catches implicit narrowing, but an *explicit*
   `(uint32_t)ptr` or a 32-bit field that stores an address is invisible to it.
   sparse's `-Wcast-truncate` and "non size-preserving pointer to integer cast"
   flag exactly these — the class behind the LP64 heap corruptions
   (`docs/ON_C_IN_DIS.md`).

2. **Dis / userspace addresses used as trusted host pointers** — see `__dis`
   below.

This is the compile-time complement to the runtime guards (DISPTRCHECK,
verifytype, the pool free-tree audit). Use it the same way as `make lint`: it is
a baseline-diff gate, green by default, that fails only on *new* warnings.

## Running it

```
make sparse          # report NEW width / address-space warnings vs baseline
make sparse-all      # every high-signal warning (triage view)
make sparse-update   # regenerate tests/sparse/baseline.txt after triaging
make sparse-raw      # raw sparse output, unfiltered (debugging the harness)
```

The first run builds sparse from kernel.org into `tests/sparse/.sparse/` — no
system install, no root. The binary is cached there afterwards.

The harness (`tests/sparse/run.sh`) mirrors `tests/lint/run.sh`: it replays
`mk -n` to recover each file's exact gcc flags, swaps the compiler for sparse,
and keeps only the high-signal lines (`non size-preserving`, `truncates bits`,
`different address space`). glibc's aarch64 SVE/Neon vector typedefs are
neutralized with `-D__Float32x4_t=int …` (we never call vector math); without
that, sparse cannot parse `<math.h>`.

### The baseline

`tests/sparse/baseline.txt` holds the warnings that are *known and accepted*.
Today that is the `(WORD)` truncations in `devprog.c modstatus` — `/prog`
returns module status as 32-bit text fields for ABI compatibility with the
debugger's parser; widening them is a coordinated format change, tracked in
`docs/DEV_INPRO.md`, not a silent fix. Anything not in the baseline fails the
gate. When you intentionally accept a new warning, run `make sparse-update` and
commit the baseline diff with the justification in the commit message.

## The `__dis` address-space tag

`include/disptr.h` defines `__dis`, an address-space annotation modelled on the
Linux kernel's `__user`. The hosted emu runs every Dis proc in one host address
space over one shared Dis heap; there is no hardware boundary between a Limbo
app and the C kernel that serves it. So an address the kernel obtains from
VM-controlled data — a `/prog` heap query, a Styx offset, a frame slot reachable
from userspace — is **not** a trusted host pointer. Dereferencing it directly is
the mechanism by which a userspace logic error reaches across and corrupts
shared kernel state. C's type system cannot see the difference: both are
`void *`.

Tag the untrusted side `__dis` and sparse reports:

| pattern | sparse says |
|---|---|
| direct `*p` of a `__dis` pointer | `dereference of noderef expression` |
| mixing a `__dis` pointer with a host pointer | `different address spaces` |

The only sanctioned way to turn a `__dis` address into a host pointer is the
audited choke point `disptr()` — *validate, then launder*:

```c
void __dis *a = hq->addr;          /* tagged at the boundary       */
if(!disok(a, n)) error(Ebadctl);   /* bounds/validity check first  */
WORD *w = disptr(a);               /* launder; now sparse-clean    */
```

Every laundering is grep-able and reviewable, and any *new* unvalidated use
fails `make sparse`. Outside sparse the tags expand to nothing — zero
representation or codegen change. Apply `__dis` incrementally at trust
boundaries; the VM core, which legitimately owns Dis memory, stays untagged.

`tests/sparse/selfcheck.sh` proves the gate works: it runs sparse over
`selfcheck/disptr-demo.c` and asserts the bad patterns warn and the laundered
one does not. If the annotation ever stops catching an unvalidated use, the
self-check fails.

## Worked example: hardening `/prog` heap reads

`progheap` (`emu/port/devprog.c`) reads Dis memory at an address the debugger
supplies as text (`addr.fmt`). The address is integer-carried (`ulong`), so the
runtime analogue of `__dis` applies: `disok(p, len)` checks that the whole span
about to be read lies inside one of the Dis pools (`heapmem`/`mainmem`/
`imagmem`), using the same `ptrinpool()` membership test as DISPTRCHECK. A wild,
truncated, or small-integer address fails the check and the read returns
`Ebadctl` instead of faulting the emu. A userspace debugger bug can no longer
take down anything but its own query. `disreadlen()` gives the per-format read
width; the module-relative `'I'` format is validated by its module lookup
instead and is exempt.

## Why not catch everything statically?

The Dis heap is dynamically typed: a slot's pointer-ness lives in the runtime
`Type->map`, invisible to C's static types. Corruption is valid, in-bounds C, so
ASan/Valgrind are blind to it too, and the corrupter is non-local to the victim.
sparse closes the part that *is* statically visible — the width casts and the
trust-boundary dereferences — and `__dis` makes the boundary explicit so the
checker can see it. The rest stays the job of the runtime guards. This is the
same division of labour Linux uses: explicit-width types + sparse for what the
types can express, KASAN/syzkaller for the dynamic remainder.
