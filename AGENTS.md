# Inferno OS — Agent Onboarding Guide

This document orients AI agents working on the Inferno OS codebase. Read this first, then consult the specialist files for deeper coverage of each subsystem.

- **AGENTS_DIS.md** — Dis virtual machine, bytecode format, GC, channels
- **AGENTS_LIMBO.md** — Limbo language, compiler, module system
- **AGENTS_KERNEL.md** — Kernel internals, 9P protocol, device drivers, process management

---

## What Is Inferno?

Inferno is a distributed operating system originally from Bell Labs. It runs in two modes:

- **Hosted (emu)**: a user-space process on Linux, macOS, Windows, FreeBSD, Plan 9, etc. The emulator provides the Dis VM, scheduler, namespace, and device interface on top of the host OS.
- **Native (os/)**: a bare-metal kernel for ARM, x86, PowerPC, MIPS, SPARC. Same API surface as hosted mode — applications see no difference.

All programs are written in **Limbo**, compiled to **Dis** bytecode, and run on the **Dis virtual machine**. The VM is the only execution environment; there is no FFI in the traditional sense (C modules are linked directly into the emulator binary).

The kernel API is entirely file-based, mediated by the **9P protocol**. Every resource — processes, network connections, windows, audio — is a file in a unified namespace. Processes can export file servers that other processes (including remote ones) can mount into their namespace.

---

## Repository Layout

```
inferno-os/
├── emu/                 Emulator (hosted Dis VM)
│   ├── port/            Platform-independent VM code
│   └── Linux/           Linux-specific files (mkfile, asm, os integration)
├── os/                  Native kernel (bare-metal)
│   ├── port/            Architecture-independent kernel code
│   ├── pc/              x86 port
│   └── arm/             ARM port (+ omap, ipaq, etc.)
├── limbo/               Limbo compiler (→ .dis bytecode)
├── libinterp/           Dis interpreter library (linked into emu)
├── module/              Module interface definitions (.m files)
├── dis/                 Pre-compiled .dis bytecode for all apps
├── appl/                Limbo application source (.b files)
│   ├── cmd/             Command-line programs (182+)
│   ├── lib/             Limbo libraries
│   ├── wm/              Window manager
│   └── acme/            Acme editor
├── include/             C headers shared across subsystems
│   ├── interp.h         Dis VM runtime types (Prog, Module, Type, Channel, ...)
│   ├── isa.h            Dis instruction set (opcodes, addressing modes)
│   ├── draw.h           Graphics/display types
│   └── fcall.h          9P protocol message types
├── lib9/                Plan 9 compatibility library (string, fmt, utf8, ...)
├── libbio/              Buffered I/O
├── libmp/               Multi-precision arithmetic
├── libsec/              Cryptography (AES, RSA, SHA, TLS, ...)
├── libmath/             Math functions
├── libkern/             Kernel utility code (shared emu/os)
├── libdraw/             2D graphics primitives
├── libmemdraw/          In-memory drawing
├── libmemlayer/         Layered/clipped drawing
├── libprefab/           Higher-level GUI widgets
├── libtk/               Tk GUI toolkit binding
├── libfreetype/         TrueType font rendering
├── libdynld/            Dynamic .dis module loading
├── libkeyring/          Authentication key management
├── utils/               Build tools (mk, iyacc, data2c, ndate, compilers)
├── mkfiles/             Build configuration per host/target pair
├── Linux/aarch64/       Build output: bin/, lib/, include/
├── mkconfig             Central build config (ROOT, SYSHOST, OBJTYPE)
├── mkfile               Top-level mk rules
└── Makefile             Reliable fresh-build wrapper (always nukes first)
```

---

## Build System

### Variables

| Variable  | Meaning                                              | Example        |
|-----------|------------------------------------------------------|----------------|
| `ROOT`    | Repo root (absolute path)                            | `/home/tyler/inferno-os` |
| `SYSHOST` | Host OS running the build                            | `Linux`        |
| `SYSTARG` | Target OS (usually same as SYSHOST)                  | `Linux`        |
| `OBJTYPE` | Target CPU architecture                              | `aarch64`      |
| `OBJDIR`  | Where artifacts land (`$SYSTARG/$OBJTYPE`)           | `Linux/aarch64`|

