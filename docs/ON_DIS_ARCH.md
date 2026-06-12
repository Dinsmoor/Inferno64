# Dis VM — Architecture & ABI Realization

**Audience / scope.** `ON_DIS.md` describes the **portable** Dis VM and
instruction set — true on any host. *This* doc covers how that model is realized on
a concrete **architecture and pointer-ABI**: the dual-ABI field widths, the per-ABI
`.dis` magic, compiled (JIT) execution and its register map, and the emu memory
pools. The deep JIT codegen reference is `ON_JIT.md`; the durable width
rules are `ON_C_IN_DIS.md` — this doc is the bridge.

> **Only Linux/aarch64 (LP64) is built and tested in this tree.** Everything below
> reflects that target. The other `comp-*.c` / `das-*.c` backends (arm/386/mips/
> power/sparc) are upstream legacy and are **not** built or exercised here; the
> Linux/amd64 LP64 glue exists but is **UNBUILT/UNTESTED** (see `ON_C_IN_DIS.md`).

---

## Dual-ABI: what is 4 bytes vs 8

Dis was historically a 32-bit-pointer VM. This tree is **dual-ABI**: the same source
and the same committed `.dis` tree build for either pointer width, selected by the
host (`include/isa.h` sets `IBY2PTR = sizeof(void*)`; `IBY2WD = 4` always). On the
LP64 aarch64 build `IBY2PTR == 8`.

The invariant that keeps Dis bytecode portable: **a Dis `WORD` is always 32-bit**
(`int`), on every ABI. Only *pointers* and the 64-bit scalar types change width:

| Field / slot | Width on LP64 | Notes |
|---|---|---|
| Dis `WORD` (int operands, `IC`, `compiled`, type tags) | 4 | never changes — this is what makes `.dis` portable |
| Dis `LONG`/`big`, `REAL`/`real` | 8 | 8 on both ABIs |
| Pointer fields of `REG`/`Frame`/`Modlink`, `MP`/`FP`/`SP`/`PC` | 8 | `IBY2PTR`; 4 on a 32-bit build |
| `Heap.ref` (`ulong`) | 8 | a refcount, pointer-width |
| GC pointer-map slot stride | 8 | map bit *i* → byte offset `i*IBY2PTR` |

All width logic in the C is symbolic (`IBY2PTR` vs `IBY2WD`), and a static assert in
`xec.c` (`sizeof(void*)==IBY2PTR`) guards it. The class of bug this creates — a
64-bit value truncated to 32 — and the layered defences against it are documented in
`ON_C_IN_DIS.md` and `ON_EMU_DEBUG.md`.

---

## `.dis` magic per ABI

### Width, not architecture

The magic does **not** identify a CPU. It identifies the **binary layout** of the
file, and that layout is a pure function of exactly two width constants
(`include/isa.h`):

- `IBY2PTR` — the size of a pointer / register slot. Drives frame sizes, GC
  pointer-map offsets, type-descriptor pointer maps.
- `IBY2WD` — the size of a Dis word (a Limbo `int`). Drives word-typed frame/data
  slots and `MOVW`-class operand spacing.

The instruction/data stream *parses* regardless of either width, so the magic is
the only safe discriminator. The consequence is the whole point of Dis
portability: **a new architecture at an existing width needs no new magic.** A
68k port (32-bit pointers, 32-bit word) simply stamps `XMAGIC`, the same as any
other 32-bit host; because the `.dis` byte format is endianness-neutral
(`operand()`/`disw()` decode a canonical big-endian, variable-length stream), a
big-endian 68k `.dis` is byte-compatible with a little-endian x86 one. Endianness
never enters the magic.

### The two width bits

Layout depends on two widths, so the magic carries two flag bits OR'd onto a base
magic (`XMAGIC` normal / `SMAGIC` signed):

| Flag | Value | Set when |
|---|---|---|
| `DISptr64`  | `0x100000` | `IBY2PTR == 8` (64-bit pointer slots) |
| `DISword64` | `0x200000` | `IBY2WD  == 8` (64-bit Dis word / Limbo `int`) |

| `IBY2PTR` | `IBY2WD` | Magic (normal / signed) | ABI |
|---|---|---|---|
| 4 | 4 | `XMAGIC` 819248 / `SMAGIC` 923426 | classic **32-bit** |
| 8 | 4 | `XMAGIC8` 1867824 / `SMAGIC8` 1972002 | **LP64** — this tree |
| 8 | 8 | `XMAGIC\|DISptr64\|DISword64` 3964976 / signed | **ILP64** (the rejected branch) |

`XMAGIC8`/`SMAGIC8` are just `XMAGIC|DISptr64` / `SMAGIC|DISptr64` — the historical
values, so the committed `dis/` tree (all LP64, `DISword64` clear) is unchanged.

### Stamp and accept

`limbo/com.c` (and the self-hosting `appl/cmd/limbo/com.b`) stamp
`XMAGIC | (IBY2PTR==8? DISptr64:0) | (IBY2WD==8? DISword64:0)`. `libinterp/load.c`
computes its own `mymagic` the same way and accepts only an exact match; anything
whose **base** (`mag & ~DISabimask`) is still `XMAGIC`/`SMAGIC` but whose flags
differ is rejected with the catchable `exDiswidth` ("wrong Dis ABI width"), which
the shell uses to recompile from source. A base that is neither `XMAGIC` nor
`SMAGIC` is plain "bad magic".

