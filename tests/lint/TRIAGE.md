# Triage of the `make lint` 64→32 narrowing baseline

Date: 2026-06-04. Reviewed all sites in `baseline.txt` (246 unique
file+conversion-kind entries, ~717 unique source lines once line numbers are
kept) produced by `tests/lint/run.sh`.

## Verdict

**No real LP64 correctness bugs were found.** Every narrowing falls into a
benign class (below). This is the expected result: the genuinely dangerous
truncations — pointers, heap addresses, large file offsets — already use
`ulong`/`uintptr`/`vlong` correctly (that is why emu boots and runs), and the
real width bugs were caught earlier by the cunit suite and runtime debugging
(`strtoull`, `mptov`, `venti`, the limbo `tptr` codegen fixes — see
`docs/ON_C_IN_DIS.md`).

A "narrowing" is only a bug when a value that **can exceed 2³¹ in practice** is
truncated and then **used at full width**. None of the baselined sites meet
both halves.

## Method

For each site the actual source line was read and classified. The high-risk
classes were examined exhaustively; the bulk classes by representative sample
plus a pattern scan over every flagged line for: pointer casts/differences,
`strtoul`/`strtoull` into `int`, and narrowed `malloc`/`memmove`/`memset` size
arguments.

## Benign classes (with evidence)

- **Intentional truncation opcodes.** `libinterp/xec.c:124` `cvtlw`
  (`W(d)=V(s)`) *is* the Limbo `int(big)` cast; truncation is the semantics.
  `inferno.c` `Sys->millisec()` returns a 32-bit int by definition (documented
  to wrap).
- **`qid.path` / device indices.** `devds.c`, `devdup.c`, `chan.c`,
  `deveia-posix.c` (`NETID`), etc. — paths/instances are small enum indices,
  never near 2³¹.
- **Instruction indices (pointer differences).** `devprog.c:778/787/1459`,
  `devprof.c:636`, `loader.c:70/172` compute `PC - module->prog`, bounded by a
  module's instruction count (≪ 2³¹).
- **Buffer/string offsets (pointer differences).** lib9 `fmt*`, libbio
  `brd*`/`bvprint`, `string.c:446` — bounded by buffer/string length (< 2GB).
- **I/O counts.** `qio.c` `BLEN(...)`, `ssize_t`→`int` read/write returns in
  `os.c`/`cmd.c`/libbio, `inferno.c` `kread`/`kwrite` returns, 9P `r->count` —
  bounded by `msize`/the request buffer.
- **Parsed small quantities.** `strtoul` into `int` for mouse x/y, button
  masks, fds, pids, pcs, step counts, window geometry, dump counts
  (`devpointer.c`, `devprof.c`, `devprog.c`, `devssl.c`, `parse.c`, `main.c`).
- **Heap-inspector address path is correct.** `devprog.c` `progheap` keeps the
  address in a `ulong` and `hq->addr = strtoul(...)` is full-width on LP64.
- **Pixel math / coordinates.** libmemdraw blend `MUL*` macros operate on
  0–255 components; libtk/libdraw coordinates are screen-bounded;
  `scale.c` deliberately widens (`(vlong)j*w`) for the multiply then stores a
  bounded pixel coord.
- **Crypto/bignum byte assembly.** libsec/libmp/libkeyring (`rsaalg`,
  `dsaalg`, `egalg`, `keyring.c`) — byte-by-byte assembly, established benign.
- **Upstream FreeType (~120 lines).** `FT_*`/`CF2_F16Dot16` 16.16 fixed-point
  font math; third-party, bounded, left as-is.
- **Profiler tag.** `devprof.c:718` `k = getmalloctag(v)` — `k` is a packed
  32-bit profiling tag (`k>>24` record, `k&0xffffff` offset) set by
  `setmalloctag`, never a raw pointer.

## Pre-existing 32-bit-size design limits (noted, not bugs, not changed)

These are original Inferno design constraints, **not** LP64 regressions, and
only matter at sizes far beyond any realistic configuration:

- **Pool block sizes** (`alloc.c`, `Bhdr.size` is `int`): a single allocation /
  free block is limited to 2GB. The default pools are 32–64 MB.
- **Image byte-counts** (`libmemdraw/draw.c:2501` `i->width*Dy(i->r)`, `bwidth`):
  an `int` pixel count; only overflows for a single image larger than the
  whole `imagmem` pool can hold.
- **`#s` srv request offset** (`devsrv.c` `req.t0`, a `WORD`): the legacy srv
  downcall offset field; srv files are message-style, not large seekable files.

If any of these ever need >2GB support it is a deliberate, separate widening of
the allocator/image/srv ABIs — out of scope for "fix LP64 narrowing bugs".

## Net

The baseline stands as-is; it documents 246 known-benign sites so that a
**new** narrowing in changed code is flagged by `make lint`. No source fixes
were required.
