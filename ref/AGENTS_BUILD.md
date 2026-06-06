# Inferno Build System (mk)

The build tool is `mk`, not `make`. Syntax differs enough to cause confusion; key differences are noted below. This doc focuses on the OBJTYPE/SYSTARG/SYSHOST configuration chain and how to add a new architecture target. Limbo compiler flags are covered in AGENTS_DEBUGGING.md.

## The Configuration Chain

Every mkfile in the tree begins with `<../../mkconfig` (or `<../mkconfig` or `<mkconfig` depending on depth). That single include sets everything.

**`mkconfig`** (top-level):

```
ROOT=/usr/inferno          # install root — override per build
SYSHOST=Linux              # OS running the build
SYSTARG=$SYSHOST           # OS being targeted (same unless cross-compiling kernels)
OBJTYPE=$objtype           # architecture — set in environment or on mk command line
OBJDIR=$SYSTARG/$OBJTYPE   # e.g. Linux/aarch64

<$ROOT/mkfiles/mkhost-$SYSHOST           # host tool definitions
<$ROOT/mkfiles/mkfile-$SYSTARG-$OBJTYPE  # target compiler/linker flags
```

The two chained includes do different jobs:

| File | Purpose | One per |
|------|---------|---------|
| `mkfiles/mkhost-$SYSHOST` | Host tools: shell, `awk`, `ndate`, `data2s` | OS type |
| `mkfiles/mkfile-$SYSTARG-$OBJTYPE` | Compiler, assembler, linker, CFLAGS | OS+arch pair |

## mkfiles/mkhost-Linux

Defines tools available on the Linux build host:

```
SHELLTYPE=sh
SHELLNAME=/bin/sh
HOSTMODEL=Posix
DATA2S=data2s        # converts binary blobs to .s
NDATE=ndate          # generates kernel timestamp
KSIZE=ksize
AWK=awk
```

`HOSTMODEL=Posix` selects the `&-Posix:` pattern rules in the top-level mkfile.

## mkfiles/mkfile-Linux-OBJTYPE

One file per OS+arch pair. This is what you create when adding a new target. Compare arm vs 386:

**mkfile-Linux-arm:**
```
TARGMODEL=  Posix
CPUS=       arm
O=          o
AR=         ar
ARFLAGS=    ruvs
AS=         arm-gcc -c
CC=         arm-gcc -c
CFLAGS=     -O -Wuninitialized -Wunused-variable -Wreturn-type -Wimplicit \
            -I$ROOT/Linux/arm/include \
            -I$ROOT/include \
            -DLINUX_ARM
LD=         arm-gcc
LDFLAGS=
YACC=       iyacc
```

**mkfile-Linux-386:**
```
TARGMODEL=  Posix
CPUS=       386
O=          o
CC=         cc -c -m32
AS=         cc -c -m32
CFLAGS=     -O ... -I$ROOT/Linux/386/include -I$ROOT/include -DLINUX_386 \
            -fno-aggressive-loop-optimizations
LD=         cc -m32
```

**mkfile-Linux-aarch64 (to create):**
```
TARGMODEL=  Posix
CPUS=       aarch64
O=          o
AR=         ar
ARFLAGS=    ruvs
AS=         aarch64-linux-gnu-gcc -c
CC=         aarch64-linux-gnu-gcc -c
CFLAGS=     -O -Wuninitialized -Wunused-variable -Wreturn-type -Wimplicit \
            -I$ROOT/Linux/aarch64/include \
            -I$ROOT/include \
            -DLINUX_AARCH64
LD=         aarch64-linux-gnu-gcc
LDFLAGS=
YACC=       iyacc
```

If building natively on an aarch64 Linux host, replace `aarch64-linux-gnu-gcc` with `gcc`.

## The emu Build Path

```
emu/mkfile
  → emu/Linux/mkfile              (SYSTARG=Linux)
      <../../mkconfig              sets OBJTYPE etc.
      <mkfiles/mkfile-Linux-aarch64   sets CC, LD, AS
      <| mkdevlist $CONF           sets DEVS, PORT, LIBS
      <mkfile-$OBJTYPE             sets ARCHFILES
      <../port/portmkfile          compilation rules
```