### Why both bits matter (the ILP64 blind spot it closes)

Tagging only the pointer width was not enough. Our **LP64** (ptr 8, word 4) and
caerwynj's **ILP64** (ptr 8, word 8) share the *same pointer width* on a 64-bit
host — so a pointer-only tag could not tell them apart. With only `DISptr64`, an
ILP64 `.dis` would have **matched** `XMAGIC8` and loaded, then silently corrupted
(every word slot is the wrong size). The `DISword64` bit is what makes that case a
clean rejection. Verified: an ILP64-magic module loads to
`REJECTED: dis module compiled for wrong Dis ABI width`, genuine garbage still
reports `bad magic`, and a valid LP64 module passes; through the shell the wrong
module is transparently recompiled from its embedded source path.

### Adding a genuinely new width

Two bits express only the 4-vs-8 cases, which cover classic/LP64/ILP64. A target
with a *third* pointer or word size (a hypothetical 16-bit or 128-bit Dis) would
need the two bits replaced by a small **width-code field** (e.g. two nibbles
holding the byte counts), grandfathering `XMAGIC`/`XMAGIC8` as the zero-field
cases. Not worth building until such a target is real. Either way the edit is the
same five sites: `include/isa.h` + `appl/cmd/limbo/isa.m` (definitions),
`limbo/com.c` + `appl/cmd/limbo/com.b` (stamp), and `libinterp/load.c` (accept) —
plus the width-agnostic reader in `appl/lib/dis.b`/`module/dis.m` for the
recompile lookup. Keep magics under bit 29 so `operand()`'s 30-bit signed decode
stays positive.

---

## Compiled (JIT) execution

When `cflag>0` (or a module's `MUSTCOMPILE` flag), the loader compiles a module to
native code at load time via the arch backend `libinterp/comp-aarch64.c`. There is
**no** tiered / hot-count heuristic — it is whole-module, at load (plus explicit
`Loader->compile`/`compilebg`). Full detail — two-pass codegen, the encoder layer,
FP, the `jitlock` compile-serialization invariant, and the background-warming
subsystem — is in **`ON_JIT.md`**. The VM-level realization:

**Execution selection** (`libinterp/xec.c`, the dispatch loop):

```c
if(R.M->compiled || ((uchar*)R.PC >= jitlo && (uchar*)R.PC < jithi))
    comvec();            /* enter native code */
else
    /* interpret: dec[]/optab[] */
```

`jitlo`/`jithi` bound the native-code arena (0 when no JIT). `Module.pctab`
(`ulong* pctab`, `include/interp.h`) maps Dis instruction index → native code offset,
used for exception tables and profiling.

**AArch64 register map** (`comp-aarch64.c` — the *real* map; an older copy of this
table in `ON_DIS.md` mistakenly listed the ARM32 numbers):

```
x0–x3 = RA0–RA3   (scratch / C args+return)
x4    = RCON      (constant / address builder)
x5    = RTA       (indirect-addressing temp)
x16   = branch-through temp
x19   = RREG      (&R; callee-saved)
x20   = RFP       (Dis frame pointer; callee-saved)
x21   = RMP       (Dis module pointer; callee-saved)
x24   = RLR2      (link save inside macros, e.g. macmcal; callee-saved)
x30   = LR
```

(`comp-arm.c`, the ARM32 reference backend, uses the older `R5`=RREG, `R8`=RMP,
`R9`=RFP scheme.)

**Low-address executable arena.** Pool/heap memory is non-executable and lives at
~`0xaaaa........` (>4GB). `jitcode()` mmaps a low (<2GB) RWX arena (hint
`0x20000000`, hard cap `0x80000000`); `segflush` `mprotect`s it RWX as a backstop.
Low addresses are **required** because IGOTO/ICASE jump tables store native code
addresses in 32-bit `WORD` slots that the interpreter reads back as `R.PC`. See
`ON_JIT.md` for the latent multi-arena caveat.

---

## Memory pools

**File:** `emu/port/alloc.c`. emu carves host memory into three pools
(`emu/port/alloc.c`, the pool table):

| Pool | Index | Default max | Purpose |
|---|---|---|---|
| `main`  | 0 | 32 MB | general C allocations |
| `heap`  | 1 | 32 MB | the Limbo GC heap (`heapmem`) |
| `image` | 2 | 64 MB (+256) | graphics / draw images |

Override at launch: `-p main=N`, `-p heap=N`, `-p image=N`. The allocator uses a
balanced tree of free blocks (`Bhdr`) and coalesces neighbours on free. The
`Bhdr.size` field is a 32-bit `int` (a pre-existing ~2GB-per-pool design limit, not
an LP64 regression — see `ON_C_IN_DIS.md`). Heap corruption here trips
`poolcheck`, which `abort()`s (see `ON_EMU_DEBUG.md`).

---

**Cross-references:** `ON_DIS.md` (the portable VM & instruction set) ·
`ON_JIT.md` (JIT codegen, the as-built aarch64 reference) ·
`ON_C_IN_DIS.md` (the durable dual-ABI width rules + the LP64 bug class) ·
`ON_EMU.md` (emulator architecture) · `ON_AARCH64_PORT.md` (the arch port).
