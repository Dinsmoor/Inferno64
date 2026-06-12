# Debugging Limbo programs in Inferno OS (exceptions, /prog, disdump)

**Audience / when to read this:** you are debugging a **Limbo program** running on
the Dis VM — it raised an exception, went `Broken`, wedged, or you want a stack
trace / diagnostic prints from *inside* Inferno. The first tool here is the VM's own
`/prog` filesystem. If instead the **C emulator itself** crashed (host
SIGSEGV/SIGBUS), hung, or corrupted its heap — i.e. emu died before you could reach
`/prog` — use **`ON_EMU_DEBUG.md`** (sanitizers, fault/hang hooks, cores).
For **heap corruption where the crash is far from the cause** (a stray/UAF write the
allocator only notices later), that doc's **`LIMBRULFENCEMEMSIZE`** electric-fence
quarantine traps the *writer* synchronously — it's what cracked the charon-teardown
free-tree corruption.
For the language itself see `ON_LIMBO.md`; for the static LP64 width-bug
catchers see `ON_C_IN_DIS.md`.

> **This repo differs from stock Inferno** in two ways that matter here: typed
> exceptions now keep their payload across frames (R1, below), and the compiler
> prints a source-snippet + caret (C1, below). A model trained on stock Limbo will
> not expect either.

---

## Exception Strings

Inferno exceptions are strings (a user-defined `exception` can also carry a typed
payload — see R1 below). The runtime raises them; Limbo code catches them. The
format matters because `exception` clauses match on glob patterns.

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

Commands signal failure via `raise "fail:reason"`. The shell interprets this as the
command's exit status string (it strips the `fail:` prefix — so `$status` becomes
`reason`). The pattern:

```limbo
raise "fail:usage";
raise "fail:cannot open file";
```

Anything matching `"fail:*"` is a normal command failure. Catch with glob patterns:

```limbo
{
    run();
} exception e {
    "fail:*"  => sys->fprint(stderr, "%s: %s\n", progname, e[5:]);  # strip "fail:"
    "out of memory:*" => handle_oom();
    "*"       => sys->fprint(stderr, "unexpected exception: %s\n", e);
}
```

### Exception Propagation Modes

Written to `/prog/PID/ctl`:

```
"exceptions propagate"      — unhandled exception kills all procs in group
"exceptions notifyleader"   — kill siblings, raise exception in group leader
```

Default: an unhandled exception prints `[Module] Broken: "reason"` to the emu
console and leaves the Prog in the `broken` state (inspectable via `/prog`, below).

---

## Limbo error reporting (compiler diagnostics + typed exceptions)

Two local improvements (`limbo-error-reporting` branch).

### C1 — compiler source-snippet + caret (`limbo/lex.c`)

Every compiler diagnostic now prints the offending source line and a caret under
the token, clang/C3 style. The `^` marks `src.start`'s column; `^~~~` spans the
whole token when start/stop are on the same line. Example:

```
foo.b:9: type clash in 'x' of type int + 'y' of type string
    	z := x + y;
    	     ^~~~~
foo.b:10: undeclared_thing is not declared
    	w := undeclared_thing + 2;
    	     ^
```

How to read it: the first line is the existing `file:line: message` (the include
chain is still appended for errors inside `include`d files); the second line is the
literal source (tabs preserved so columns align); the caret line shows the column.
Columns were always tracked (`Src.start.pos`/`stop.pos`, 0-based runes) but
previously discarded — the caret surfaces them. `showsrc()` reopens the source on
the cold diagnostic path (no hot-path cost) and is a silent no-op if the line can't
be recovered. Wired into `error`/`nerror`/`warn`/`nwarn`/`yyerror`. A clean compile
prints nothing extra.

### R1 — typed exceptions keep their payload across frames (`emu/port/exception.c`)

A typed (`ExcName: exception(...)`) exception now propagates with its full payload
until a **typed** handler (`ExcName =>`) catches it, at *any* stack depth. It only
degrades to its name string when delivered into a **string/`"*"`** arm (whose
handler variable is string-typed). Previously it was eagerly stringified the moment
it left the immediate caller, so `(a,b) := e;` in a distant `ExcName =>` arm got the
bare name, not the payload.

Mechanics: `handler()` no longer force-stringifies between frames. The match test is
now `ematch(e->s, estr) && (ne <= 0 || !str)` — a string pattern (`ne<=0`) matches any
exception by name; a typed pattern (`ne>0`) matches only a still-typed value. A
`matchtyped` flag records which kind caught it; the degrade-to-name happens lazily at
`found:` only when a typed value lands in a non-typed arm. String exceptions and
`fail:*` exits are unchanged.

