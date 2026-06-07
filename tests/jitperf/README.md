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

## Adding a case

Drop a `<name>.b` here that prints deterministic results to stdout and (if you
want a timing number) a single `TIME ... ms=<n>` line to stderr. Keep every
operand runtime-derived (array element / variable / loop counter) or the
compiler folds the arithmetic and the JIT path never runs. Then point a runner
at it the same way `run.sh` does. The intended growth path (Tyler) is a fuller
profiling suite; this is the seed.
