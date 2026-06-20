# Writing C in the Inferno codebase

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

## What out-of-memory actually does (and why it matters for vendored C)

This is the part that bites when you bring a real C library in and feed it
real-world input. emu does **not** have one heap — it carves its address space into
several named pools, each with a hard `maxsize` ceiling (`emu/port/alloc.c`, the
`table.pool[]` array). Three matter:

| pool | default cap | who allocates from it |
|---|---|---|
| `main`  | 32 MB | emu's global `malloc`/`free`/`realloc` → **all C**, including any vendored library |
| `heap`  | 32 MB | the Dis/Limbo heap — every Limbo `array`, `string`, `ref adt` |
| `image` | 32 MB | Draw images (`writepixels` targets) |

Every allocation bottoms out in `poolalloc()`. When a pool can't satisfy a request
it tries to grow its arena; if that would cross `maxsize` it attempts a compaction,
and if *that* fails it prints `arena <name> too large: ...` and **returns nil** — it
does not itself crash. What happens next depends entirely on **which caller** got
the nil, and that split is the whole reason a vendored library's API has to be
designed around streaming rather than "hand me the whole blob":

- **A Limbo-side allocation that fails is graceful.** Dis heap allocations
  (`libinterp/heap.c`: `heap`, `heapz`, `heaparray`, `nheap`) turn a nil into
  `error(exHeap)` → the catchable Limbo exception `"out of memory: heap"`. The
  offending Dis process can catch it (`{ … } exception`), or, uncaught, **only that
  process** is marked `Broken` and reaped (the scheduler in `emu/port/dis.c` even
  refuses to keep an OOM-broken proc around, since its corpse pins the memory).
  emu and every other Dis proc keep running. (See `ON_LIMBO_ERROR_HANDLING.md`.)

- **A C-side allocation that fails is just C.** A vendored library calling `malloc`
  (or, if you bridged its allocator onto emu's pool the way the FFmpeg work did,
  `posix_memalign`/`realloc`) gets a **nil/`ENOMEM` return** — *not* an `error()`
  longjmp. There is no `waserror()` in third-party code. From there it's entirely
  the library's contract: a disciplined library checks the return and propagates an
  error code you can surface as a normal Limbo `(…, err)` tuple; a careless one
  dereferences the nil and you get a real **SIGSEGV inside the library** that emu
  cannot turn into a catchable exception. So when you wrap a C library, the
  allocation-failure paths of *its* code are now part of your reliability surface.
  (Caveat on `## Memory` above: malloc-family failures raise via `error()` only in
  the *emu/kernel* call sites that set up a recovery point — bare library calls do
  not get that for free.)

The pool ceilings are the deliberate backstop: a runaway allocation hits a clean
"arena too large → nil → exception" long before it can drag the host process into
the OS OOM-killer. On the **native kernel** the same pool code runs but there is no
host process underneath to absorb the hard case, so those ceilings matter even more.

**Design consequence — this is the load-bearing lesson.** If your wrapper's API
takes the whole input as one Limbo `array of byte` (e.g. "decode these bytes"), that
array lives in the 32 MB `heap` pool — so a 50 MB video, a large PDF, a big dataset
*cannot fit*, and you get `arena heap too large` before the library is even called.
The fix is to make the wrapper **stream**: hand the C library a pull-callback that
reads the source on demand through the kernel file ops (`kopen`/`kread`/`kseek`/
`kclose` on an Inferno-namespace file — these work identically on emu and the native
kernel, and never touch the host fs), so only a small working buffer and one unit of
output are ever resident. The vendored-FFmpeg `$Ffmpeg` builtin is the worked
example: its in-memory opener OOMs on real clips, while its streaming opener
(callback AVIO backed by `kread`) decodes arbitrarily large video with the heap
holding a single frame. Detail in `module/ffmpeg.m` + `libffmpeg/ffwrap.c` +
`libinterp/ffmpeg.c`; the related hazard of routing the library's allocator onto
emu's pool so `free`/`realloc` don't fault is in `ON_C_IN_DIS.md` (the pool-vs-libc
boundary).

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

It's been done several times (FreeType, mbedTLS, stb, and FFmpeg). The pattern: drop
the upstream source under a `lib<name>/` tree, add a thin Inferno wrapper that
exposes it to the rest of the system (often as a built-in `$Module`), wire it into
the build order (the top-level `mkfile`'s `EMUDIRS`), and — for a heavy tree — let
the content-signature cache skip rebuilding it when unchanged. The worked example
with the most detail is the stb suite: **`ON_STB.md`** (and `ON_IMAGEIO.md` for how
its output reaches Draw). The vendored-cache mechanics are in `ON_BUILDING.md`.

Three things will bite on a non-trivial library, all learned doing the FFmpeg port,
all covered above or in the linked docs:

1. **The allocator boundary.** emu overrides global `malloc`/`free`/`realloc` with
   its own pool allocator; a library that mixes libc aligned-alloc with bare `free`
   will allocate from one heap and free into the other and panic (`alloc:D2B … not
   in pools`). Bridge the library's allocator symbols onto emu's pool — see
   `ON_C_IN_DIS.md`.
2. **Out-of-memory is your problem now.** See *What out-of-memory actually does*
   above: a Limbo-side OOM is a catchable exception, but a C-side OOM is whatever the
   library does with a nil return — design the wrapper to **stream** large input
   rather than take it as one Dis `array of byte`, or it will hit the 32 MB pool
   ceiling on real data.
3. **The host filesystem isn't there on real hardware.** A library's own `open()`
   reads the *host* fs and cannot see the Inferno namespace — fine on emu, broken on
   the native kernel. Feed it bytes through the namespace (the kernel file ops) or an
   in-memory buffer instead; never rely on a host path.