Debugging tip: if a handler that expects a typed payload is instead seeing the bare
exception *name* (e.g. `Mod.0.E`), a `"*"`/string arm is catching it before the typed
arm — typed arms are more specific and now win, so reorder accordingly.

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
| `exception` | r | last **caught** exception as `pc module exception-string` (see caveat) |
| `stack` | r | one frame per line: `FP PC MP modcode compiled path` (hex; see below) |
| `fd` | r | open file descriptors |
| `ns` | r | namespace as bind/mount commands (reproducible) |
| `heap` | rw | memory inspector |
| `wait` | r | child exit notifications |

> **Caveat — `/prog/PID/exception` is empty for a freshly-`broken` proc.**
> `p->exstr` is set only when a handler *catches* an exception (`emu/port/exception.c`,
> the `found:` path). A proc that breaks on its *first/uncaught* exception never sets
> it, so the file reads empty. For a `broken` proc the exception text is the emu
> console line `[Module] Broken: "reason"` (`emu/port/dis.c`, function `disexit`), and
> `state` in `status` is `broken`. Use `/prog/PID/stack` for the frame chain.

### Inspecting a Broken Process

```sh
# Find broken processes
grep broken /prog/*/status
# e.g.:  3  1  tyler  0:00.0  broken  150K  B

# Read the call stack (one frame per line, all hex except the compiled flag):
cat /prog/3/stack
# FP           PC        MP           modcode      compiled  path
# afcc...87a38 00000001  afcc...a67b0 afcc...56c20 0         /tmp/broke.dis
# afcc...87908 00000714  afcc...9d370 afcc...57260 0         /dis/sh.dis
#   ^FP         ^PC(dis-  ^MP(module   ^module      ^1 if     ^.dis the
#               instr     data)        code base    JIT'd     frame is in
#               offset)
```

`PC` is the Dis-instruction offset within the module — cross-reference it with
`disdump <module>.dis` (and the `.sbl` for source lines) to find the faulting line.

```sh
# Examine memory at an address (heap inspector)
echo '0x1234.W4' > /prog/3/heap   # read 4 words starting at 0x1234
cat /prog/3/heap

# Open fds / namespace
cat /prog/3/fd
cat /prog/3/ns
```

Heap query syntax: `addr.fmtN` where fmt is one of:
- `W` — word (**always 32-bit**, even on LP64 — Inferno `WORD` is 32-bit by design)
- `B` — byte
- `V` — big (64-bit)
- `I` — Dis instruction
- `P` — pointer (**pointer width**: 8 bytes on LP64, 4 on a 32-bit build)
- `A` — array header   ·   `C` — channel   ·   `M` — module

> Dual-ABI note: `P`/`A`/`C`/`M` follow the pointer width (`IBY2PTR`), so on the
> LP64 aarch64/amd64 build they are 8 bytes; `W` stays 32-bit. See
> `ON_C_IN_DIS.md`.

### Debug Control Protocol

Write commands to `dbgctl`, read events back:

```sh
echo 'stop'  > /prog/3/dbgctl          # stop at current instruction
echo 'step 1' > /prog/3/dbgctl         # execute 1 instruction (step N)
echo 'toret' > /prog/3/dbgctl          # execute until return
echo 'cont'  > /prog/3/dbgctl          # continue until breakpoint or stop
echo 'start' > /prog/3/dbgctl          # resume a stopped proc
echo 'unstop' > /prog/3/dbgctl         # clear the stopped state
echo 'bpt set /dis/ls.dis 100' > /prog/3/dbgctl   # breakpoint at PC 100
echo 'bpt del /dis/ls.dis 100' > /prog/3/dbgctl   # remove it
```

(Command set: `step`, `toret`, `cont`, `start`, `stop`, `unstop`, `bpt set|del` —
`emu/port/devprog.c`.) Reading `dbgctl` blocks until an event:

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

### Windowed debugger (`wm/deb`)

