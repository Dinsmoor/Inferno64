# DLM (Dynamically Loaded Modules) — libdynld, dynld, and why it's stubbed

> *So you want to load native C modules at runtime (read this first — you mostly can't, here's why)?* This is the reference.

This document exists because the DLM machinery in this tree is one of the
places where **the code organization actively misleads you about the intent.**
The files are present, partly compiled, named like a live feature, and wired
through `load`/`readmod` — yet on hosted POSIX emu the whole thing is dead by
design. Reading the source bottom-up leads to wrong conclusions. This is the
top-down explanation, written explicitly so nobody re-derives it from scratch
(it took a long Q&A to untangle once).

**One-line summary:** DLM lets a running Inferno system load a *native C module*
(type-checked, exposed to Limbo as a `$Sys`-style builtin) at runtime, without
rebuilding the kernel/emu. It was disabled on hosted Unix emu **on purpose**,
because in the hosted cross-development model you just compile the C builtin in.
It has **no 64-bit backend** and is **not** a path to loading Linux kernel
drivers.

See also: [ON_DIS.md](ON_DIS.md) (why C kernels exist at all),
[ON_EMU.md](ON_EMU.md) (hosted emu = a userspace process),
[ON_C_IN_DIS.md](ON_C_IN_DIS.md) (the LP64 story that the 32-bit format
collides with), [ON_AARCH64_PORT.md](ON_AARCH64_PORT.md).

---

## The core confusion, named up front

People (including past-us) reach for four wrong mental models. Kill each one:

| Wrong model | Reality |
|---|---|
| "DLM is how you load a Limbo program." | No. Limbo `.dis` programs run on the **Dis VM** inside `libinterp`. That path is totally separate and already works fine on LP64. DLM is for **native C** modules only. |
| "DLM is a live feature in our emu." | No. `libinterp/dlm-Posix.c` stubs every entry point to `nil`/`0`, and `readmod.c:51` only takes the native path `if((d->mode&0111) && dynldable(fd))` — `dynldable` is hardwired to `0` on POSIX. It is **dead code on hosted Unix**, intentionally. |
| "It loads Linux device drivers (`.ko`)." | No. emu is a **userspace process**; a `.ko` is kernel-space (ring 0) using kernel API. Categorically impossible for any userspace loader. See "Hardware" below. |
| "Reviving it would speed up our dev cycle." | No — it would do the opposite of useful for us. Our cycle is cross-dev from a Linux host where `make all` is ~55s and is the *safe default*. DLM's payoff only appears when rebuild-and-restart is expensive (self-hosted or bare-metal). |

The reason the code misleads: it is **structurally complete** (a library, per-arch
backends, a device, kernel glue, a `load` path) but **functionally switched off**
at exactly one or two seams. Completeness reads as "live." It isn't.

---

## What DLM actually is

A tiny built-in runtime linker. Original Vita Nuova work, © 2004–2007; stopped
~2007, so **no 64-bit backend was ever written**.

Flow: a Limbo program does `load "foo"`. If `foo` is a `.dis`, normal Dis path.
If `foo` is a specially-linked **native object** (exec bit set + recognized
magic), `readmod` hands it to `newdyncode`, which:

1. `dynld(fd)` → `dynloadgen` maps the object into one combined image
   (text+data+bss), big-endian header via `lgetbe`.
2. Resolves an **import table** against a host symbol table (`_exporttab`), with
   **type-signature checking** (`t->sig != sig` → "signature mismatch"). This is
   Limbo's module type-safety discipline extended to native code: a mismatched
   native module is *rejected*, not silently linked.
3. Applies a **relocation table** via `dynreloc` (arch-specific), then
   `segflush` flushes the I-cache.
4. `dynimport` later hands back exported symbols by name+signature;
   `builtinmod` registers it as a `$Sys`-style module.

### Why one file per CPU
`libdynld/dynld-{386,arm,mips,power,sparc,spim}.c` each provide exactly two
things: `dynmagic()` (that arch's object magic) and `dynreloc()` (that arch's
instruction-encoding fixups). Relocation is instruction-format-specific, so it
cannot be generic. **There is no `dynld-aarch64.c` and no `dynld-amd64.c`.**

