# Porting Inferno's Dis VM to LP64 — a field retrospective

This is the narrative companion to the per-subsystem `AGENTS_*.md` files: how the
LP64 port of Inferno's `emu` (the Dis virtual machine + Limbo runtime) actually
came together, the bug families that recurred, the methodology that worked, and
what is left. If you are picking this up cold, read `AGENTS_INPRO.md` first for
the authoritative status; this file is the story and the lessons.

## What "LP64 port" means here

Stock Inferno assumes a 32-bit data model: a C `long`/`ulong` is 4 bytes, a
pointer is 4 bytes, and the Dis VM's "word" (`IBY2WD`) and "pointer"
(`IBY2PTR`) are both 4. On a 64-bit host (LP64: `long`/pointer = 8 bytes) those
assumptions break in dozens of small, independent places.

The port keeps the **Dis word at 4 bytes** (`IBY2WD = 4`) but makes a **Dis
pointer 8 bytes** (`IBY2PTR = 8`). A Limbo `int` stays 32-bit; a Limbo `big` is
64-bit; a `ref`/pointer is 64-bit. The compiled `.dis` tree is identical across
all LP64 hosts (it carries an `XMAGIC8` magic distinct from the 32-bit
`XMAGIC`), so aarch64 and amd64 share the entire Dis ABI; only per-arch glue
differs. `master` is frozen 32-bit upstream; all of this lives on `port-LP64`.

The crucial mental model, learned the hard way and worth repeating:

> **The LP64 bugs are in C, not in Limbo.** Limbo is pointer-width-agnostic — a
> correctly-compiled `.dis` runs identically on 32- and 64-bit. Limbo programs
> are only the *vehicle* that drives the C paths where the bugs live. So you find
> bugs by *running* Limbo (broad C-path coverage), and you fix them in C.

## The journey, in phases

### 1. CLI / shell bring-up — a sequence of codegen bugs

The port came together as a chain of "this code-generation or analysis path
still assumes 4-byte pointers" bugs in the **Limbo compiler**. Each full
dis-tree recompile with the corrected compiler pushed the boot further and
exposed the next unconverted pointer path. Five distinct root causes in the
compiler/optimizer: the call-frame temporary, the array-literal element-address
temporary, the pointer-comparison opcodes, optimizer liveness sizes, and the
indexed-element address node type (the `Oindex`→`Oindx` rewrite). The endpoint:
a full interactive `sh` — pipes, redirection, globbing, `ps`, env vars, control
flow, dynamic builtin load — with no known CLI crashes.

The subtle lesson from this phase (documented at length in `AGENTS_INPRO.md`):
**not every `tint`/32-bit temp is a bug.** A `tint` node is only wrong when its
own type drives a move width *and* it holds a materialised 8-byte address. Those
are exactly the `Oindx` element-address nodes; intermediates for explicitly-typed
ops are fine. Blanket-converting `tint`→`tbig` is itself a bug. Don't
whack-a-mole — characterise the class, then fix the class.

### 2. Foundational C fixes

A handful of pure-C 64-bit correctness fixes that had to land before anything
ran: `libmath/dtoa.c` and `limbo/dtocanon.c`/`libinterp/load.c`
(`dtocanon`/`canontod`) assumed a 32-bit bignum word and that an IEEE double's
two halves are 32 bits — a `union { double; unsigned long[2]; }` aliased the
whole double on LP64, so **every real *constant* loaded as ~0** (runtime-computed
reals were fine, which is why the CLI never caught it). `emu/port/alloc.c`'s pool
quantum (32 bytes) was smaller than the LP64 `Bhdr`+`Btail` (64 bytes), spilling
free-tree pointers into neighbouring blocks. These share a signature: a width
assumption that is invisible until you exercise the exact path.

### 3. `$Loader` — runtime module reflect/rebuild

`$Loader` (`libinterp/loader.c`) round-trips a module's instructions to/from
Limbo (runtime code-gen — think mmap+exec+cast). Three LP64 bugs, e.g. `brunpatch`
read a branch target from the truncating 4-byte `i->d.imm` when the core stores
it as a full 8-byte `Inst*`. All VM-only (no `.dis` change); verified by
byte-for-byte `ifetch`→`newmod` round-trips.

### 4. The standing test harness — `tests/lp64/`

A self-contained TAP suite that exercises the VM + language end-to-end through
`emu-g`, no display needed. `run.sh` compiles each `suites/*.b` with the C
`limbo`, runs it under `emu-g`, and aggregates `ok`/`not ok`. It grew to **166
assertions across 8 suites**: `00_vm` (constants/math/strings/lists/ADTs/
exceptions/the modern features), `10_concur` (spawn/channels/alt/sieve/GC
stress), `20_crypto` (Keyring digests, AES/DES, IPint modexp), `30_styxnet` (TCP
loopback + 9P pack/unpack incl. >4 GiB), `40_selfhost` (drive the in-emu
compiler), `50_loader`, `60_plumb` (Regex/Plumbmsg/Plumbing), `70_except`
(exception fall-through, the `NOPC` regression). The harness flags a mid-run VM
break (`BROKE`/`NOPLAN`) so a tolerated exit code can't hide a fault.

