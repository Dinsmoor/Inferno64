# Building & hacking on Inferno64

This is the developer guide. If you just want to *run* it, the README's "Try it"
section (`make run`) is all you need. This covers the build system, the emulator
command line, catching the LP64 heap bugs, and how the project is developed.

- [Prerequisites](#prerequisites)
- [Building](#building)
- [Build profiles](#build-profiles)
- [Why `make`, not `mk` directly](#why-make-not-mk-directly)
- [Running emu directly](#running-emu-directly)
- [Debugging: catching the heap bugs](#debugging-catching-the-heap-bugs)

See also the per-subsystem "so you want to…" references in [`ref/`](ref/) — start
at [`ref/ON_C_IN_DIS.md`](ref/ON_C_IN_DIS.md) for the 32/64-bit story.

## Prerequisites

A host C toolchain (`gcc`, `ar`), GNU `make`, and the usual coreutils
(`sha256sum`, `find`). For the default graphical `emu` you also need the X11 build
headers — on Debian/Ubuntu:

```sh
sudo apt-get install build-essential libx11-dev libxext-dev
```

FreeType, mbedTLS, and stb are **vendored in-tree** (`libfreetype/`, `libmbedtls/`,
`libstb/`), so you don't need system versions of those. A headless, graphics-less
build (`CONF=emu-g`) needs no X11 headers at all. Plan 9's `mk` build tool is
**not** a prerequisite — `make` compiles it from the host `gcc` on the first build
(see [below](#why-make-not-mk-directly)).

Supported hosts: Linux **aarch64** (the default) and **amd64** (build with
`make OBJTYPE=amd64 all`).

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

Two reasons — one about correctness, one about portability:

- **`mk` doesn't guarantee it rebuilds everything that changed.** Its incremental
  dependency tracking is unreliable here, and a stale object — or a stale `.dis`
  linked against a freshly rebuilt ABI — is a real, previously-debugged crash class.
- **`make` runs pretty much everywhere.** Wrapping the build in GNU `make` improves
  portability, gives one coherent entry point instead of a hand-driven recursive
  `mk`, and makes it easy to add build rules and profiles.

The system is still built by Plan 9 `mk` underneath (every component directory has
an `mkfile`, and `mk install` / `mk clean` / `mk nuke` work fine *inside a single
directory*); the top-level `Makefile` just drives it correctly:

- **It nukes objects between components**, so nothing stale survives a build. A
  full rebuild is cheap (~10s on a fast box). The one exception is the heavy
  *vendored* libraries (libfreetype, libmbedtls, libstb), which only change on a
  manual source update: those are skipped when a content signature shows them
  unchanged (`mkfiles/libcache.sh` — hashes every vendored source file by path, the
  headers they include, the build flags, the ABI, and the compiler). Any change
  busts the signature and forces a full rebuild of that lib, so a dependency update
  can never be served stale. `make all NOCACHE=1` (and `make clean`/`nuke`) bypass
  the cache entirely. No third-party tools — just make, the compiler, and coreutils.
- **It builds both halves in the right order** — the C side produces the `limbo`
  compiler that then compiles the Dis tree; `make` sequences this and
  **regenerates the per-ABI module headers**, so a 32↔64-bit switch can't link
  wrong-width stubs.
- **It warns if an `emu` is running** while you rebuild — overwriting its files
  underneath it produces crashes that look like real bugs.

## Running emu directly

`make run` is just a wrapper; you can launch the emulator straight out of the
build tree. `-r"$PWD"` makes the repo root the Inferno root, and the final
argument is the first Dis program to run:

```sh
./Linux/aarch64/bin/emu -r"$PWD" -g1280x800 wm/wm     # graphical desktop (needs X)
./Linux/aarch64/bin/emu -r"$PWD" /dis/sh.dis           # just a shell, no GUI
./Linux/aarch64/bin/emu -c1 -r"$PWD" -g1280x800 wm/wm  # via the AArch64 JIT (-c1)
```

On an x86-64 host the binary is at `./Linux/amd64/bin/emu`. For a headless box
(no monitor, or over SSH), don't wire up the framebuffer by hand —
**[`scripts/headless_vnc.sh`](../scripts/headless_vnc.sh)** does it for you: it
starts `Xvfb` + a VNC server, launches the desktop, and prints exactly how to
connect (an SSH tunnel + your VNC client). `scripts/headless_vnc.sh stop` tears it
down. (`make run` points you here too when `$DISPLAY` is empty.)

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
heap bugs. See [`ref/ON_JIT.md`](ref/ON_JIT.md) for the trade-off.

## Debugging: catching the heap bugs

The remaining LP64 bugs are mostly heap corruption, and the `debug` profile is
built to catch them: it defaults `EMUCRASH` on (a wild Dis fault drops a core *at
the writer* instead of wedging the VM) and builds the `DISPTRCHECK` GC checker. The
short version is **build `debug`, reproduce, get a core, `gdb` it**:

```sh
sudo sh -c 'mkdir -p /tmp/inferno-cores; \
  echo /tmp/inferno-cores/core.%e.%p.%t > /proc/sys/kernel/core_pattern'   # once per boot
ulimit -c unlimited
env EMUCRASH=1 EMUWATCHDOG=60 ./Linux/aarch64/bin/emu -r"$PWD" -g1280x800 wm/wm
gdb ./Linux/aarch64/bin/emu /tmp/inferno-cores/core.emu.<pid>.<ts>     # bt; info registers
```

Leave ASLR **on** (don't use `setarch -R`) — it provokes the high-address faults.
The full story — *why* this corruption happens (a 64-bit pointer truncated into a
32-bit Dis slot), how to prevent it, the step-by-step recipe, and the `LIMBRUL`
electric-fence — is in
**[`ref/ON_C_IN_DIS.md`](ref/ON_C_IN_DIS.md#debugging-heap-corruption-when-prevention-fails)**.

For *how* this project is developed (the "demon machine" workflow — driving the
desktop with `xdotool` over VNC, the gdb-mcp harness), see the
[README](../README.md#demon-machine-based-development).