**`emu/Linux/mkfile-$OBJTYPE`** is a tiny file that sets `ARCHFILES` — the architecture-specific object files that get linked into the emu binary:

```
# mkfile-arm:
ARCHFILES=\
    arm-tas-v7.$O\

# mkfile-aarch64 (to create):
ARCHFILES=\
    aarch64-tas.$O\
```

**`emu/port/mkdevlist`** is an awk script that reads `emu/Linux/emu` (the CONF file) and emits:
- `DEVS=` — device object files (`devcons.$O devdraw.$O ...`)
- `PORT=` — portable kernel object files (`alloc.$O chan.$O dis.$O ...`)
- `LIBS=` — libraries to link (`interp tk math draw 9 ...`)

The CONF file (`emu/Linux/emu`) lists devices, libs, modules, port files, and the root filesystem to embed. It is shared across all architectures in `emu/Linux/`.

**OBJ list** in `emu/Linux/mkfile` (lines 22–31):
```
OBJ=\
    asm-$OBJTYPE.$O\      # arch-specific: umult, FPsave, FPrestore
    $ARCHFILES\           # from mkfile-$OBJTYPE: _tas etc.
    os.$O\
    kproc-pthreads.$O\
    segflush-$OBJTYPE.$O\ # arch-specific: I-cache flush
    $CONF.root.$O\
    lock.$O\
    $DEVS\                # from mkdevlist
    $PORT\                # from mkdevlist
```

## The Install Tree

`mk install` populates `$ROOT/$SYSTARG/$OBJTYPE/`:

```
$ROOT/Linux/aarch64/
    bin/        emu binary and host tools
    lib/        lib9.a libdraw.a libinterp.a ... (one per library)
    include/    lib9.h emu.h fpuctl.h (arch-specific headers)
```

Libraries are built by recursing into each `lib*/` directory with the current `SYSTARG` and `OBJTYPE`. The portmkfile rule:

```
LIBFILES=${LIBS:%=$ROOT/$SYSTARG/$OBJTYPE/lib/lib%.a}
```

resolves libraries to their install paths. `mk` in a lib directory builds and installs `lib$stem.a` to `$ROOT/$SYSTARG/$OBJTYPE/lib/`.

The `Linux/aarch64/include/` directory must contain architecture-specific headers. At minimum:
- `lib9.h` — POSIX type definitions and architecture-specific sizes
- `emu.h` — FPU register save struct definition (`FPsave`/`FPrestore` layout)

Copy these from `Linux/arm/include/` and adjust for aarch64 (64-bit pointer sizes, AArch64 FP register layout).

## Iterating on a running system: Dis tree vs the emu binary

The system has two halves that rebuild very differently, which matters when a
desktop (`wm/wm`) is live and you don't want to disturb it:

- **Limbo / Dis changes** (anything under `appl/` — charon, wm, sh, acme, the
  libraries) compile to `.dis` files that the running emu loads *lazily at launch*.
  So you can `mk` the new `.dis` (or `make dis`), then **just relaunch that app
  inside the live desktop** to pick up the change — **no emu/VNC restart needed**.
  (An already-running instance keeps the old `.dis`; close and reopen it.)

- **C changes** (the emu VM itself, devices, or a builtin like `srv.c`) require
  rebuilding and reinstalling the **emu binary**, and installing is
  `cp o.emu → $OBJDIR/bin/emu`. Linux refuses to overwrite a **running**
  executable: the `cp` fails with `ETXTBSY` ("text file busy"), so `make emu`
  ends in `cp ... : exit status=exit(1)` while a desktop is using that binary.
  The compile itself succeeded — `emu/$SYSTARG/o.emu` is the fresh binary. To
  finish you must stop the running emu first (kill it by its **specific pid**,
  never `pkill -x emu`, which would also kill any other emu/desktop sessions),
  or test the new build by running `o.emu` directly from `emu/$SYSTARG/`.

