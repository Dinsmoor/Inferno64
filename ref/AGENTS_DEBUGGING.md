# Debugging in Inferno OS

## Exception Strings

Inferno exceptions are strings. The runtime raises them; Limbo code catches them. The format matters because `exception` clauses match on glob patterns.

### Built-in Runtime Exceptions (`libinterp/raise.c`)

```
"alt send/recv on same chan"   — channel appears in both send and recv arms of an alt
"channel busy"                 — concurrent access to channel from multiple OS threads
"module not loaded"            — module variable used before successful load
"compile failed"               — runtime compile (load with inline source) failed
"zero divide"                  — integer divide or mod by zero
"out of memory: heap"          — GC heap exhausted
"out of memory: image"         — draw/image memory exhausted
"out of memory: main"          — kernel memory exhausted
"invalid math argument"        — bad argument to math function (e.g. sqrt(-1))
"array bounds error"           — subscript outside [0, len)
"negative array size"          — array[n] where n < 0
"dereference of nil"           — field access or call on nil ref
"value out of range"           — type conversion overflow
"type not constructed correctly"
"inconsistent type"
"illegal dis instruction"
```

### User Convention for Exit Status

Commands signal failure via `raise "fail:reason"`. The shell interprets this as the command's exit status string. The pattern:

```limbo
raise "fail:usage";
raise "fail:cannot open file";
```

Anything matching `"fail:*"` is a normal command failure. `"error:*"` means an internal error. Catch them with glob patterns:

```limbo
{
    run();
} exception e {
    "fail:*"  => sys->fprint(stderr, "%s: %s\n", progname, e[5:]);  # strip "fail:"
    "out of memory:*" => handle_oom();
    "*"       => sys->fprint(stderr "unexpected exception: %s\n", e);
}
```

### Exception Propagation Modes

Written to `/prog/PID/ctl`:

```
"exceptions propagate"      — unhandled exception kills all procs in group
"exceptions notifyleader"   — kill siblings, raise exception in group leader
```

Default: unhandled exception leaves the Prog in "Broken" state (inspectable via `/prog`).

---

## The /prog Filesystem

Bind it first if it isn't already mounted:

```sh
bind '#p' /prog
```

Every Limbo thread gets a directory `/prog/PID/`. Files:

| File | Mode | Content |
|------|------|---------|
| `status` | r | `pid pgid user cputime state mem(K) modname` |
| `ctl` | w | `kill`, `killgrp`, `exceptions propagate`, `exceptions notifyleader`, `restricted` |
| `dbgctl` | rw | debug commands (write) / debug events (read) |
| `exception` | r | `pc modpath exception-string` of last unhandled exception |
| `stack` | r | one frame per line: `fp pc mp progpid compiled modpath` |
| `fd` | r | open file descriptors |
| `ns` | r | namespace as bind/mount commands (reproducible) |
| `heap` | rw | memory inspector |
| `nsgrp` | r | namespace group ID |
| `pgrp` | r | process group ID |
| `wait` | r | child exit notifications |

### Inspecting a Broken Process

```sh
# Find broken processes
grep Broken /prog/*/status

# Read the exception
cat /prog/42/exception
# e.g.: 1234 /dis/ls.dis dereference of nil

# Read the call stack
cat /prog/42/stack
# fp=0x... pc=42 mp=0x... prog=42 compiled=0 /dis/ls.dis

# Examine memory at a specific address
echo "0x1234.W4" > /prog/42/heap   # read 4 words starting at 0x1234
cat /prog/42/heap

# Check open file descriptors
cat /prog/42/fd

# View namespace
cat /prog/42/ns
```

Heap query syntax: `addr.fmtN` where fmt is one of:
- `W` — word (32-bit)
- `B` — byte
- `V` — big (64-bit)
- `I` — Dis instruction
- `P` — pointer
- `A` — array header
- `C` — channel
- `M` — module

### Debug Control Protocol

Write commands to `dbgctl`, read events back:

```sh
echo "stop" > /prog/42/dbgctl         # stop at current instruction
echo "step 1" > /prog/42/dbgctl       # execute 1 instruction
echo "toret" > /prog/42/dbgctl        # execute until return
echo "cont" > /prog/42/dbgctl         # continue until breakpoint or stop
echo "bpt set /dis/ls.dis 100" > /prog/42/dbgctl   # set breakpoint at PC 100
echo "bpt del /dis/ls.dis 100" > /prog/42/dbgctl   # remove breakpoint
echo "unstop" > /prog/42/dbgctl       # resume from stopped state
```

Reading `dbgctl` blocks until an event:

```
broken: <exception>     — process faulted
exited                  — process terminated normally
new <pid>               — new child process
```

### Programmatic Debugging via `appl/lib/debug.b`

