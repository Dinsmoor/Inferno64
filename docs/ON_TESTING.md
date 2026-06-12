# So you want to test Inferno64? — the suites, the gate, and which one you need

Everything testable lives under `tests/`, one directory per suite, each with
its own README for the details. This doc is the map: what each suite covers,
which one your change needs, and the conventions they all share.

The one command to know:

```sh
make check        # the pre-push gate: builds + every required suite, PASS/FAIL matrix
```

`make check` runs the per-platform capability matrix declared in
`tests/check/platforms/<SYSTARG>-<OBJTYPE>.manifest` and exits nonzero iff a
`require` cell fails. Run it before pushing; expect a few minutes (it builds
debug, link-checks release, restores debug, then runs the suites).

## The map: layer → suite

| you changed… | run | suite |
|---|---|---|
| portable C libraries (`lib9`, `libbio`, `libmp`, `libsec`, `libmath`, …) | `make test_all_unit` (or `make test_lib9_unit` etc.) | [`tests/cunit/`](../tests/cunit/README.md) |
| anything endian- or width-sensitive in those libs | `tests/cunit/cross.sh arm` (ILP32) / `cross.sh m68k` (big-endian) | [`tests/cunit/`](../tests/cunit/README.md) |
| the Dis VM, the Limbo compiler, GC, channels, modules | `tests/dis/run.sh` | [`tests/dis/`](../tests/dis/README.md) |
| the JIT (`libinterp/comp-*.c`) | `make test_jitperf` + the `dis/<conf>/jit` cells | [`tests/jitperf/`](../tests/jitperf/README.md) |
| Charon / the web stack (CSS, layout, JS) | `tests/web/run.sh` | [`tests/web/`](../tests/web/README.md) |
| the native kernel (`os/`) | `tests/kernel/run.sh` (`HWTARG=` picks the board) | [`tests/kernel/`](../tests/kernel/README.md) |
| any C that crosses a 64→32-bit boundary | `make lint` | [`tests/lint/`](../tests/lint/README.md) |
| GUI behaviour you need to *see* | `tests/dis/scenario.sh` / `tests/dis/gui_sweep.sh` | [`tests/dis/`](../tests/dis/README.md) |

A change rarely needs every suite directly — `make check` runs the required
set for you. Run a suite by hand when you are iterating on the thing it
covers.

## The suites in one paragraph each

**`tests/cunit/` — C unit tests.** Plain C tests linked against the built
static libs, one directory per library section; `run.sh` derives the compiler
and flags from the active arch mkfile so the same tests build under either
Dis ABI. Assertions must be width-safe (rules in `cunit.h`). Test binaries
run under a 60-second timeout, so a hang is a FAIL, not a wedged run.

**`tests/cunit/cross.sh` — the cross-ABI canaries.** Every developer machine
here is 64-bit little-endian; the canaries keep the 32-bit ABI (`arm`) and
big-endian byte order (`m68k`) honest by cross-building the portable libs and
running the cunit sections under qemu-user. Cross objects use Plan 9 object
letters (`*.5`, `*.2`) so they coexist with the host `*.o` — no clean/nuke
dance. These are `require` cells (`cunit/arm`, `cunit/m68k`) in the gate.

**`tests/dis/` — the Dis VM + Limbo regression suite.** Headless,
TAP-emitting Limbo programs run end-to-end under `emu-g` (no display): VM
semantics, concurrency, crypto builtins, Styx, the loader, exceptions, module
globals, self-hosting the compiler. The gate runs it under both `interp` and
`jit` run-modes (`dis/<conf>/<runmode>` cells). Also home to `scenario.sh`
(deterministic headless GUI runs with a JSON verdict + screenshots) and
`gui_sweep.sh` for desktop apps.

**`tests/jitperf/` — JIT equivalence + throughput.** Runs the same `.dis`
under `emu -c0`, `-c1`, and `-c1 -B`, requires bit-identical output, and
times a hot loop. It is a correctness gate first and a benchmark second.

**`tests/web/` — the Charon rendering bench.** A deterministic CSS/layout
core plus a visual tail (`render.sh`) against pinned fixtures and a real
testbed site.

**`tests/kernel/` — native-kernel end-to-end.** Boots the built kernel image
once per test under the board's qemu profile (`os/boards/<board>/qemu.json`)
and drives the serial console: boot, networking, DNS, disk persistence, TLS
verification, import/export against a hosted emu, and a screendump check that
the desktop renders. Board-agnostic: `HWTARG=` selects the board; a board
without a qemu profile is a clean TAP SKIP.

**`tests/lint/` — the narrowing lint.** clang's `-Wshorten-64-to-32` replayed
over exactly the files the real build compiles, diffed against a triaged
baseline. This is the LP64 bug class as a compile-time check; `make lint`
fails only on *new* narrowings.

**`tests/check/` — the gate itself.** The manifest grammar, how cells map to
the suite runners, and how to add a platform or cell:
[`tests/check/README.md`](../tests/check/README.md).

## Conventions every suite follows

- **TAP output** (`ok` / `not ok` / `1..N`), aggregated by each suite's
  `run.sh`. Exit status is the verdict; the gate only trusts exit status plus
  positive evidence.
- **Positive evidence, not absence of failure.** A run that produces no TAP
  output is a FAIL, not a pass — a stale or crashing harness must not score
  green. Suites rebuild their own stale artifacts (`tests/web/run.sh` checks
  toolchain staleness; `tests/kernel/run.sh` rebuilds the image) for the same
  reason: a stale binary is a false verdict.
- **Headless and repeatable.** No suite needs a display; GUI verification
  goes through `scenario.sh`'s virtual framebuffer + screenshot path.
- **Hangs are failures.** Long-running test binaries run under timeouts
  (cunit: 60 s per binary; the dis and kernel harnesses bound each step), so
  a deadlock surfaces as a red cell instead of a stuck gate.
- **Env knobs over editing.** Suites take `EMU=`, `EMUFLAGS=`, `KERNEL=`,
  `HWTARG=`, `RUN=` overrides so the gate (and you) can point them at a
  different binary, run-mode, board, or executor without touching the script.
- **Untested surface stays visible.** Manifest cells are marked `skip` or
  `todo` rather than deleted; a capability nobody runs should still appear in
  the matrix.

## Adding a test

1. Pick the suite that owns the layer (table above) and read its README —
   each one documents its own "adding a test" recipe.
2. If the new coverage is a *capability* (a new conf, run-mode, board, or
   ABI), it also gets a manifest cell in
   `tests/check/platforms/*.manifest` — `todo` until it's trusted, then
   `require`.
3. Debugging a failure? Limbo-level: [`ON_DEBUGGING.md`](ON_DEBUGGING.md).
   emu C-level: [`ON_EMU_DEBUG.md`](ON_EMU_DEBUG.md). Heap corruption:
   [`ON_C_IN_DIS.md`](ON_C_IN_DIS.md#debugging-heap-corruption-when-prevention-fails).