### Where the real glue lives (and where the stub lives)
| File | Role | State |
|---|---|---|
| `libinterp/dlm-Inferno.c`, `dlm-Plan9.c` | Real, **generic** `newdyncode`/`freedyncode`/`newdyndata`/`freedyndata` (arch-independent; only call `dynld`+`dynimport`) | Real |
| `libinterp/dlm-Posix.c` | Same four entry points, **all stubbed to nil/0**, plus `dynld`→nil, `dynldable`→0 | **STUB (what hosted Linux links)** |
| `emu/port/dynld.c` | `kdynloadfd`/`kdynloadable` over `kread`/`kseek`. Missing the `dynld`/`dynldable` wrappers and **not linked into hosted Linux** (only `emu/Plan9/emu` lists `dynld`). | Partial / unlinked |
| `emu/port/exptab.c` | The host symbol table `_exporttab[]` — currently the **dummy** `{0,0,nil}`. | Empty |
| `os/port/dynld.c` | The real native-kernel `dynld`/`dynldable`. | Real (but `os/` is dormant + 32-bit) |

So "implement `dlm-Posix.c` for real" is mostly: copy the four generic functions
from `dlm-Inferno.c`, add the 5-line `dynld`/`dynldable`, populate `_exporttab`,
link `libdynld` + `emu/port/dynld.c`, and flip the `readmod.c:51` gate. That part
is small. The hard parts are below.

---

## Why it can't just be switched on (the LP64 wall)

The entire on-disk ABI is **ILP32 to the bone** — note this is about the
*serialized* format and the reader, **not** the in-memory struct widths (in this
LP64 build `ulong` is 64-bit, so e.g. `Dynsym.addr` is actually a 64-bit field):

- `libdynld/dynld.c`: `lgetbe()` is the wire reader, and it is hardwired to 4
  bytes — its union is `{ ulong l; uchar c[4]; }` and it returns `get4(u.c)`. On
  LP64 the union's `ulong` is 8 bytes but only the low 4 are read, so every header
  field it parses is **truncated to 32 bits**. It also reads `sizeof(Exec)` where
  `Exec`'s fields are `long` (now 8 bytes), so the header offsets are wrong before
  relocation even starts. A 64-bit symbol address therefore cannot survive the
  load even though `Dynsym.addr` could hold it in memory.
- `include/dynld.h`: `struct Dynsym { ulong sig; ulong addr; char *name; }`. The
  field is wide enough on LP64, but it is filled from the 32-bit-truncating
  `lgetbe` path above, and the format has no room for a 64-bit `addr`.
- `dynreloc(uchar *b, ulong p, ...)` does its fixups by writing through `ulong*`
  and adding `(ulong)b`; the reloc addends in the stream are ≤4-byte deltas, so
  the *encoding* — not the C arithmetic — caps relocations at 32 bits.

`R_MAGIC` (arm64) and `S_MAGIC` (amd64) *are* defined (`utils/include/a.out.h`,
both with `HDR_MAGIC` header-expansion), but there is **no expanded 64-bit `Exec`
struct** in this tree. A 64-bit DLM would need a new, versioned container.

---

## The decisive missing piece: there is no aarch64 toolchain

`dynreloc`'s reloc modes are **specific to what Inferno's own linker emits**. DLM
objects are **not** gcc/ELF; they are produced by the Plan 9-style linkers
(`5l` ARM, `8l` 386) run with `-x` to emit `_exporttab` + the custom DYN reloc
table. The `utils/` toolchain here is `0l 5l 6l 8l c2l ftl il kl ql tl vl` —
**there is no arm64 code generator or linker.** You cannot produce a single
loadable aarch64 native object today, and `dynld-aarch64.c` cannot be written
before the reloc encoding exists (which means before a linker emits it). aarch64
also needs reachability handling the 32-bit modes never had: `BL` is ±128 MB
(`CALL26`), `ADRP+ADD` for data → veneers/GOT for a far-`malloc`'d module.

---

## Two roads to a real 64-bit DLM, compared

