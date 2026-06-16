# tests/sparse — LP64 pointer / Dis-address-space static analysis

Runs Linus Torvalds' [sparse](https://sparse.docs.kernel.org/) over the emu and
libinterp C to catch two bug classes the compiler and `make lint` miss:

* the **cast** form of pointer↔`WORD` truncation on LP64 (`(uint32_t)ptr`, a
  32-bit field holding an address) — `-Wcast-truncate`, "non size-preserving";
* **Dis/userspace addresses** dereferenced as trusted host pointers, via the
  `__dis` address-space tag (`include/disptr.h`).

It is a baseline-diff gate, green by default, exactly like `tests/lint`.

## Use

```
make sparse          # NEW warnings vs baseline.txt (the gate)
make sparse-all      # every high-signal warning
make sparse-update   # regenerate baseline.txt after triaging
make sparse-raw      # unfiltered sparse output
```

Full rationale, the `__dis` pattern, and the `progheap` worked example:
[`docs/ON_SPARSE.md`](../../docs/ON_SPARSE.md).

## Files

| file | role |
|---|---|
| `run.sh` | the harness — replays `mk -n` flags, swaps gcc→sparse, filters, diffs baseline |
| `build-sparse.sh` | builds sparse from kernel.org into `.sparse/` (no install/root); prints the binary path |
| `baseline.txt` | known/accepted warnings; anything else fails the gate |
| `selfcheck.sh` + `selfcheck/disptr-demo.c` | prove the `__dis` gate still catches bad patterns |
| `.sparse/`, `.out/` | build artifacts (gitignored) |

## Self-check

```
SPARSE=$(sh tests/sparse/build-sparse.sh) sh tests/sparse/selfcheck.sh
```

Asserts that a direct deref of a `__dis` pointer and leaking one as a host
pointer both warn, and the laundered (`disptr()`) path is clean. If `__dis` ever
stops catching an unvalidated use, this fails — the gate that guards the kernel
is itself guarded.