Gotchas baked in: `/tmp` is not in the headless namespace (generate into
`_build/`); `exit` is a no-arg statement (signal pass/fail via TAP); any spawned
helper proc must terminate or `emu-g` hangs to timeout; the post-run rc-137
SIGKILL is a benign emu-g teardown.

### 5. The GUI — from "graphics can't link" to an interactive desktop

This was the big lift. Three things had to happen:

1. **Vendor FreeType.** `libfreetype/libfreetype/` was an *unpopulated git
   submodule*, so `freetype.c` had no headers and the full `emu` config couldn't
   link. Checked out the exact commit the submodule pinned — **FreeType
   2.13.2** — as plain bundled source (submodule de-registered, `.gitmodules`
   removed) so there is no version drift.
2. **Fix the draw word width.** libmemdraw/libdraw modelled an image scan line as
   an array of `ulong` words and computed every stride as `sizeof(ulong)`. On
   LP64 that became 8, so strides *doubled*: the X11-backed screen image
   (`width=1024`, depth 32) got a 8192-byte stride instead of 4096 and the
   compositor walked off the end of the 3 MB framebuffer — SIGSEGV in
   `boolcalc1011`/`memimagedraw` on the very first window. A draw word must be
   **32 bits** (matching the draw protocol, image files, fonts and `win-x11a.c`).
   Pinned it to `sizeof(u32int)` (and a 32-bit unit in `wordsperline`) and made
   the pixel pointers `u32int*` across `bytesperline.c` and
   `libmemdraw/{alloc,draw,defont,load,unload,line}.c`. **Rule: a draw word is 4
   bytes — never `sizeof(ulong)`.**
3. **Fix exception unwinding.** With graphics up, `wm/wm` rendered but its
   `wmsetup`/`plumber` broke with "illegal dis instruction". The unwinder's
   `NOPC` "no handler" sentinel (`emu/port/exception.c`) was 32-bit
   (`0xffffffff`), but the loader stores the fall-through terminator as
   `operand()`'s `-1`, which sign-extends to `0xffffffffffffffff` on LP64 — so a
   `raise` that fell through a non-matching handler jumped to `prog-1`. (Minimal
   repro: `kill 99999`, which does `raise "fail:..."`.) Fixed: `#define NOPC
   (~(ulong)0)`.

Result: `make all` defaults to `CONF=emu`, and `wm/wm` runs an interactive
desktop — verified headless under Xvfb with screenshots of the taskbar, the
FreeType-rendered application menu, and a correctly-rendered Mandelbrot.

### 6. The UBSan audit

Standing up a sanitizer build to systematically hunt the rest. **ASan is
incompatible with emu** (its `malloc`/`free` interceptors collide with emu's own
pool allocator → `alloc:D2B ... not in pools` at boot), so the workhorse is
**UBSan** (no allocator conflict; catches integer/shift/pointer-overflow/
misalignment), with **Valgrind** as the substitute for ASan's heap and
uninitialised-value checking. The sweep (suite + `ref/limbobyexample` +
inferno-lab + GUI apps under Xvfb) surfaced exactly one real LP64 class — see
below — plus a lot of benign 2's-complement UB.

## Bug taxonomy — the LP64 patterns that recur

1. **`sizeof(ulong)` used as a fixed 4-byte unit.** Strides, word sizes,
   per-pixel/per-word arithmetic. Became 8 on LP64. (Draw scan line; the pool
   header math.) *Fix:* use the right fixed type (`u32int`/`WORD`) or `void*`.
2. **Byte→word assembly that sign-extends into a wider field.** `(uchar)<<24`
   promotes to `int`; a high byte ≥ 0x80 makes a *negative* int that
   sign-extends to `0xFFFFFFFF…` when widened into a 64-bit `ulong`/`vlong`.
   This is the single most common real bug. Hit it in: the 9P unpack macros
   `GBIT32`/`GBIT64` (`mode`, lengths, qids, times — `GBIT64` also sign-extended
   its *low* word), `Dir.mode` assembly (`dev.c`, `devfs-posix.c`, `dirstat-*`),
   and the `.dis` loader (`disw`, the DEFL big path). *Fix:* assemble each byte
   as `u32int`; zero-extend low words.
