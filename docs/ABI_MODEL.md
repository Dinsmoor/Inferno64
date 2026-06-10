# Dis integer model: LP64 vs ILP64 — and why this project targets LP64

**The target:** Limbo source code behaves *identically* on every host
architecture. A compiled `.dis` may need to be recompiled per arch, but the
*meaning* of the Limbo program must not change from host to host. Complexity is
absorbed in the C core (with defined checks/tests, below); userspace stays
stable.

**The decision:** under that target, **LP64 is the correct Dis model** — it pins
the Limbo `int` (Dis WORD) at 32 bits on *every* host, so a `.dis` means the same
thing wherever `emu` runs. ILP64 makes the Limbo `int` width follow the host
pointer width (32 on 32-bit hosts, 64 on 64-bit hosts), which breaks that
guarantee and defeats the point of Limbo-on-Dis being host-independent. The
`master`/`lp64` two-branch split exists so both models stay buildable; this
document records why LP64 is the one to commit to for the stated target.

> Terminology trap, kept throughout: **"LP64" has two meanings.** (1) the *host
> C data model* (Linux aarch64/amd64 are LP64 C platforms: `int`=4, `long`=8,
> ptr=8) — permanent, true on **both** branches; (2) *Inferno's Dis integer
> model* — `IBY2WD`=4 (LP64-Dis, the `lp64` branch) vs `IBY2WD`=8 (ILP64-Dis,
> `master`). Only meaning (2) differs between branches.

---

### Table A — Host C data models (the platforms in this tree)

| Host arch (OBJTYPE) | Example hosts in tree | C `int` | C `long` | C ptr | C model |
|---|---|---|---|---|---|
| `386`, `arm`, `mips`, `power`, `s800` (32-bit) | Nt(386), legacy *BSD/Irix/Solaris 32 | 32 | 32 | 32 | **ILP32** |
| `aarch64` *(default)* | Linux, MacOSX | 32 | 64 | 64 | **LP64** |
| `amd64` *(override)* | Linux, *BSD, Solaris | 32 | 64 | 64 | **LP64** |
| `power64`/`mips64`/`sparc64` | (buildable, not active) | 32 | 64 | 64 | **LP64** |
| *Win64* | **not a target** (`emu/Nt`=`386`) | 32 | 32 | 64 | *LLP64* |

The host C model is a fixed property of the OS/arch — **identical on both branches**. Only ILP32 and LP64 hosts are actually built; no LLP64.

---

### Table B — Limbo `int` (Dis WORD) width per host, under each Dis model

| Host class | C model | **LP64-Dis branch** (`IBY2WD`=4 always) | **ILP64-Dis master** (`IBY2WD`=ptr) |
|---|---|---|---|
| 32-bit (386/arm/…) | ILP32 | Limbo `int` = **32** | Limbo `int` = **32** |
| 64-bit (aarch64/amd64) | LP64 | Limbo `int` = **32** | Limbo `int` = **64** |
| **Limbo `int` constant across all hosts?** | | ✅ **Yes — always 32** | ❌ **No — 32 or 64 by host** |

This is the whole decision in one row. **LP64 pins Limbo `int` at 32 bits on every host arch** → a `.dis` behaves bit-identically regardless of where `emu` runs (same overflow, same `1<<31`, same masking, same layout). ILP64 makes Limbo `int` width follow the host pointer width → semantics differ between a 32-bit device and a 64-bit machine.

---

### Table C — Verdict against the target

| Requirement | LP64-Dis | ILP64-Dis |
|---|---|---|
| Limbo source behaves the same on every host arch | ✅ guaranteed (int=32 everywhere) | ⚠️ only within one width class |
| `.dis` recompiled per arch is acceptable | ✅ (magic-gated, auto) | ✅ (magic-gated, auto) |
| Don't break userspace / Limbo-struct == C-struct identity (e.g. `Draw_Rect`==`Rectangle`) | ✅ **holds** (int=32 = C int) | ❌ **breaks** (needs field-wise `IRECT/DRECT`, `Tk_rect` cast) |
| Push complexity into C, keep Limbo simple | ✅ that's the model | ✗ inverts it (Limbo gets host-dependent int) |

