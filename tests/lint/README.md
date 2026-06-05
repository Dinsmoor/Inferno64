# tests/lint — clang 64→32 narrowing lint

The LP64 bug class in this dual-ABI tree is *a 64-bit value silently narrowed
to 32 bits as it crosses a boundary* (`int x = somelong;`, `(int)ptr`, a 9P
field truncated, …). It compiles cleanly under gcc and only misbehaves when the
high 32 bits are nonzero, so it is exactly the kind of thing a warning should
catch. clang has a warning for precisely this — **`-Wshorten-64-to-32`** — and
gcc does not. This harness runs clang purely as an analysis pass; gcc stays the
production compiler.

## Running

    make lint            # report NEW narrowings vs the baseline; nonzero if any
    make lint-all        # list every narrowing site (no baseline comparison)
    make lint-update     # regenerate the baseline after triaging

Needs `clang` and a built tree (`make emu`): the runner asks `mk -n -a` for the
exact compile command of every host C file (libs + emu), so the include paths
and `-D` defines match the real build byte-for-byte, then replays each `.c`
through `clang -fsyntax-only -Wno-everything -Wshorten-64-to-32`. No `.o` is
produced and the gcc build is untouched.

## The baseline

`baseline.txt` is the curated set of *known* narrowings (same idea as
`libinterp/valgrind-inferno.supp`). `make lint` diffs the current set against it:

- a **new** entry fails the run (`+ file: warning: …`) — triage it;
- an entry that no longer warns is reported as fixed (`- …`) — rerun
  `make lint-update` to drop it from the baseline.

The baseline key is **file + conversion kind** (the source line/column are
stripped so the baseline doesn't churn every time code moves). The trade-off:
a brand-new narrowing of a kind a file *already* has won't stand out — so when
touching a file that appears in the baseline, run `make lint-all` and eyeball
that file's sites directly.

Most of the 246 baselined sites are in upstream lib9/libbio formatting/utf code
and in length/IO-count locals that are benign on both ABIs. The point of the
tool is the **next** narrowing, in new or changed code — the same class that
produced the real bugs already fixed here (`strtoull`, `mptov`; see the cunit
suite and `ref/AGENTS_DEBUGGING.md` → "Runtime observability").

## Notes / limits

- aarch64-specific `-march=armv8-a` is hardcoded in the runner; for another ABI
  build that tree first and adjust if needed.
- Generated sources that don't exist yet are skipped; build first for full
  coverage.
- `#include`d `.c` files (e.g. emu's `../port/dev*-posix.c`) are attributed to
  the included path, normalized to `emu/port/…`.
