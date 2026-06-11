# So you want to write C in the Inferno codebase?

> *So you want to write C in the Inferno codebase?* This is the reference — the
> dialect, the types, the error model, and where everything lives.

Most of Inferno is Limbo, but the emulator, the kernel, the device drivers, and the
built-in modules are C — and it is **not** the C you write everywhere else. It's
Plan 9 C: a slightly different dialect, its own type names, its own error-handling
mechanism, and its own conventions. This document gets you oriented so you don't
fight the house style.

Two boundaries to set first:

- If you're writing C that **touches the Dis VM** — builtins, the heap/GC, anything
  that handles a Limbo value or a Dis word — the integer-width rules there are
  load-bearing and have their own doc: **`ON_C_IN_DIS.md`**. Read it before you
  store a pointer anywhere near a Dis slot.
- For the *architecture* of the pieces (how the emulator and kernel are put
  together, devices, scheduling) see **`ON_EMU.md`** and **`ON_KERNEL.md`**; for
  bringing the emulator up on a new host see **`ON_PORTING.md`**.

This doc is the connective tissue: the C *dialect and conventions* common to all of
them.

## It's Plan 9 C, not ANSI-idiomatic C

The code is compiled by the host `gcc`, but it is written in the Plan 9 style and
leans on the `lib9` compatibility layer (`include/lib9.h` per host). Practical
consequences:

- **`nil`, not `NULL`.** `nil` is `((void*)0)` (`lib9.h`).
- **Short integer names.** Use the `lib9` typedefs rather than `<stdint.h>`:

  | name | meaning |
  |---|---|
  | `uchar`, `schar` | 8-bit unsigned / signed |
  | `u8int`, `u16int`, `u32int`, `u64int` | explicit fixed-width unsigned |
  | `vlong`, `uvlong` | 64-bit signed / unsigned ("very long") |
  | `Rune` | a Unicode code point (32-bit) |
  | `uintptr` | **pointer-width** unsigned integer (64-bit on a 64-bit host) |

  The last one matters: `uintptr` is the type to use when you need an integer that
  can *hold a pointer*. Do not reach for `int`/`u32int` for that — see
  `ON_C_IN_DIS.md` for why truncating a pointer is the central hazard.
- **House macros** (`lib9.h`): `USED(x)` (silence an unused-variable warning without
  pretending to use it), `SET(x)` (tell the compiler a variable is set on all paths),
  `nelem(x)` (array length), `offsetof`.
- **Strings are UTF-8 / `Rune`.** Text is UTF-8 byte strings; decode to `Rune` with
  the `chartorune`/`runetochar` family. `print`/`fprint`/`sprint` are the Plan 9
  formatted-output family (with `%r` for the last system error and the runtime's own
  verbs), not C `stdio`. Prefer `snprint`/`seprint` for bounded output.

## The error model: `error()` / `waserror()` / `nexterror()`

This is the single most important convention to get right, because it changes how
control flows through your function. Inferno C does **not** thread error codes back
by hand; it uses a `setjmp`/`longjmp` exception stack on the current process
(`up->estack`):

```c
if(waserror()){          /* sets a recovery point; returns non-zero when error() longjmps here */
    cleanup();           /* runs on the error path */
    nexterror();         /* re-raise to the next handler out */
}
... code that may call error("message") ...
poperror();              /* SUCCESS path: pop the recovery point you pushed */
```

- `error(char*)` raises: it `longjmp`s to the most recently pushed `waserror()`.
- `waserror()` pushes a recovery point and evaluates to 0 normally, non-zero when an
  `error()` unwinds into it.
- `poperror()` removes the recovery point on the **success** path — every
  `waserror()` you push must be balanced by exactly one `poperror()` or one
  `nexterror()`.
- `nexterror()` re-raises to the next handler further out.

The trap to internalize: because `error()` is a `longjmp`, **any code between your
`waserror()` and the `error()` call that acquires a lock, opens a file, or
allocates must release it on the error path** — the `longjmp` skips straight over
your normal cleanup. Forgetting a `poperror()` (or doing real work after it that can
itself `error()`) corrupts the exception stack. This is the C-side half of Inferno's
two-layer error story; the Limbo side (`raise`/`exception`) and why the two are
bridged awkwardly is in **`ON_LIMBO_ERROR_HANDLING.md`**.

## Memory

- `malloc`/`free` are the `lib9` versions; freed memory is the caller's to track.
  The house discipline is **free-and-nil**: `free(p); p = nil;` so a stale pointer
  can't be reused.
- `smalloc` is "malloc that waits" — it blocks until the allocation can be
  satisfied rather than returning `nil`, and is the kernel-side default where a
  failure isn't an option.
- `mallocz(n, 1)` allocates zeroed memory.
- Allocation failures in the `malloc` family raise via `error()` in the contexts
  that set that up, so pair allocations with `waserror()`/`poperror()` when you hold
  other resources.

The Dis heap is **separate** and garbage-collected — do not `free()` a Dis value or
confuse the two allocators. That boundary, and the GC pointer maps, are in
`ON_C_IN_DIS.md`.

## Where the C lives

```
emu/port/        portable emulator + kernel C (devices, channels, namespace,
                 scheduler, qio, 9P) — shared across all hosts
emu/$SYS/        host-specific glue; os.c is the per-host kernel-thread + signal
                 layer (e.g. emu/Linux/os.c).  See ON_PORTING.md
libN/  (lib9,    the support libraries: lib9 (the dialect), libbio (buffered I/O),
 libbio, libsec, libsec (crypto), libmath, libmp, libdraw, libmemdraw, libinterp
 libinterp, …)   (the Dis VM itself), …
include/         shared headers; per-host generated headers under $SYS/$OBJTYPE/include
```

A few conventions worth knowing:

- **`up`** is the current process (`Proc*`) — the C analogue of "the running
  thread"; `up->env`, `up->estack`, etc. hang off it.
- Devices are tables of file operations (a `Dev` struct) registered in `emu/port`;
  adding one is the canonical "extend the kernel" task — see `ON_KERNEL.md`.
- The build is Plan 9 `mk` wrapped by the top-level `make`; how to build, the
  profiles, and the vendored-library cache are in **`ON_BUILDING.md`**.

## Want to vendor an external C library?

It's been done three times (FreeType, mbedTLS, stb). The pattern: drop the upstream
source under a `lib<name>/` tree, add a thin Inferno wrapper that exposes it to the
rest of the system (often as a built-in `$Module`), wire it into the build order
(the top-level `mkfile`'s `EMUDIRS`), and — for a heavy tree — let the
content-signature cache skip rebuilding it when unchanged. The worked example with
the most detail is the stb suite: **`ON_STB.md`** (and `ON_IMAGEIO.md` for how its
output reaches Draw). The vendored-cache mechanics are in `ON_BUILDING.md`.
