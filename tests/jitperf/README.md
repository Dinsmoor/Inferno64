# tests/jitperf — JIT vs interpreter equivalence + micro-benchmarks

Profiling/equivalence harness for the aarch64 Dis JIT
(`libinterp/comp-aarch64.c`). The premise: run the **same** compiled `.dis`
under the interpreter (`emu -c0`) and the JIT (`emu -c1`) and require the value
output to be **bit-for-bit identical**, while timing a hot loop to measure the
speedup.

## Run

```sh
tests/jitperf/run.sh [iters]      # default 4_000_000
```

Output: the interpreter's value dump, an `EQUIVALENCE: PASS/FAIL` verdict
(stdout diff of `-c0` vs `-c1`, excluding the timing line), and a
`TIMING ... speedup=N.NNx` line. Exit 0 iff equivalent and fault-free.

## What's covered

- **`fp.b`** — native floating point (the first thing nativized after the
  integer/control core). Exercises every native FP opcode with **runtime**
  operands (so the Limbo compiler can't constant-fold the op away):
  - `IADDF/ISUBF/IMULF/IDIVF/INEGF`
  - `ICVTWF/ICVTLF` (int/big→real) and `ICVTFW/ICVTFL` (real→int/big,
    round-half-away-from-zero — the interpreter's rule, not RNE)
  - all six compares `IBEQF/IBNEF/IBLTF/IBLEF/IBGTF/IBGEF` (packed into a
    bitmask so one value captures every condition-code outcome)
  - a hot Leibniz-π + golden-ratio-walk loop mixing arithmetic and FP branches

  Typical result: equivalence PASS, ~3.3× faster under `-c1`.

## STFT spectrogram — DSP throughput (`stft.b` + `runbench.sh`)

A larger, "real work a user does" benchmark: a Short-Time Fourier Transform
spectrogram in **pure Limbo** — read a WAV → frame + Hann-window → radix-2
Cooley-Tukey FFT per frame → magnitudes → Inferno-colormap PNG (parameters
mirror the `rspektrum` analyzer: FFT 1024, 75% overlap, Hann, dB magnitude).
The PNG is written through the native `$Imageio->encode` (added alongside this).

Run it (needs `make all` first — for the FP-JIT and the `$Imageio->encode`):

```sh
make test_jitperf          # or: tests/jitperf/runbench.sh
```

It runs the **same** `stft.dis` under `-c0`, `-c1`, and `-c1 -B`, for two
kernels, and prints a `min_ms / med_ms / speedup / wall_ms` table:

- **`float`** — `real` (IEEE-double) butterflies. With FP now nativized this is
  the kernel that should show the JIT win on FP-heavy DSP.
- **`fixed`** — Q15 fixed-point (32-bit `int` mul + arithmetic shifts), the
  natively-compiled integer path. Kept as a contrast / regression baseline.

Methodology (keeps the comparison honest):
- Timed region is **pure Limbo** — windowing + FFT + magnitude only. `sin`/`cos`
  build the window/twiddle tables *outside* timing; only `sqrt` (per bin,
  identical count across configs) is a native call inside it.
- WAV decode, dB/colormap, and PNG encode are **outside** the timed loop.
- Report **min + median** over `-iter` runs (cold first run drops out);
  `EMUPOOLCHECK=0` so the GC audit can't skew timings. `wall_ms` (whole-process,
  incl. load + JIT compile) is reported separately as the launch-latency cost.
- **Correctness gate:** the rendered PNGs must be **byte-identical** across
  `-c0`/`-c1`/`-c1 -B` per kernel (a `DIFFERS!` flags a JIT miscompile) — same
  bit-for-bit premise as the `fp.b` equivalence check, on a full workload.
- Deterministic input: a linear-chirp WAV synthesized in-tree (clean diagonal
  in the spectrogram = visually self-verifying); no binary asset.

Knobs (env): `N`, `HOP`, `ITER`, `SR`, `DUR`, `KERNELS`, `CONFIGS`. Results land
in `_build/results.json`; spectrograms in `_build/spec_*.png`.

This is also a measurement bed for the next JIT levers: compiled-module caching
(amortize `wall_ms`), multithreaded/async background compilation, and
interpret-then-hot-swap (kill the launch-latency hit).

## Adding a case

Drop a `<name>.b` here that prints deterministic results to stdout and (if you
want a timing number) a single `TIME ... ms=<n>` line to stderr. Keep every
operand runtime-derived (array element / variable / loop counter) or the
compiler folds the arithmetic and the JIT path never runs. Then point a runner
at it the same way `run.sh` does. The intended growth path (Tyler) is a fuller
profiling suite; this is the seed.