`appl/wm/deb.b` is the graphical debugger (its window title is `spark:Wmdeb`). It
drives the same `/prog/PID/dbgctl` protocol through `appl/lib/debug.b`, with a
thread picker (File → Thread…), a Threads/Break list, a source/disassembly pane and
a Stack window. Source-level view needs the module's `.sbl` (compile with `limbo
-g`); without it you still get disassembly + the stack.

**Caveat — never stop a GUI proc; it self-deadlocks the desktop.** Adding a target
writes `stop` to its `dbgctl`. If that target is `Wm`/`Wmsrv`/`Toolbar` (the
window-manager group, usually grp 1 / grp 8) or any Tk client, the whole desktop
hard-freezes: the compositor that draws the debugger's own window and dispatches
input is now halted, so you can't even click "unstop"/"detach". The emu stays
healthy (all threads idle on futex, no fault/spin) — a pure suspension deadlock, and
on hosted emu there's no host-side `/prog` access to write `start` back, so recovery
is restarting that emu. The "Wmdeb Thread List" picker also **auto-refreshes/
reorders**, so a select-then-"Add Thread" can grab the wrong pid (an easy way to stop
`Wmsrv` by accident). Use `wm/deb` on non-GUI / headless Limbo programs; pick targets
by their own `grp`, never the wm group.

---

## disdump — Disassembling .dis Files

```sh
disdump file.dis
disdump /dis/ls.dis | head -30
```

Source: `appl/cmd/disdump.b`. Compiled to `/dis/disdump.dis`. Output is one Dis
instruction per line with the PC offset. Useful for:
- Mapping a `/prog/PID/stack` `PC` (or an exception PC) back to source (cross-reference with `.sbl`).
- Checking a module compiled with the expected code shape.
- Understanding what the optimizer did.

The `.sbl` (symbol) file is generated by `limbo -g`. Without it, PC offsets are
opaque. Compile with `-g` during development.

---

## Profiling (prof / cprof / mprof)

Inferno ships three line-level Limbo profilers, all driven by one kernel device and
one library module. They answer different questions:

| Tool | Kind | Question | Source |
|---|---|---|---|
| `prof`  | **time** (statistical) | "why is this slow?" — % of samples per source line | `appl/cmd/prof.b` |
| `cprof` | **coverage** | "which lines ran?" — `+`/`-`/`?` per line, accumulable across runs | `appl/cmd/cprof.b` |
| `mprof` | **memory** | "what allocates?" — bytes live + high-water per line | `appl/cmd/mprof.b` |

Each has a Tk GUI sibling under `appl/wm/` (`wm/prof`, `wm/cprof`, `wm/mprof`) that
colours the source by hotness/coverage. All six share the library module
`module/profile.m` / `appl/lib/profile.b`, which is the only thing that talks to the
kernel.

**How it works.** The kernel half is the profile device **`#P`** (`emu/port/devprof.c`,
and `os/port/devprof.c` for native), which the library binds onto `/prof`
(`profile.b`: `bind("#P", "/prof", MREPL|MCREATE)`). `prof` samples the currently
executing Dis instruction from a kernel timer; `cprof` swaps in an
instruction-counting Dis execute routine (the same mechanism the debugger uses);
`mprof` tags each heap allocation/free with the source line that caused it. None of
these profile **C/kernel** code — they are Limbo-source-line tools only.

```sh
prof wm/polyhedra                 # time-profile a command, stats on exit
prof -m Polyhedra -m Polyfill cmd # restrict to named modules
prof -s rate cmd                  # finer sampling (slower, more accurate)
cprof -m Zeros zeros 1024 2880    # coverage; -r accumulates into <mod>.prf across runs
mprof -b -m Polyhedra             # begin memory profiling a module...
wm/polyhedra &                    #   ...run the target, then:
mprof                             #   dump current/high-water bytes per line
mprof -c                          # cease, discarding kernel stats
```