The `Debug` module (`module/debug.m`) wraps the `/prog` interface:

```limbo
debug := load Debug Debug->PATH;

(p, err) := debug->prog(pid);   # open process for debugging
debug->stop(p);
debug->step(p, StepExp);
debug->setbpt(p, "/dis/ls.dis", 100);
debug->cont(p);
stk := debug->stack(p);         # returns array of Frame adts
debug->kill(p);
```

---

## disdump — Disassembling .dis Files

```sh
disdump file.dis
disdump /dis/ls.dis | head -30
```

Source: `appl/cmd/disdump.b`. Compiled to `/dis/disdump.dis`.

Output is one Dis instruction per line with the PC offset. Useful for:
- Mapping exception PC numbers back to source lines (cross-reference with `.sbl` file)
- Checking that a module compiled with the expected code shape
- Understanding what the optimizer did

The `.sbl` (symbol) file is generated by `limbo -g`. Without it, PC offsets in exceptions are opaque. Always compile with `-g` during development.

---

## Sanitizer builds (UBSan / ASan / Valgrind) — auditing the C for LP64 bugs

The LP64 bugs all live in **C** (the VM, libraries), not in Limbo — Limbo is
pointer-width-agnostic. Limbo programs are just the vehicle that drives the C
paths. A sanitizer build turns silent corruption into an immediate report.

**UBSan is the workhorse** (catches the LP64 classes: integer overflow, shifts,
pointer overflow, misaligned access; no allocator conflict). Inject the flags via
the arch mkfile and rebuild the emu-g runtime libs + emu-g (leave the host
`limbo`/`iyacc` normal so the toolchain stays fast and stable):

```sh
# in mkfiles/mkfile-Linux-$OBJTYPE: append to CFLAGS and set LDFLAGS
#   CFLAGS:  -fsanitize=undefined -fno-omit-frame-pointer -g
#   LDFLAGS: -fsanitize=undefined
ARGS="ROOT=$PWD SYSHOST=Linux SYSTARG=Linux OBJTYPE=aarch64"
for d in lib9 libbio libmp libsec libmath libinterp libkeyring; do
  (cd $d && mk $ARGS nuke && mk $ARGS install); done
(cd emu/Linux && mk $ARGS CONF=emu-g clean && rm -f *.o && mk $ARGS CONF=emu-g install)
UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=0 emu-g -r$PWD /dis/sh.dis -c PROG
# For the GUI stack also rebuild libdraw/libmemdraw/libmemlayer/libprefab/libtk
# (leave the vendored libfreetype uninstrumented — third-party noise; UBSan is
# per-TU so mixed linking is fine) and link CONF=emu, then run under Xvfb.
```
Revert the mkfile and `make all` to restore the normal build afterwards.  (The
rule templates make `.o` depend on the per-target flags mkfile, so changing the
sanitizer flags there does invalidate stale objects — but `mk clean` the emu dir
anyway if you mix configs.)

**ASan does NOT work** with emu: `emu/port/alloc.c` defines its own pool
`malloc`/`free`, which ASan's interceptors override, so a pool pointer reaches
`free`/`D2B` and panics `alloc:D2B ... not in pools` at boot. Don't fight it.

**Valgrind** is the substitute for ASan's heap/uninitialised-value checking — it
needs no recompile and tolerates the custom allocator (intra-pool granularity is
lost, but it catches uninitialised reads — great for width bugs — and overruns of
plain `malloc` buffers like `gscreendata`):
`valgrind --track-origins=yes emu-g -r$PWD /dis/sh.dis -c PROG`.

