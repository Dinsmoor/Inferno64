# tests/check — the `make check` pre-push gate

A manifest-driven capability gate. `make check` (→ `tests/check/run.sh`) runs the
matrix for the active platform and prints a `PASS/FAIL/SKIP/TODO` table, exiting
nonzero iff a cell marked `require` fails. It exists to stop the failure mode
where a config breaks *only* the headless build (the `raster3`-in-`emu-g` rot)
and rots the test path unnoticed — `emu-g` is a hard `require` cell here.

## Run

```sh
make check                 # gate for the current platform (Linux/$OBJTYPE)
```

It builds debug, does a `PROFILE=release` link-check, then restores the debug
tree, and runs the suites — expect a few minutes.

## The manifest

`platforms/<SYSTARG>-<OBJTYPE>.manifest` declares the matrix, one cell per line:

```
CHECK  CELL  STATUS  [NOTE...]
```

- **CHECK** — `build` | `test` | `doc`
- **STATUS** — `require` (must pass; FAIL fails the gate) · `skip` (not run;
  printed with reason) · `todo` (wanted but not yet wired/trusted; printed,
  never gates)
- **CELL grammar**
  - `build  <conf>[/release]` — conf = `emu` | `emu-g` | `emu-wrt`; `/release`
    link-checks the no-instrumentation build
  - `test   cunit` — dual-ABI C library unit tests
  - `test   {lp64,web}/<conf>/<runmode>` — runmode = `interp` | `jit` | `jitB`
  - `test   jitperf` — self-contained `c0`/`c1`/`c1B` bench + bit-equivalence
  - `doc    <name>`

The matrix is identical across platforms; only the **trust** (the STATUS)
differs. `Linux-amd64.manifest` marks the JIT run-mode cells `skip`
("comp-amd64.c unverified under LP64") rather than pretending they pass — keeping
a `skip`/`todo` cell listed (not deleted) is the point: untested surface stays
visible.

## Adding a platform / cell

Drop a `platforms/<SYSTARG>-<OBJTYPE>.manifest`. The driver dispatches test cells
to the existing suite runners (`tests/{cunit,lp64,web,jitperf}`), driving
`tests/lp64/run.sh` and `tests/web/run.sh` via their `EMU` / `EMUFLAGS` env
overrides to pick the binary and run-mode. The `doc man-coverage` cell is a
scoped `todo` (man-page-per-`/dis`-command, then per-flag) with no checker yet.