3. **A pointer stuffed into / read from a 4-byte field.** (`$Loader` brunpatch
   reading an `Inst*` from `i->d.imm`.) *Fix:* use the 8-byte member.
4. **A 32-bit sentinel/mask compared against a now-64-bit value.** (`NOPC =
   0xffffffff` vs a sign-extended `-1`.) *Fix:* `~(ulong)0`, or the correct width.
5. **Unions overlaying a `double`/pointer with `long[2]`/`int`.** (`dtoa`,
   `dtocanon`.) *Fix:* pin the element to `u32int`.
6. **Compiler/optimizer assuming a 4-byte pointer** when sizing temps, moves,
   liveness, or address nodes. (The `Oindx` class.) *Fix:* widen only the
   materialised-address nodes; do not blanket-convert.

### Benign look-alikes (do NOT churn these)

A left-shift/overflow finding is only a bug when the value **sign-extends into a
wider field used at full width**. If it is stored into a 32-bit field, masked, or
truncated, it is benign 2's-complement UB with a correct result. Verified-benign
classes here: the graphics pixel-assembly shifts (the desktop and Mandelbrot
render correctly), the crypto/bignum byte-assembly (AES/MD5/SHA vectors pass),
the string hash, `operand()` (made well-defined anyway since it is foundational),
and `memmove(x, nil, 0)` (not even LP64-specific). Fixing verified-correct hot
paths for sanitizer-cleanliness is risk without reward.

## Methodology and tooling that worked

- **Recompile-on-mismatch.** After any `limbo`/compiler change, the *entire*
  `appl` dis tree must be rebuilt — `mk` does **not** rebuild a `.dis` when only
  the compiler changed and the `.b` is unchanged. Several "the fix didn't work"
  dead-ends were stale `.dis`. The `.dis` carries `XMAGIC8`; the emu rejects a
  wrong-width module, which is itself a useful guard.
- **Native Dis-level debugging first.** A broken process parks in the `Broken`
  state and is fully inspectable via `/prog/<pid>/`: `grep Broken /prog/*/status`,
  then `cat /prog/<pid>/{exception,stack}` for the Dis backtrace, `disdump` +
  the `.sbl` (`limbo -g`) to map a PC to source. Reach for `/prog` *before* gdb.
- **gdb for the C fault.** emu is not stripped; for a hard segfault, `handle
  SIGSEGV stop` then `bt` lands you in the faulting C frame (this is how the draw
  word-width bug was localised to `boolcalc1011`). Rebuild the one suspect file
  with `-g -O0` and swap the object in for locals.
- **Sanitizers.** UBSan build (inject `-fsanitize=undefined` via the arch
  mkfile, rebuild the runtime libs + emu, leave the host toolchain and vendored
  FreeType normal); Valgrind on the normal binary for uninit/heap. Full recipe
  and the ASan-vs-pool-allocator caveat are in `AGENTS_DEBUGGING.md`.
- **A standing regression suite.** Every fix got an assertion; reintroducing a
  bug must turn the suite red (verified for `NOPC`: 9→1 assertions).
- **Xvfb for headless GUI.** `Xvfb :99 … & DISPLAY=:99 emu -g WxH wm/wm`, then
  `import -window root out.png` to screenshot and `xdotool` to drive input —
  enough to render menus and apps and confirm pixels are correct.

## Build system notes

`make all` (top-level `Makefile`) wraps `mk` and nukes objects between
components because `mk`'s incremental dependency tracking is unreliable. Default
`CONF=emu` (full GUI); `CONF=emu-g` for the fast headless build the tests run
under. **Known `mk` gaps** (tracked separately): it does not rebuild a `.dis`
when only the compiler changed, and it does not recompile `.o` when only mkfile
flags change (stale ASan `.o` vs UBSan libs produced `__asan_*` link errors mid-
audit). Until fixed, `mk clean`/`rm *.o` a dir after changing flags.

## Status: done vs deferred

**Working:** the LP64 Dis VM and full CLI/sh; the entire `tests/lp64` suite
(166/166); crypto, 9P/Styx + TCP, the self-hosted compiler, `$Loader`; and the
**graphical desktop** (`wm/wm`, Tk apps, FreeType text) on aarch64.

**Deferred / not done:**
- **JIT** — `libinterp/comp-aarch64.c` is an interpreter-only stub; native Dis→
  aarch64 code generation is unwritten (the largest remaining new LP64 surface).
- **amd64** — x86-64 glue is in the tree but unbuilt/untested; it shares the
  `XMAGIC8` `.dis` ABI, so only per-arch glue should differ.
- A handful of off-boot-path LP64 items and the benign-UB cleanup above.

## If you remember one thing

Characterise the *class*, fix the class, add a regression, and don't touch
verified-correct hot paths for cosmetics. The bugs are in C; Limbo just walks you
to them.
