# Building & hacking on Inferno64

This is the developer guide. If you just want to *run* it, the README's "Try it"
section (`make run`) is all you need. This covers the build system, the emulator
command line, catching the LP64 heap bugs, and how the project is developed.

- [Building](#building)
- [Build profiles](#build-profiles)
- [Why `make`, not `mk` directly](#why-make-not-mk-directly)
- [Running emu directly](#running-emu-directly)
- [Debugging: catching the heap bugs](#debugging-catching-the-heap-bugs)

See also [`INSTALL`](INSTALL) (prerequisites, amd64 notes), [`LP64_NOTES.md`](LP64_NOTES.md)
(the porting retrospective), and [`ref/AGENTS_*.md`](ref/) (per-subsystem references;
start at [`ref/AGENTS_DUALABI.md`](ref/AGENTS_DUALABI.md)).

## Building

From a clean checkout or a fresh `git worktree`:

```sh
make all                  # full build, Linux/aarch64 (the default)
make OBJTYPE=amd64 all     # x86-64 host instead
make help                  # one-screen summary + current build settings
```

Bare `make` is the same as `make all`. The build is self-contained: a fresh tree
has no `mk` (it's build output, not checked in), and `make` bootstraps it from the
host `gcc` automatically — no pre-existing toolchain required. Output lives under
`Linux/$OBJTYPE/{bin,lib,include}` and `dis/` (all gitignored), so each worktree
needs its own one-time `make all`.

| command | what it does |
|---|---|
| `make` / `make all` | full coherent build (`debug` profile): C side (host libs → the `limbo` compiler → `emu`), then the Dis tree (`appl/*.b` → `dis/`) compiled with that freshly built `limbo` |
| `make run` | full build **and launch** the graphical desktop — always rebuilds (never launches a stale binary), `RUNPROFILE=bleedingedge` by default |
| `make debug` / `release` / `bleedingedge` | `make all` in the named [profile](#build-profiles) |
| `make check` | **pre-push gate**: builds every required config (incl. the headless `emu-g` and a release link-check) and runs the test suites, printing a PASS/FAIL/SKIP/TODO matrix; nonzero exit if a required cell fails, so a headless-only break can't reach master unnoticed |
| `make clean` / `make nuke` | remove object files / objects + library archives + installed `.dis` |
| `make emu` / `make dis` | C-side-only / Dis-tree-only **half** builds — gated behind `FORCE=1`, since on their own they leave the two halves out of sync |

## Build profiles

A profile bundles an optimization level, `-march` target, and instrumentation:

| profile | what | use it for |
|---|---|---|
| `debug` (default) | `-Og`, the DISPTRCHECK GC pointer-checker, `EMUCRASH` crash-dump auto-on | day-to-day work — turns silent heap corruption into a clean cored fault |
| `release` | `-O2`, portable `-march` baseline, no instrumentation | a fast/distributable binary |
| `bleedingedge` | `-O3 -march=native`, no instrumentation | host-tuned, the snappiest local run |

The default `make all` builds **debug** on purpose: it's intentionally slower
while the LP64 port matures. Develop on `debug` and benchmark *relative* numbers
there; use `release`/`bleedingedge` for a fast binary and absolute figures.
`make all` records the profile it built in `Linux/$OBJTYPE/.buildmode`.

## Why `make`, not `mk` directly

The system is built by Plan 9 `mk` (every component directory has an `mkfile`),
and `mk install` / `mk clean` / `mk nuke` still work fine *inside a single
directory*. But driving a whole-system build by hand is a foot-gun, so the
top-level GNU `Makefile` wraps `mk` and is the only coherent entry point:

- **`mk`'s incremental dependency tracking is unreliable here** — a stale object,
  or a stale `.dis` linked against a freshly rebuilt ABI, is a real and
  previously-debugged crash class. `make` **nukes objects between components** so
  nothing stale survives. A full rebuild is cheap (~10s on a fast box). The one
  exception is the heavy *vendored* libraries (libfreetype, libmbedtls, libstb),
  which only change on a manual source update: those are skipped when a content
  signature shows them unchanged (`mkfiles/libcache.sh` — hashes every vendored
  source file by path, the headers they include, the build flags, the ABI, and the
  compiler). Any change busts the signature and forces a full rebuild of that lib,
  so a dependency update can never be served stale. `make all NOCACHE=1` (and
  `make clean`/`nuke`) bypass the cache entirely. No third-party tools — just make,
  the compiler, and coreutils.
- **both halves must be built in the right order** — the C side produces the
  `limbo` compiler that then compiles the Dis tree; `make` sequences this and
  **regenerates the per-ABI module headers**, so a 32↔64-bit switch can't link
  wrong-width stubs.
- `make` also warns if an `emu` is running while you rebuild — overwriting its
  files underneath it produces crashes that look like real bugs.

## Running emu directly

`make run` is just a wrapper; you can launch the emulator straight out of the
build tree. `-r"$PWD"` makes the repo root the Inferno root, and the final
argument is the first Dis program to run:

```sh
./Linux/aarch64/bin/emu -r"$PWD" -g1280x800 wm/wm     # graphical desktop (needs X)
./Linux/aarch64/bin/emu -r"$PWD" /dis/sh.dis           # just a shell, no GUI
./Linux/aarch64/bin/emu -c1 -r"$PWD" -g1280x800 wm/wm  # via the AArch64 JIT (-c1)
```

On an x86-64 host the binary is at `./Linux/amd64/bin/emu`. For a headless box,
run emu under a virtual framebuffer (e.g. `Xvfb :3` + a VNC server) and point
`DISPLAY` at it before launching `wm/wm`.

**To shut emu down, type `^\` (Ctrl-\\) at the console it was launched from** —
that is the hard-kill escape hatch (emu reminds you on startup). `^C` is *not* a
host kill: emu runs the terminal in raw mode and passes `^C` through to Inferno as
a normal byte (so a shell/line-editor inside emu can use it).

**The JIT (`-c1`).** `-c` takes a level (`-c1`…`-c9`); any non-zero value turns the
compiler on, `-c0` (the default) is the pure interpreter. `emu -v` prints `compile`
vs `interp`. The JIT compiles every module **eagerly at load time**, so `-c1` makes
the desktop slower to start and only pays off for **compute-bound** Limbo — the GUI
is IO-bound and the heavy work (`$Raster3`, image decode, TLS) is already native C.
For interactive use prefer the interpreter; reserve `-c1` for batch/benchmark work.
Leave `-B` (which disables the JIT's array-bounds checks) **off** while chasing
heap bugs. See [`ref/AGENTS_JIT.md`](ref/AGENTS_JIT.md) for the trade-off.

## Debugging: catching the heap bugs

Most of the remaining LP64 bugs are heap corruption, which is hard to narrow down.
The goal of the setup below is that the *very first* time something faults you get
a clean core dump + log, instead of having to reproduce an intermittent crash.

**1. Tell the host kernel where to drop cores (once per boot):**

```sh
sudo mkdir -p /tmp/inferno-cores
echo '/tmp/inferno-cores/core.%e.%p.%t' | sudo tee /proc/sys/kernel/core_pattern
```

(`%e` program, `%p` pid, `%t` timestamp. The directory must exist and be writable.
To make it survive reboots put `kernel.core_pattern=...` in `/etc/sysctl.d/`.)

**2. Raise the core-size limit in the shell you launch emu from:** `ulimit -c unlimited`

**3. Leave ASLR on.** Several of these bugs only surface at high addresses, so do
**not** run emu under `setarch -R` (ASLR-off) — let the host randomize the address
space; that is what provokes the fault.

**4. Launch emu with the crash/observability env vars:**

```sh
ulimit -c unlimited
env EMUCRASH=1 EMUWATCHDOG=60 \
    ./Linux/aarch64/bin/emu -r"$PWD" -g1280x800 wm/wm
```

- `EMUCRASH=1` — a wild/illegal Dis fault aborts the process immediately (dumping
  a core) instead of being swallowed into a Dis exception that can silently wedge
  the VM. **This is the important one** (and it is on by default in `debug`
  builds) — without it an intermittent heap-corruption fault often just leaves a
  zombie/hung emu and the evidence is gone.
- `EMUWATCHDOG=60` — if the VM hangs for 60s (a deadlock rather than a hard fault)
  the watchdog prints a dump of every Dis thread so you can see who is stuck.
- `kill -USR2 <emu-pid>` forces the same Dis thread dump from a live (or
  apparently-hung) emu at any time.

**5. When you get a core, hand it straight to gdb:**

```sh
gdb ./Linux/aarch64/bin/emu /tmp/inferno-cores/core.emu.<pid>.<ts>
(gdb) bt              # host C backtrace at the fault
(gdb) info registers  # the faulting address is usually a smashed pointer
```

The fault message emu prints on the way down names the Dis module, the builtin
(e.g. `Charon[$Sys]`), and a `pc=`; map that `pc` back to a Limbo source line with
the module's `.sbl` file (`limbo -g` output). See
[`ref/AGENTS_DEBUGGING.md`](ref/AGENTS_DEBUGGING.md) for the full workflow.

For *how* this project is developed (the "demon machine" workflow — driving the
desktop with `xdotool` over VNC, the gdb-mcp harness), see the
[README](README.md#demon-machine-based-development).