**Dis-heap object granularity for Valgrind (`-DVALGRIND`) — use-after-free in the
GC heap.** By default Valgrind sees the whole Dis garbage-collected heap as a few
giant pool superblocks, so a *use-after-free of a collected object* — a dangling
pointer left in an `isptr=0` (untraced) `tptr`/`tbig` slot, or any reference that
outlives a GC sweep — is invisible. `libinterp/vgheap.h` (off unless built with
`-DVALGRIND`) overlays object-level tracking: every Dis object is a
`VALGRIND_MALLOCLIKE_BLOCK` when `poolalloc(heapmem,…)` hands it out
(`libinterp/heap.c`: `nheap`/`heapz`/`heap`) and a `VALGRIND_FREELIKE_BLOCK` when
it is reclaimed — by refcount (`destroy`, `freelist`) **or by the GC sweep**
(`gc.c`). After the FREELIKE the object is poisoned NOACCESS, so reading a
reclaimed object is reported immediately as "Invalid read … block was freed by
`<stack>`" with **both** the alloc and free/GC stacks — i.e. it confirms-or-denies
a GC dangling-pointer and points at the offending slot. Build + run:
```sh
# rebuild just libinterp with the flag, relink emu, run under valgrind+Xvfb:
cd libinterp; gcc -c -DVALGRIND <normal-cflags> heap.c gc.c
ar r $ROOT/$OBJDIR/lib/libinterp.a heap.o gc.o
(cd emu/Linux && rm -f o.emu && mk $ARGS CONF=emu install)   # or CONF=emu-g
DISPLAY=:99 valgrind --error-exitcode=99 --num-callers=20 \
    emu -g1024x768 wm/wm /dis/<app>.dis
```
When off (`-DVALGRIND` absent) the macros are no-ops, so the production allocator
is byte-for-byte unchanged. Notes: redzones are 0 (the pool packs objects
adjacently, so this catches use-after-free + uninitialised reads, not
adjacent-object overruns); pool block coalescing makes a reused region's tracking
approximate; the `MALLOCLIKE` instructions are harmless no-ops when the binary is
run *outside* valgrind, so one `-DVALGRIND` emu serves both. The `-DVALGRIND`
build also swaps the pool's arena growth from `sbrk` to `mmap` (`emu/port/alloc.c`)
— `sbrk` overflows Valgrind's brk-segment limit and emu dies with `mallocz failed`
before reaching the code under test. **ASan still can't use these** (its `malloc`
interceptor already breaks emu at boot), so this is Valgrind-only — the right call,
since wiring ASan would require renaming emu's allocator across every hosted
platform.

**Accuracy to Inferno's memory model — GC-phase-aware (this is what makes it
usable).** A naive `FREELIKE` poison is swamped with false positives because the
memory manager *itself* legitimately reads freed-but-not-yet-reused memory, and by
memory access alone that is **indistinguishable from a real dangling-pointer UAF —
the only difference is WHO reads: the manager (legitimate) vs. the mutator (a
bug).** So the fix is phase-based, not frame-based:

1. **`VG_MM_BEGIN`/`VG_MM_END`** (`VALGRIND_{DISABLE,ENABLE}_ERROR_REPORTING`,
   nestable; defined in `vgheap.h`/`alloc.c`) bracket the manager's
   freed-memory-touching phases — the **GC mark+sweep** (`rungc`'s loop and
   `rootset`, which covers the `markheap`/`markarray`/`marklist` callbacks too),
   the **refcount free-cascade** (`destroy`'s `t->free`/`freeptrs`), and the
   **pool tree/coalesce** (`poolalloc`'s `dopoolalloc`, `poolfree`'s body). While
   the manager runs, freed reads are not reported; **the object stays
   `FREELIKE`-poisoned, so a *mutator* read of it IS still caught** outside the
   bracket. This keeps the whole object protected (no un-poisoning).
2. **Bhdr registration** (`VGHEAP_HDR` in `vgheap.h`): the pool's `Bhdr` header
   sits 16 bytes *before* `B2D`, and `D2B`'s consistency check reads it in plain
   mutator context. `VGHEAP_ALLOC` marks it `DEFINED` so those reads are clean —
   without un-poisoning any object byte, so a `destroy` that reads a *genuinely*
   freed child's `->ref` still fires (the real signal).
3. **Full-block registration**: `VGHEAP_ALLOC` registers the block's actual
   `poolmsize` extent, not `sizeof(Heap)+n` — a String's C-terminator write at
   `s->Sascii[s->len]` runs to the rounded block end, so the smaller size made
   that legitimate write look like "N bytes after the block".
4. **`libinterp/valgrind-inferno.supp`** mops up only the few un-bracketed paths:
   `smalloc` (the libc-malloc interposition artifact — production uses emu's pool)
   and the `poolread`/`poolmsize` `/prog` inspectors. Run with
   `--suppressions=libinterp/valgrind-inferno.supp`.

Measured on a charon launch (full GUI): **389 → 1** Invalid read/write reports
(the one residual is a benign boundary read). **Validated** that it still catches
real bugs: a synthetic mutator UAF (`newstring`; `destroy`; read `s->len` in
`Sys_write`) is reported as the *only* error — "Invalid read … inside a block …
free'd at `destroy`", top frame `Sys_write ← mcall ← xec` (a VM/mutator frame) with
both alloc and free stacks. **So a genuine UAF = a report reading *inside* a freed
block from a VM frame** (`Sys_*`/`xec`/string/font ops); the manager's own freed
reads are silenced, not conflated. (Caveat for intermittent races: Valgrind's ~30×
slowdown perturbs timing — the brutus/charon `Tkclient[$Sys]` intermittent did
**not** fire under it; chase that one via the deterministic `0xa8c2…` address with
`/prog`/gdb instead.)

**Triage note (what's a real bug vs benign):** a left-shift/overflow finding is a
real LP64 bug only when the value **sign-extends into a wider (64-bit) field used
at full width** (e.g. `(uchar)<<24` → negative int → `0xFFFFFFFF…` in a `ulong`).
If the result is stored into a 32-bit field, masked, or truncated, it is benign
2's-complement UB (correct result). The graphics pixel pipelines, crypto/bignum
byte-assembly, the string hash, `operand()`, and `memmove(x,nil,0)` are all benign
(verified: correct render + crypto vectors); the real ones found this way were the
sign-extending `mode`/9P-field/`disw` family below.

---

## Adding Diagnostic Prints

```limbo
# Module-level setup
sys := load Sys Sys->PATH;
stderr := sys->fildes(2);

# Print to stdout
sys->print("value=%d name=%s\n", x, name);

# Print to stderr (won't interfere with program output)
sys->fprint(stderr, "%s: error: %r\n", progname);

# Format to string
msg := sys->sprint("offset=%bd size=%d", offset, count);

# Format to byte array (for writing to a channel/fd)
buf := sys->aprint("key=%s\n", key);
```

Format verbs:

| Verb | Meaning |
|------|---------|
| `%d %o %x %X` | integer (decimal/octal/hex) |
| `%bd %bx` | big integer (64-bit) |
| `%e %f %g` | float |
| `%s` | string |
| `%q` | quoted string |
| `%c` | character |
| `%r` | current system error string (like strerror) |
| `%.*s` | precision from argument |

The `%r` verb is particularly useful — it prints the OS-level error string for the last failed syscall, equivalent to `sys->errstr()`.

---

## Build System: Rebuilding a Single Module

The build tool is `mk` (not `make`). Rules live in per-directory `mkfile`s; the Limbo compilation template is `mkfiles/mkdis`.

```sh
# Compile a single Limbo source file
limbo -I/home/tyler/inferno-os/module -gw appl/cmd/myfs.b
# Produces: myfs.dis (bytecode) + myfs.sbl (debug symbols, with -g)

# Rebuild via mk in the source directory
cd appl/cmd && mk myfs.dis

# Clean and rebuild
mk clean && mk myfs.dis

# Install (copies .dis to /dis/)
mk myfs.install
```

Key compiler flags:

| Flag | Meaning |
|------|---------|
| `-g` | Generate `.sbl` symbol file (needed for stack traces with source info) |
| `-w` | Enable warnings |
| `-I dir` | Add module search path |
| `-o file` | Output file name |
| `-S` | Output assembly instead of `.dis` |
| `-D flags` | Verbose debug output from compiler passes |

The standard combination for development is `limbo -gw`.

---

## Common Runtime Errors and Their Causes

| Exception | Typical Cause |
|-----------|--------------|
| `dereference of nil` | Using a `ref T` before assigning it, or after a failed `load` |
| `array bounds error` | Off-by-one in loop, or reading past end of a received byte slice |
| `zero divide` | Missing guard before integer division |
| `module not loaded` | Calling a module function before `load` succeeded (always check nil return) |
| `out of memory: heap` | Long-lived goroutine accumulating garbage; large byte arrays not released |
| `out of memory: image` | Creating Draw `Image` objects without freeing them |
| `alt send/recv on same chan` | A channel appears in both a send arm and a recv arm of the same `alt` |
| `negative array size` | Computing array length from arithmetic that went negative |
| `channel busy` | Two OS threads concurrently manipulating the same channel (rare in hosted mode) |

### Load Return Value

`load` returns nil on failure. The pattern is:

```limbo
m := load MyMod MyMod->PATH;
if(m == nil)
    raise "fail:cannot load MyMod: " + sys->sprint("%r");
```

Forgetting the nil check and calling through `m` gives `dereference of nil` with no useful context.

### Checking Status After Spawn

`spawn` gives no direct way to observe the child. Use an unbuffered sync channel:

```limbo
sync := chan of int;
spawn child(sync, ...);
<-sync;    # blocks until child sends, confirming it started cleanly
```

Or use `/prog/PID/wait` to read child exit events.

---

## Key Files

| File | Purpose |
|------|---------|
| `libinterp/raise.h` | Exception string constants (C) |
| `libinterp/raise.c` | Exception string definitions |
| `module/debug.m` | Debug module interface |
| `appl/lib/debug.b` | Debug module implementation (wraps /prog) |
| `appl/lib/exception.b` | Exception helper (getexc, setexcmode) |
| `appl/cmd/disdump.b` | Dis disassembler |
| `emu/port/devprog.c` | /prog filesystem kernel implementation |
| `os/port/devprog.c` | /prog for native kernels |
| `man/3/prog` | /prog filesystem reference |
| `man/10/acid` | acid debugger reference (native builds) |
| `man/2/sys-print` | Format verb reference |
| `man/1/limbo` | Compiler flags |