| | **Road 1: revive the bespoke a.out format** | **Road 2: back DLMs with host `dlopen` (POSIX)** |
|---|---|---|
| 64-bit format work | widen `Dynsym`/`Exec`/`lgetbe`/`dynreloc` | none (ELF is already 64-bit) |
| New compiler/linker | **YES — build an arm64 Inferno linker (huge)** | none (use `cc`/`ld`) |
| `dynld-aarch64.c` + veneers | **YES** | **none** |
| Keep type-signature safety | yes | yes (keep the `sig` check; that's the portable value) |
| Works on | aarch64 (eventually) | aarch64 **and** amd64 immediately |
| Effort | 🔴🔴🔴🔴 | 🟢🟢 |

**If we ever want this, Road 2 is the answer.** The bespoke-format + per-arch
reloc backend route only makes sense for the dormant native `os/` kernel (still
32-bit). Keep Inferno's signature check — it's the genuinely valuable, portable
part; throw away the parts that require inventing a compiler backend.

---

## Hardware: what "load a driver" can and cannot mean

This is the other big confusion. "Driver" means two unrelated things:

| | Linux device driver (`.ko`) | Inferno device / native module |
|---|---|---|
| Runs in | Linux kernel, ring 0 | the emu **userspace** process, ring 3 |
| Calls | kernel API (`kmalloc`, `request_irq`, `ioremap`, DMA) | Inferno's `_exporttab` builtin ABI |
| Loaded by | `insmod`, `CAP_SYS_MODULE` | dlopen/dynld, no privilege |

DLM loads the **right column**. It can **never** load a Linux `.ko` — wrong
privilege level *and* wrong symbol universe. What a DLM module *can* do is reach
hardware the only way any userspace program can: through Linux's **userspace**
interfaces — libusb, `/dev/*`, evdev, `vfio`/`uio`, sockets, `mmap`. The Linux
kernel driver still does the ring-0 work; your Inferno-native C module talks to
its userspace face.

| Goal | DLM a path to it? |
|---|---|
| Load an unmodified Linux `.ko` into emu | ❌ never |
| Reuse a Linux driver's function from Inferno | 🟡 only via its userspace API (libusb/vfio/uio/evdev) — DLM not even required |
| Drop-in native Inferno device modules at runtime (libusb/evdev wrappers) | ✅ the real win |
| Same on bare-metal native `os/` | ✅ but `os/` is dormant + 32-bit |

---

## "So it's like Plan 9, just write things in C?" — partly

| | Plan 9 | Inferno (hosted emu) |
|---|---|---|
| Applications written in | C (native binaries) | **Limbo** (Dis), always |
| System/native layer in | C | C (`$Sys`, `$Draw`, `$Raster3`, `$Imageio` …) |
| To add native C | compile + link/run | compile as a **typed module** behind a `.m` interface |
| Linkage discipline | raw linker, no type check | **type-signature checked** |

Two things people miss:

1. **Your apps stay Limbo.** DLM is not "write Inferno apps in C like Plan 9." It
   extends the *module/builtin layer underneath* Limbo.
2. **C is already available.** Inferno already lets you write native builtins in
   C — that's exactly how `$Raster3` and `$Imageio` exist. The *current* way is
   "compile the builtin into emu, rebuild emu." DLM does not unlock C; it unlocks
   **one** thing on top of the C you already have: *load that native module at
   runtime as a plugin, without recompiling emu.* Pluggability, not a new
   language capability.

---

## Why it's stubbed for us, and why that's correct

DLM's payoff is "extend a running system you don't want to / can't cheaply
rebuild and restart." That fits **self-hosted dev** (living inside Inferno) and
the **native kernel on bare metal** (reboot is expensive). It does **not** fit
our model.

| Dev model | Rebuild cost | DLM value |
|---|---|---|
| **Our cross-dev from a Linux host** | trivial (`make all` ~55s, and we *want* the full nuke — it catches stale-ABI bugs) | ~none — correctly stubbed |
| Self-hosted inside Inferno | disruptive (bounce the world) | real |
| Native kernel, bare metal | expensive (reboot) | real |

Vita Nuova made exactly this call: DLMs disabled on hosted Unix emu (`dlm-Posix.c`
stubs, `libdynld` unlinked, no dynld device in the emu config) **because** in the
hosted cross-dev model you just compile the C builtin in. **The dead code is the
design speaking.** Leaving it stubbed is the correct state, not a gap to close.

It becomes interesting only if the project's center of gravity shifts toward
developing *in* Inferno rather than *on* it — at which point Road 2 (a
`dlopen`-based `dlm-Posix.c`, keeping the signature check) is the cheap way in.
Excluding `libdynld` from the emu build is therefore faithful to the original
architecture, not a shortcut.