`prof` flags: `-bflnv`, `-m modname` (repeatable), `-s rate`, then the command. The
output columns are *line · value · source*: percent-of-samples for `prof`,
`+`/`-`/`?` (ran / didn't / partial) for `cprof`, live-bytes + high-water for
`mprof`.

Manuals: `prof(1)`, `cprof(1)`, `mprof(1)` (commands), `prof(2)` (the `Profile`
module interface), `prof(3)` (the `#P` device). The historical `wm-*(1)` pages
referenced by the old "Limbo profilers in Inferno" note (`docs/ref/lprof.pdf`) were
never written; the GUI tools document themselves via the same options.

---

## Adding Diagnostic Prints

```limbo
# Module-level setup
sys := load Sys Sys->PATH;
stderr := sys->fildes(2);

sys->print("value=%d name=%s\n", x, name);          # stdout
sys->fprint(stderr, "%s: error: %r\n", progname);   # stderr (won't mix with output)
msg := sys->sprint("offset=%bd size=%d", offset, count);   # format to string
buf := sys->aprint("key=%s\n", key);                # format to byte array
```

Format verbs:

| Verb | Meaning |
|------|---------|
| `%d %o %x %X` | integer (decimal/octal/hex) |
| `%bd %bx` | big integer (64-bit) |
| `%e %f %g` | float |
| `%s` | string · `%q` quoted string · `%c` character |
| `%r` | current system error string (like `strerror`; = `sys->errstr()`) |
| `%.*s` | precision from argument |

`%r` is particularly useful — it prints the OS-level error string for the last
failed syscall.

---

## Build System: Rebuilding a Single Module

The build tool is `mk` (not `make`). Rules live in per-directory `mkfile`s; the
Limbo compilation template is `mkfiles/mkdis`.

```sh
limbo -I/home/tyler/inferno-os/module -gw appl/cmd/myfs.b   # -> myfs.dis (+ myfs.sbl with -g)
cd appl/cmd && mk myfs.dis        # via mk
mk clean && mk myfs.dis           # clean rebuild
mk myfs.install                   # install (copies .dis to /dis/)
```

Key compiler flags:

| Flag | Meaning |
|------|---------|
| `-g` | Generate `.sbl` symbol file (needed for source-level stack traces) |
| `-w` | Enable warnings |
| `-I dir` | Add module search path |
| `-o file` | Output file name |
| `-S` | Output assembly instead of `.dis` |

The standard development combination is `limbo -gw`. (Whole tree: `cd appl && mk
install`. Build caveats — emu-vs-Dis rebuild, ETXTBSY, ABI-switch header staleness —
are in `ON_C_IN_DIS.md`.)

---

## Common Runtime Errors and Their Causes

| Exception | Typical Cause |
|-----------|--------------|
| `dereference of nil` | Using a `ref T` before assigning it, or after a failed `load` |
| `array bounds error` | Off-by-one in loop, or reading past end of a received byte slice |
| `zero divide` | Missing guard before integer division |
| `module not loaded` | Calling a module function before `load` succeeded (always check nil return) |
| `out of memory: heap` | Long-lived proc accumulating garbage; large byte arrays not released |
| `out of memory: image` | Creating Draw `Image` objects without freeing them |
| `alt send/recv on same chan` | A channel in both a send and a recv arm of the same `alt` |
| `negative array size` | Computing array length from arithmetic that went negative |
| `channel busy` | Two OS threads concurrently manipulating the same channel (rare in hosted mode) |

### Load Return Value

`load` returns nil on failure — always check:

```limbo
m := load MyMod MyMod->PATH;
if(m == nil)
    raise "fail:cannot load MyMod: " + sys->sprint("%r");
```

Forgetting the nil check and calling through `m` gives `dereference of nil` with no
useful context. (The `module not loaded` exception is the related case: a *module
variable* used before a successful `load`.)

### Checking Status After Spawn

`spawn` gives no direct way to observe the child. Use a sync channel:

```limbo
sync := chan of int;
spawn child(sync, ...);
<-sync;    # blocks until child sends, confirming it started cleanly
```

Or read `/prog/PID/wait` for child exit events.

---

## Key Files

| File | Purpose |
|------|---------|
| `libinterp/raise.h` / `raise.c` | exception string constants / definitions (C) |
| `emu/port/exception.c` | exception dispatch / handler matching (R1 lives here) |
| `module/debug.m` / `appl/lib/debug.b` | Debug module interface / implementation (wraps `/prog`) |
| `appl/lib/exception.b` | exception helper (`getexc`, `setexcmode`) |
| `appl/cmd/disdump.b` | Dis disassembler |
| `module/profile.m` / `appl/lib/profile.b` | profiler library (binds `#P` → `/prof`) |
| `appl/cmd/{prof,cprof,mprof}.b` / `appl/wm/{prof,cprof,mprof}.b` | the three profilers + Tk GUIs |
| `emu/port/devprof.c` / `os/port/devprof.c` | `#P` profile device (hosted / native) |
| `emu/port/devprog.c` | `/prog` filesystem kernel implementation |
| `os/port/devprog.c` | `/prog` for native kernels |
| `limbo/lex.c` | compiler diagnostic funnel (C1 `showsrc` lives here) |
| `man/3/prog`, `man/1/limbo`, `man/2/sys-print` | `/prog`, compiler flags, format verbs (manuals) |

**Cross-references:** `ON_EMU_DEBUG.md` (the emu *itself* faulted/hung —
sanitizers, fault/hang hooks, cores) · `ON_LIMBO.md` (the language &
compiler) · `ON_DIS.md` (the Dis VM & instruction set) · `ON_C_IN_DIS.md`
(LP64 static catchers, build profiles).
