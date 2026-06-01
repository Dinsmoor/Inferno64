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