> Generated, ABI-specific headers (`emu/Linux/srv.h`/`srvm.h`, `libinterp`'s
> `runt.h`/`*mod.h`) are removed on `clean`/`nuke` so a full `make` always
> regenerates them with the current-ABI `limbo`. See AGENTS_DUALABI.md for why this
> matters across a 32↔64-bit switch.

## mk Syntax vs make

| Concept | mk | make |
|---------|----|------|
| Include | `<file` | `include file` |
| Piped include | `<\| script` — execute script, use stdout as mkfile | N/A |
| Virtual target | `target:V:` — always run, no timestamp check | `.PHONY: target` |
| Quoted virtual | `target:QV:` — virtual + suppress echo | N/A |
| Pattern prefix | `&-Posix:QV:` — matches any `*-Posix` target; `$stem` = prefix | N/A |
| Object suffix | `$O` — set by mkfile-SYSTARG-OBJTYPE (usually `o`) | N/A |
| Stem in pattern | `$stem` | `$*` |
| Suffix pattern | `${LIBS:%=lib%.a}` | `$(LIBS:lib%.a)` |

**Piped include** is used for `mkdevlist`:
```
<| $SHELLNAME ../port/mkdevlist $CONF
```
The shell executes `mkdevlist emu`, which prints variable assignments to stdout, which `mk` reads as mkfile syntax.

## Building for aarch64

```sh
# From the repo root, cross-compiling on Linux/amd64:
mk 'SYSHOST=Linux' 'OBJTYPE=aarch64' all

# Or set in environment:
OBJTYPE=aarch64 mk all

# Build just emu:
cd emu/Linux && mk 'OBJTYPE=aarch64'

# Install:
mk 'SYSHOST=Linux' 'OBJTYPE=aarch64' install
```

The build recurses: top-level mkfile → each library dir → `emu/mkfile` → `emu/Linux/mkfile`.

## Files to Create for Linux/aarch64

| File | Template | Notes |
|------|----------|-------|
| `mkfiles/mkfile-Linux-aarch64` | `mkfiles/mkfile-Linux-arm` | Change CC/AS/LD to `aarch64-linux-gnu-gcc`, CPUS=aarch64, -DLINUX_AARCH64 |
| `emu/Linux/mkfile-aarch64` | `emu/Linux/mkfile-arm` | ARCHFILES=aarch64-tas.$O |
| `Linux/aarch64/include/lib9.h` | `Linux/arm/include/lib9.h` | 64-bit type adjustments |
| `Linux/aarch64/include/emu.h` | `Linux/arm/include/emu.h` | AArch64 FP register struct |

Source files (see AGENTS_PORT.md for content):

| File | Template |
|------|----------|
| `emu/Linux/aarch64-tas.S` | `emu/Linux/arm-tas-v7.S` (use ldaxr/stlxr) |
| `emu/Linux/asm-aarch64.S` | `emu/Linux/asm-arm.S` (umult, FPsave, FPrestore) |
| `emu/Linux/segflush-aarch64.c` | `emu/Linux/segflush-arm.c` (use `__builtin___clear_cache`) |

## Key Files

| File | Purpose |
|------|---------|
| `mkconfig` | Root configuration: ROOT, SYSHOST, SYSTARG, OBJTYPE |
| `mkfiles/mkhost-Linux` | Linux host tool definitions |
| `mkfiles/mkfile-Linux-arm` | ARM compiler/linker flags (nearest template) |
| `mkfiles/mkfile-Linux-386` | x86 compiler/linker flags |
| `mkfiles/mkdis` | Limbo .b → .dis compilation rules |
| `emu/mkfile` | Dispatches to emu/$SYSTARG/mkfile |
| `emu/Linux/mkfile` | Main emu build: OBJ list, link rule |
| `emu/Linux/mkfile-arm` | ARCHFILES for ARM |
| `emu/Linux/emu` | CONF: device/lib/port lists |
| `emu/port/mkdevlist` | Parses CONF → DEVS, PORT, LIBS vars |
| `emu/port/portmkfile` | Shared compilation pattern rules |
