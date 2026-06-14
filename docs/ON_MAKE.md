# The build system — every make target and option

There are **two make systems** in this tree, plus the Plan 9 `mk` tool under one
of them:

| layer | builds | tool | entry |
|---|---|---|---|
| **root `Makefile`** | the hosted system: `emu` (the C side) + the Dis/Limbo tree | GNU make wrapping **`mk`** | `make` at the repo root |
| **native kernel** | bare-metal kernel images (`os/<arch>` + `os/boards/<board>`) | GNU make + `gcc` only (no `mk`) | `make image-<board>` at the root, or `cd os/<arch> && make` |

The root `Makefile` is the front door for both: it drives the hosted build
directly and **dispatches** native image builds into `os/<arch>`. You rarely
need to invoke `mk` by hand — the root `Makefile` orchestrates it (and bootstraps
it on a fresh tree).

A build is **always a full, coherent nuke+rebuild** of both halves of the hosted
system on purpose: a stale `.dis` against a freshly built compiler/ABI is a real,
debugged crash class. `make all` is cheap (the heavy vendored C libs are
content-cached — per-signature object slots, so a debug↔release profile flip
restores the prior build's objects instead of recompiling); half builds are
gated behind `FORCE=1`.

---

## Quick map — common tasks

| you want to… | run |
|---|---|
| build everything and poke at it | `make run` (build + launch the GUI desktop) |
| just build the hosted system | `make` (== `make all`) |
| a faster/optimized hosted build | `make release` or `make bleedingedge` |
| build a native kernel image | `make image-virt64` |
| list native boards + their arch | `make boards` |
| run the pre-push gate | `make check` |
| C unit tests | `make test_all_unit` |
| the 64→32 narrowing lint | `make lint` |
| see this, tersely | `make help` |

---

## Root `Makefile` — the hosted system (emu + Dis tree)

### Targets

| target | what it does |
|---|---|
| `all` (default) | full coherent build: the C side (`_emu`) then the Dis tree (`_dis`). The only coherent build; your default. |
| `debug` / `release` / `bleedingedge` | `make all` in that profile (see `PROFILE`). |
| `run` | full build (in `RUNPROFILE`) then launch the GUI desktop (`wm/wm`). Needs `$DISPLAY`; on a headless box it tells you to use `scripts/headless_vnc.sh`. |
| `emu` | C side only. **Gated** — refuses without `FORCE=1` (leaves the `.dis` tree stale against a new ABI). |
| `dis` | Dis tree only. Same gate (`FORCE=1`). |
| `bootstrap` | (re)build the `mk` binary if missing (a fresh tree/worktree has none). Runs automatically as a prerequisite too. |
| `clean` | remove object files. |
| `nuke` | remove objects **and** the generated `.dis` tree + the vendored-lib slot cache. |
| `check` | the pre-push gate: builds each required CONF, runs every required suite (cunit, dis+web, jitperf), prints a PASS/FAIL/SKIP matrix. Exits nonzero iff a required cell fails. |
| `test_all_unit` | C unit tests for every section under `tests/cunit/`. |
| `test_<section>_unit` | one section, e.g. `make test_lib9_unit`. |
| `test_jitperf` | JIT-vs-interpreter throughput benchmark (pass `ARGS=…`). |
| `lint` / `lint-all` / `lint-update` | the `-Wshorten-64-to-32` narrowing lint / include everything / refresh the baseline. |
| `emu-disptrcheck` | debug relink of `emu` with the Dis-pointer checker (`-DDISPTRCHECK`). Slow; run `make all` afterwards to revert. |
| `image-<board>` | build a native kernel image (see the native section). |
| `boards` | list native boards and their arch. |
| `help` | terse quick reference. |

### Variables (override on the command line: `make VAR=value target`)

| variable | default | meaning |
|---|---|---|
| `OBJTYPE` | `aarch64` | hosted target arch. Both LP64 archs share the whole Dis ABI / `.dis` tree; only per-arch glue differs. On an x86-64 host: `make OBJTYPE=amd64 all`. |
| `CONF` | `emu` | emu configuration: `emu` (full GUI: X11 + freetype + tk + draw) or `emu-g` (graphics-less headless; faster; what `tests/dis` runs under). |
| `PROFILE` | `debug` | optimization/instrumentation bundle: `debug` (`-Og` + DISPTRCHECK + EMUCRASH-on; find-the-bug), `release` (`-O2`, portable), `bleedingedge` (`-O3 -march=native`). |
| `NPROC` | host CPUs − 1 (≥1) | parallel compile jobs. The tree-wide default for every entry point. |
| `NOCACHE` | _(unset)_ | `NOCACHE=1` bypasses the per-signature slot cache and forces a full rebuild of the vendored libs (`libfreetype`, `libmbedtls`, `libstb`, `libwebp`). |
| `FORCE` | _(unset)_ | `FORCE=1` opts in to a gated half build (`make emu FORCE=1`). |
| `RUNPROFILE` | `bleedingedge` | profile `make run` builds with. |
| `RUNGEOM` | `1280x800` | desktop geometry for `make run`. |
| `ARGS` | _(unset)_ | extra flags forwarded by `test_jitperf`. |

Profiles report **relative** benchmark numbers on `debug` (the checker taxes
interp and JIT equally); use `release`/`bleedingedge` for absolute numbers.

---

## Native kernel images (`os/<arch>` + `os/boards/<board>`)

This half is standalone GNU make + `gcc` (host or cross), no `mk`. An image is
one self-contained ELF that embeds its whole root filesystem — `-kernel
i<board>.elf` is the entire boot story (no disk/initrd).

### Front door (from the repo root)

The board's CPU arch is read from its manifest, so you **never name the arch**:

```sh
make image-virt64                          # → os/aarch64/ivirt64.elf
make image-virt64 USERSPACE=headless GIC=v3   # knobs pass straight through
make boards                                # list boards + their arch
```

`make image-<board>` reads `ARCH := <arch>` from `os/boards/<board>/board.mk`
and dispatches `make -C os/<arch> image HWTARG=<board>`. Command-line knobs
forward automatically (they ride `MAKEFLAGS`). A board built in the wrong arch
dir (`cd os/arm && make HWTARG=virt64`) fails immediately — `native.mk`
cross-checks the board's `ARCH` against the arch dir's `KARCH`.

### Or build inside the arch dir directly (equivalent)

```sh
cd os/aarch64
make                 # == make image → ivirt64.elf
make run             # boot it under qemu (the board's board.mk says how)
make clean           # remove every board's build-*/ and i*.elf
```

### Targets

| target | what it does |
|---|---|
| `image` (default) | build `i<board>.elf` for `HWTARG`. |
| `run` | boot the image (the board's `board.mk` supplies the qemu/U-Boot recipe). |
| `clean` | `rm -rf build-* i*.elf` (all boards). |

### Variables

| variable | default | meaning |
|---|---|---|
| `HWTARG` | `virt64` | which board (`os/boards/<HWTARG>/`). |
| `USERSPACE` | `full` | baked-in root profile: `full` (`dis fonts icons lib module man locale`) or `headless` (`dis lib module locale`; ~36 MB→20 MB, no GUI assets). |
| `PARANOID` | `1` | `POOLPARANOID` — the pool free-tree audit on every alloc/free. `PARANOID=0` for a much faster kernel. |
| `GIC` | `v2` _(board knob)_ | interrupt-controller driver for qemu-virt-class boards: `v2` or `v3` (`v3` also selects the matching qemu machine in the run target; needed for MSI/LPIs). |
| `CROSS` | _(empty)_ | toolchain prefix for cross-building, e.g. `CROSS=aarch64-linux-gnu-`. Empty = native host toolchain. |
| `DISK` | _(unset)_ | `make run DISK=/path/raw.img` attaches a persistent virtio-blk disk (board knob). |
| `NPROC` | host CPUs − 1 | parallel jobs (same formula as the root). |

Switching a value-only knob (`GIC`, `USERSPACE`) touches no file timestamp, so
`native.mk` keeps a `.varstamp` and forces the affected relink when it changes —
you never get a stale kernel that still contains the old driver.

### How an image's contents are decided (the manifest)

Composition is **declarative** — no build-invocation flags pick drivers:

- `os/<arch>/Makefile` — thin: states only what is the arch's (`KARCH`, arch C/asm
  sources, codegen flags, the toolchain `CROSS`), then `include ../native.mk`.
  **The ABI/word-width lives here and nowhere else.**
- `os/boards/<board>/board.mk` — the board manifest: `ARCH`, its own sources
  (`BOARDC`), its driver picks (`DRIVERC` + `include ../drivers/groups/*.mk`),
  and how to `run`.
- `os/boards/<board>/<board>` — the kernel config (devices/links/root), fed to
  `mkdevc`/`mkroot`.
- `os/drivers/groups/<family>.{mk,conf}` — reusable, arch-neutral driver-family
  name lists a board includes in one line.

So adding a board or a whole new arch needs **no change to the front door**: get
the manifests right and `make image-<board>` just works. A driver is portable to
both ABIs by source discipline (fixed-width types), not by any build switch — see
[ON_PORTING_HW_DRIVERS.md](ON_PORTING_HW_DRIVERS.md). Only `os/aarch64` exists
today; a 32-bit board would declare `ARCH := arm`, add `os/arm/Makefile`
(toolchain only), and reuse every width-clean driver and group manifest unchanged.

---

## The `mk` underneath (hosted side only)

The hosted build's per-component compilation is done by Plan 9 **`mk`** (driven
by `mkfile`s), which the root `Makefile` wraps. You normally don't call it
directly; the wrapper exists because `mk`'s incremental dependency tracking is
unreliable across ABI/compiler changes, so the wrapper nukes each component
before rebuilding in the dependency order it extracts from the top-level
`mkfile`'s `EMUDIRS`. `make bootstrap` builds `mk` itself with the host `gcc`
when a fresh tree has no `mk` binary yet. The native kernel half does **not** use
`mk` at all.

---

## Recipes

```sh
# Hosted: try it now (build + GUI desktop)
make run
make run RUNPROFILE=debug RUNGEOM=1920x1080

# Hosted: headless / x86-64 host / optimized
make CONF=emu-g all
make OBJTYPE=amd64 all
make release

# Native: the default board, headless+fast, then boot under qemu
make image-virt64 USERSPACE=headless PARANOID=0
cd os/aarch64 && make run

# Native: cross-build from an x86-64 host
cd os/aarch64 && make CROSS=aarch64-linux-gnu- image

# Verify before pushing
make check
make test_all_unit
make lint
```