**For the target as stated, LP64 is the model that delivers it.** Its price is a C-side hazard class (pointer wider than word) — which is exactly what the checks below exist to catch.

---

### Table D — LP64 C hazard classes → the defined check/test that catches each *(all verified in-tree)*

| # | Hazard (only arises because C ptr=8 > Dis WORD=4) | Detection mechanism | Where | Phase |
|---|---|---|---|---|
| 1 | C pointer stored into a `WORD`/`int`/`s32` slot → high 32 bits truncated (the "tptr" class) | `make lint` → clang **`-Wshorten-64-to-32`** vs frozen `tests/lint/baseline.txt` | `tests/lint/run.sh` | **Build** |
| 2 | Compiler emits a word-width move for a pointer-width type | **`genmove` width assert** → `fatal("… LP64 width mismatch")`, in **both** compilers | `limbo/gen.c` + `appl/cmd/limbo/gen.b` | **Compile** |
| 3 | A temp that must hold a pointer is typed `tint` (4B) not `tptr` (8B) | explicit **`tptr`** pointer-width type routing | `limbo/ecom.c` / `ecom.b` | **Compile** |
| 4 | GC pointer-map disagrees with a type's slot size/stride | **`verifytype` / `verifyctype`** GC-map↔size cross-check | `libinterp/heap.c` | **Init/runtime** |
| 5 | A truncated/stray Dis pointer gets walked by the collector | **`DISPTRCHECK`** ("Valgrind for Dis pointers"), `-DDISPTRCHECK` debug build | `libinterp/gc.c` | **Runtime (debug)** |
| 6 | Wrong-width `.dis` (stale 32-bit module on 64-bit emu) | **`XMAGIC` vs `XMAGIC8`** stamp + `exDiswidth` rejection → shell recompiles from source | `limbo/com.c`, `libinterp/load.c` | **Load** |
| 7 | Stale generated module headers (`srv.h`, runt.h) after an ABI switch | `make` **force-regenerates** generated headers per-ABI; `clean`/`nuke` wipe them | mkfiles | **Build** |
| 8 | Anything that slips all of the above | regression nets: **`tests/lp64`** (9 suites) + **`tests/cunit`** (per-C-lib: lib9/libmp/libsec/libmath/libbio/…) | `tests/` | **Test** |
| 9 | First-fault capture for a bug in the wild | **`EMUCRASH=1`** core + `USR2` dump + `EMUWATCHDOG` | `emu/Linux/os.c` | **Runtime obs.** |

---

### Table E — Defense-in-depth: when each net fires

| Stage | Catches | Cost |
|---|---|---|
| Write C | (discipline: use `tptr`/`WORD`/`uintptr` deliberately) | — |
| **Compile** | #2 `genmove` assert, #3 `tptr` typing | free, automatic, hard-fails |
| **Build** | #1 `make lint` regression, #7 header regen | seconds; baseline diff |
| **Load** | #6 wrong-width `.dis` | automatic recompile |
| **Init / run** | #4 `verifytype`, #5 `DISPTRCHECK` (debug) | debug-build only |
| **Test** | #8 `tests/lp64` + `tests/cunit` | `make check` gate |
| **In the wild** | #9 `EMUCRASH`/`USR2`/watchdog | core on first fault |

The takeaway: the LP64 hazard is **real but bounded and mechanically caught** —
two of the nets (#2, #6) are *hard compile/load failures* you cannot miss, and
#1/#8 are CI-gateable. That is the trade the target implicitly accepts: **a
known, tooled C hazard in exchange for Limbo source that means the same thing on
every host arch.**