These live in `mkconfig`, whose defaults are now this fork's host: `SYSHOST=Linux`, `OBJTYPE=aarch64` (LP64). For cross-compilation (e.g., kernel builds), `SYSTARG` differs from `SYSHOST`.

### The `mk` Build Tool

`mk` is a Plan 9 make replacement. Its syntax looks like make but differs:
- Variable assignment: `VAR=value` (no spaces around `=` in recipes)
- Include another mkfile: `<filename`
- Dynamic include (runs shell command): `<| shellcmd`
- Phony targets: `target:V:`
- Pattern rules: `%.$O: %.c`

Each library/component directory has an `mkfile`. The top-level `mkfile` loops over `EMUDIRS` to build them in order.

### Build Output Locations

```
$ROOT/$OBJDIR/bin/    installed binaries (emu, limbo, iyacc, ...)
$ROOT/$OBJDIR/lib/    static libraries (lib9.a, libinterp.a, ...)
$ROOT/$OBJDIR/include/ architecture-specific headers
```

### Using the Makefile Wrapper

The `Makefile` at the repo root is the **recommended entry point** and the only coherent build. It works from a *fresh checkout or git worktree* with no toolchain present: it auto-bootstraps `mk` with the host `gcc` (see `make bootstrap`), then builds both halves of the system, always nuking first (mk's incremental dependency tracking is unreliable):

```sh
make           # == make all (default target)
make all       # 1) C side: libs + limbo compiler + emu;  2) Dis tree: appl/*.b -> dis/
make clean     # remove object files
make nuke      # remove objects, library archives, and installed .dis
make OBJTYPE=amd64 all   # build for x86-64 instead of the aarch64 default
```

`make all` is the safe default and is cheap (~1 min) — run it freely. The cost in
this tree comes from the *lack* of nuking: a stale `.dis` against a freshly built
compiler/ABI is the exact incoherence behind the truncated-pointer crashes, so a
full nuke+rebuild is the insurance that prevents it, not an expense.

**Half-builds are gated.** `make emu` (C side only) and `make dis` (Dis tree only)
each leave the two halves out of sync, so the bare targets refuse to run; opt in
deliberately with `make emu FORCE=1` / `make dis FORCE=1`.

The Makefile passes `ROOT`, `SYSHOST`, `SYSTARG`, `OBJTYPE` to every `mk` invocation; `mkconfig` now defaults to the same host (`Linux`/`aarch64`), so invoking `mk` directly in a component directory works too.

### EMUDIRS Build Order

Components must be built in this exact order (each depends on all prior):

```
lib9 → libbio → libmp → libsec → libmath
  → utils/iyacc    (parser generator, needed by limbo)
  → limbo          (Limbo compiler, needed by libinterp)
  → libinterp      (Dis VM library)
  → libkeyring → libdraw → libprefab → libtk
  → libfreetype → libmbedtls → libmemdraw → libmemlayer
  → utils/data2c → utils/ndate
  → emu            (the emulator binary)
```

This is the `EMUDIRS` list in the root `Makefile`. After the C side, `make all`
builds the Dis tree: it runs `mk nuke` then `mk install` over `appl/`, compiling
every `.b` to a `.dis` under `dis/` with the freshly built `limbo`.

When running `mk install` in `emu/Linux/`, the emu build auto-recurses into dependencies; but this dependency tracking is unreliable for incremental rebuilds, which is why the Makefile always nukes first.

---

## Execution Model

### From Source to Running Program

```
appl/cmd/cat.b          (Limbo source)
    ↓  limbo cat.b
dis/cat.dis             (Dis bytecode, platform-independent)
    ↓  emu /dis/cat.dis arg...
                        (Dis VM interprets bytecode)
```

The emu binary is a C program (~100 KLOC of C) that:
1. Parses command-line options, opens an X11 window if needed
2. Loads `/dis/emuinit.dis` (the Inferno init process)
3. Runs the Dis interpreter loop until exit

### Module Loading at Runtime

When Limbo code executes `load Sys Sys->PATH`, the runtime:
1. Resolves `Sys->PATH` (the constant `"$Sys"`) to a file path
2. Reads the `.dis` file (from the Inferno namespace, not the host filesystem)
3. Verifies type signatures against the caller's expected interface
4. Links the module into the calling process's module table

---

## Key C Data Structures

These are the most important structures to understand. All defined in `include/interp.h` or `emu/port/dat.h`.

### Prog — a Limbo thread

```c
struct Prog {
    REG         R;          // Register file: PC, FP, MP, SP, IC, ...
    enum ProgState state;   // Pready, Palt, Psend, Precv, Pexiting, Pbroken
    int         pid;
    int         quanta;     // Instructions remaining in time slice
    Prog*       link;       // Run-queue link
    Channel*    chan;        // Channel blocked on (if Palt/Psend/Precv)
    Progs*      group;      // Process group (for exception propagation)
    void*       exval;      // Current exception value
    void*       osenv;      // Points to Osenv (file descriptors, namespace, ...)
};
```

### REG — register file

```c
struct REG {
    Inst*    PC;   // Program counter
    uchar*   MP;   // Module data pointer (global variables of current module)
    uchar*   FP;   // Frame pointer (current stack frame)
    uchar*   SP;   // Stack pointer
    uchar*   TS;   // Top of stack extent
    Modlink* M;    // Current module instance
    int      IC;   // Instruction counter (decremented each instruction)
};
```

### Module / Modlink — loaded bytecode

`Module` holds shared, read-only bytecode and type info. `Modlink` is a per-instance wrapper that holds the writable module-data segment (global variables).

```c
struct Module {
    int     nprog;      // Instruction count
    Inst*   prog;       // Text segment (Dis instructions)
    Inst*   entry;      // Entry-point instruction
    int     ntype;      // Number of type descriptors
    Type**  type;       // Type descriptor array
    Handler* htab;      // Exception handler table
    Link*   ext;        // External linkage table (imports)
};

struct Modlink {
    uchar*  MP;         // Per-instance module data (global variables)
    Module* m;          // Shared module code
};
```

### Type — runtime type descriptor

Used by the garbage collector to know which fields are pointers.

```c
struct Type {
    int   size;         // Size in bytes
    int   np;           // Number of pointer-sized slots
    uchar map[...];     // Bit map: 1 = pointer at that slot offset
    void (*mark)(Type*, void*);   // GC mark function
    void (*free)(Heap*, int);     // GC free function
};
```

### Channel — inter-thread communication

```c
struct Channel {
    Array*  buf;        // Circular buffer (nil for unbuffered)
    Progq*  send;       // Progs waiting to send
    Progq*  recv;       // Progs waiting to receive
    void  (*mover)(void); // Copies one element (movb/movw/movp/movm/...)
    int     front;      // Front index in circular buffer
    int     size;       // Items currently in buffer
};
```

### Chan — file/resource handle (9P)

Not to be confused with `Channel` above. `Chan` is the kernel's file descriptor, the result of open/attach/walk in the 9P namespace.

```c
struct Chan {
    Ref     r;          // Reference count
    vlong   offset;     // Current file position
    ushort  type;       // Device type index (into devtab[])
    Qid     qid;        // Unique file identifier (path, vers, type)
    ushort  mode;       // OREAD, OWRITE, ORDWR
    Mhead*  umh;        // Union mount point
    Chan*   mchan;      // Channel to mounted server
    Cname*  name;       // Path name
    void*   aux;        // Device-specific state
};
```

### Dev — device driver vtable

```c
struct Dev {
    int   dc;           // Device character (e.g., '#c' for cons, '#s' for srv)
    char* name;
    void  (*init)(void);
    Chan* (*attach)(char*);
    Walkqid* (*walk)(Chan*, Chan*, char**, int);
    Chan* (*open)(Chan*, int);
    long  (*read)(Chan*, void*, long, vlong);
    long  (*write)(Chan*, void*, long, vlong);
    void  (*close)(Chan*);
    // ... stat, create, remove, wstat, bread, bwrite
};
```

---

## Module Interface Files (.m files)

`.m` files in `module/` define public interfaces (like C headers or Go interfaces). They list constants, ADT definitions, and function signatures. `.b` files in `appl/` implement them.

```limbo
# module/sys.m (excerpt)
Sys: module {
    PATH: con "$Sys";          # Module search path

    FD: adt { fd: int; };      # File descriptor ADT

    open:  fn(s: string, mode: int): ref FD;
    read:  fn(fd: ref FD, buf: array of byte, n: int): int;
    write: fn(fd: ref FD, buf: array of byte, n: int): int;
    print: fn(s: string, *): int;
};
```

The `PATH` constant (`"$Sys"`) is resolved at runtime to a file path like `/dis/lib/sys.dis`.

---

## Coding Conventions

### C Code (emu, libinterp, libraries)

- **Types**: Use `uchar`, `ushort`, `ulong`, `vlong` (64-bit signed), `uvlong`. Avoid `int` for sizes — use `long` or explicit-width types.
- **Errors**: Use `error(msg)` to raise an exception (longjmp to error handler). Check `waserror()` for cleanup.
- **Memory**: `malloc`/`free` for temporary C data. `allocb`/`freeb` for kernel block chains. Limbo heap objects via `halloc`.
- **Locking**: `lock(&l)` / `unlock(&l)` for spinlocks. `qlock(&ql)` / `qunlock(&ql)` for sleep locks. `rlock`/`runlock`/`wlock`/`wunlock` for rwlocks.
- **Reference counting**: `incref(&r)` / `decref(&r)`.
- **String helpers**: `kstrdup`, `smprint`, `snprint` (from lib9).
- **No C++ / C99 VLAs** — plain C89/C90 with Plan 9 extensions.

### Limbo Code (appl/, module/)

- **Loading a module**: `sys = load Sys Sys->PATH;`
- **Spawning a thread**: `spawn functionname(args);`
- **Channel send/receive**: `ch <-= val;` / `val = <-ch;`
- **Exception**: wrap with `{ ... } exception e { if e == "msg" => handle(); }`
- **nil checks**: always check refs before use — nil dereference raises `"dereference of nil"`.

---

## Common Tasks

### Add a New Limbo Application

1. Create `appl/cmd/myapp.b` — implement the module with `init(ctxt, args)`.
2. Create `dis/cmd/myapp.dis` by running `limbo -o dis/cmd/myapp.dis appl/cmd/myapp.b`.
3. The app is accessible as `/cmd/myapp` in the Inferno namespace.

### Add a New C Device Driver

1. Create `emu/port/devfoo.c` implementing the `Dev` vtable.
2. Add `devfoo` to `emu/port/master` in the `dev` section.
3. The device appears under `#F` (or whatever `dc` character you assign) in the namespace.

### Add Architecture-Specific Assembly

1. Create `emu/Linux/foo-aarch64.S`.
2. Add it to `ARCHFILES` in `emu/Linux/mkfile-aarch64`.
3. Rebuild with `make`.

### Understand a Crash

- `"dereference of nil"` → nil pointer dereference in Limbo.
- `"array bounds error"` → out-of-bounds array index.
- `"zero divide"` → integer divide by zero.
- `"out of memory: heap"` → Limbo GC heap exhausted.
- `"module not loaded"` → `load` failed (bad path or type mismatch).
- Segfault in C code → bug in emu/libinterp C code, not in Limbo.

---

## Architecture Support Matrix

| OBJTYPE  | Architecture         | Status    |
|----------|----------------------|-----------|
| `aarch64`| ARM 64-bit           | Active    |
| `386`    | Intel x86 32-bit     | Active    |
| `arm`    | ARM 32-bit           | Active    |
| `amd64`  | x86-64               | Available |
| `power`  | PowerPC              | Available |
| `mips`   | MIPS                 | Available |
| `sparc`  | SPARC                | Available |
| `thumb`  | ARM Thumb            | Available |
| `spim`   | MIPS simulator       | Available |

For each target, the compiler flags live in `mkfiles/mkfile-Linux-$OBJTYPE` (for Linux host) and architecture-specific emu files in `emu/Linux/mkfile-$OBJTYPE`.

---

## Where to Look for What

| Question | Where to look |
|----------|---------------|
| What does opcode X do? | `libinterp/xec.c` (search `OP(iopcode)`) |
| How is .dis file structured? | `libinterp/load.c` + `AGENTS_DIS.md` |
| How does GC work? | `libinterp/gc.c` |
| How does alt/channel work? | `libinterp/alt.c` |
| How does a Limbo thread get scheduled? | `emu/port/dis.c` (`addrun`, `delrun`) |
| How does file open/read work? | `emu/port/chan.c`, then the relevant `devXXX.c` |
| How does 9P mounting work? | `emu/port/devmnt.c` |
| How does Limbo → Dis compilation work? | `limbo/` + `AGENTS_LIMBO.md` |
| What are the system call APIs? | `module/sys.m`, then `emu/port/devcons.c` for #c |
| How does X11 graphics work? | `emu/Linux/win-x11a.c`, `emu/port/devdraw.c` |
