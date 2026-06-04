# tests/cunit — C unit tests for Inferno's host libraries

Unit tests for the C code in the host libraries (`lib9`, `libbio`, `libmp`,
`libsec`, `libmath`, …), focused on the routines the LP64 port touched, where a
32/64-bit width mistake silently corrupts a value instead of failing to compile.

## Running

    make test_lib9_unit        # one section
    make test_libmp_unit
    make test_all_unit         # every section with a tests/cunit/<section>/ dir

Build the C side first (`make emu` or `make all`) so the static libs the tests
link against exist under `$(OBJDIR)/lib`.

A run prints one line per test file, e.g. `PASS ALLPASS lib9/fmt (22 checks)`;
the target exits non-zero if any test fails to build, run, or pass.

## Dual-ABI

This tree targets both the 64-bit (LP64) and 32-bit (ILP32) Dis ABIs, and the
tests must pass under either. The runner (`run.sh`) derives the compiler and the
`-DLINUX_<ARCH>` define from the active arch's mk file
(`mkfiles/mkfile-$SYSTARG-$OBJTYPE`), so tests compile exactly as the libraries
did — never hardcode a compiler, `-m32/-m64`, or platform define in a test.
Run for another ABI with e.g. `make test_lib9_unit OBJTYPE=386` (that arch's
tree must be built first).

Assertions must not assume a width that varies between ABIs (see the header
comment in `cunit.h`):
- `vlong`/`uvlong` are 64-bit on **both** ABIs — assert their full 64-bit
  behaviour unconditionally; this is where the interesting bugs live.
- `long`/`ulong`/`uintptr`/pointers are 64-bit on LP64, 32-bit on ILP32 — gate
  width-specific expectations on `sizeof(ulong) >= 8`, or compare against the
  value itself (e.g. round-trip through the code under test) rather than a
  hardcoded width-dependent string.

## Adding a test

1. Create `tests/cunit/<section>/test_<thing>.c`. A *section* maps to a library;
   `run.sh` links the test against `lib<section>.a` (+ its dependency libs).
2. Include the library header(s) first, then `cunit.h`:

   ```c
   #include "lib9.h"
   #include "cunit.h"

   static void test_foo(void){ CKEQ(foo(2), 4); }

   CUNIT_MAIN("section/foo", test_foo)
   ```

3. Check macros: `CK(cond)`, `CKEQ(got,want)` (signed), `CKEQX` (hex/unsigned),
   `CKSTR`, `CKMEM(a,b,n)`. End with `CUNIT_MAIN("name", fn, ...)`.
4. Compute expected values **independently** of the function under test (known
   vectors, hand-computed results), so the test can actually catch a bug.

`shim.c` provides host versions of kernel/emu hooks that the libraries call but
lib9 doesn't define (`mallocz`, `NaN`/`Inf`, `_assert`, `_tas`, and a
malloc-backed image pool for libmemdraw); it is linked into every test. Build
artifacts go in each section's `.out/` (git-ignored).

## Testing VM/loader internals

Some of the highest-LP64-risk C lives inside the Dis VM (libinterp) as
file-local `static` functions in objects that drag the whole runtime if linked.
To unit-test such a function, **extract it** into a small dependency-free
compilation unit and declare it in the library's header, so a test can link
just that object. Example: `operand`/`disw`/`canontod` were moved from
`libinterp/load.c` into `libinterp/disops.c` (declared in `interp.h`), which is
pure code motion — emu still builds and links unchanged — and is now covered by
`libinterp/disops`. Functions that genuinely need a live heap/module/display
runtime stay covered by the integration suites (`tests/lp64`, `gui_sweep.sh`).

## Coverage

8 sections: lib9 (fmt, str, runestr, utf, getfields, b64, numconv, fcall),
libbio, libmp (conv, arith, shift), libsec (digest, cipher), libmath, libdraw
(geom, chan), libmemdraw, libinterp (disops). LP64 bugs caught + fixed so far:
`lib9/strtoull` (base-16 overflow clamp) and `libmp/mptov` (64-bit truncation).
