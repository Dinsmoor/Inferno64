# ref/p9 — 9front ideas worth bringing to Inferno64

A future-task consideration list distilled from **9front's git history (2011–2026,
~11,800 commits)** compared against the current Inferno source. The goal is *ideas*,
not code theft: "they improved X well by doing Y — should we?" 9front and Inferno
share Plan 9 C heritage, so the portable libraries and the (C) kernel overlap;
Inferno's userspace is Dis/Limbo, so native userspace does **not** port.

These are **candidates to evaluate**, not commitments. Some may be superseded by
vendoring decisions (e.g. mbedTLS for TLS).

## The corpus

| File | Topic | Immediate value to hosted emu |
|---|---|---|
| [draw.md](draw.md) | `libdraw` / `libmemdraw` / `libmemlayer` | **High** — shared code; new features + security fixes |
| [kernel-port.md](kernel-port.md) | portable kernel `9/port` → `emu/port` + `os/port` | **High** — several touch the live `emu/port` |
| [ip-stack.md](ip-stack.md) | `9/ip` + `libip` → `os/ip` + `emu/port/devip` | **Low** (mostly native-port-only) |

## The applicability split (read this — it shapes everything)

Inferno64 currently builds and runs the **hosted `emu`**. That changes which
9front work is transferable, per subsystem:

- **Draw libs:** `libmemdraw`/`libmemlayer` are pure pixel-pushing and port nearly
  verbatim. `libdraw`'s I/O half (devdraw protocol, mouse/kbd event loop) maps
  poorly — Inferno wraps draw via emu `devdraw` + the `Draw` Limbo module. → mine
  the pixel code, skip the client/event code.
- **Kernel:** the **hosted `emu/port`** shares `chan`/`pgrp`/`devmnt`/`qio`/
  `sysfile`/`dev` with `9/port` (these are live targets). But emu has **no
  VM/paging/scheduler of its own** (host pthreads + the libinterp Dis scheduler),
  so 9front's `proc.c`/`edf.c`/`segment.c`/`page.c`/`fault.c` work only applies to
  the **dormant native `os/port`**.
- **IP:** the hosted emu uses the **host OS TCP/IP stack** (`devip.c` is socket
  glue). 9front's TCP/UDP/IPv6 internals only apply to the **dormant native
  `os/ip`**. → mostly parked unless the native port is revived.

A recurring accelerant: 9front shares many fixes with **drawterm** (a hosted
Plan 9 terminal, architecturally identical to emu) — those commits port to
`emu/port` almost as-is.

## Deliberately out of scope

- **Crypto / `libsec` / `libmp`** — you're vendoring **mbedTLS**; the algorithm
  buildout (sha3, blake2, x25519, ecdsa, TLS1.2) is displaced. The one residual
  idea is the kernel **`devtls`** *architecture* (vs Inferno's old `devssl`), which
  ties into the existing `charon-tls-mbedtls` plan — tracked there, not here.
- **Native userspace** (rc, upas, git, gefs/cwfs/hjfs filesystems, nusb, vmx,
  the C compiler suite) — different from Dis/Limbo; not code-portable.
- **Design-only analogues** (acme, sam, rio≈wm, **mothra≈Charon**) — rich sources
  of *behavior* ideas for the Limbo apps, but not code ports. Not covered here per
  scope; revisit if you want a Charon-vs-mothra or acme UX-parity pass.

---

## Cross-cutting top picks (ranked for the hosted emu)

Best value/effort first. Each links to its detailed entry.

1. **9P/Styx iounit 8 KB → 32 KB** — [kernel-port.md#K1]. One file
   (`emu/port/devmnt.c`), large throughput win for all mounted-fs I/O. *Low effort.*
2. **`icossin2()` integer-overflow fix** — [draw.md#B2]. Inferno has the exact
   vulnerable code; port verbatim. *Trivial.*
3. **drawterm-sourced kernel fixes + `_Noreturn`** — [kernel-port.md#K3,K4].
   `waserror`/`longjmp`/`devwalk` correctness + lint-friendly annotations; aligns
   with the existing LP64/observability tooling. *Low effort.*
4. **`badrect()` + font-file validation** — [draw.md#B1,B3]. Cheap security
   hardening on attacker-controllable inputs (matters for Charon). *Low effort.*
5. **qio + sysfile/chan correctness pass** — [kernel-port.md#K5,K6]. A review
   batch over the live namespace/queue code; several real races/leaks. *Low–med.*
6. **Affine image warp** (`memaffinewarp`/`affinewarp`) — [draw.md#A1]. The one
   genuinely new high-value capability; benefits Charon, image viewers, Tk.
   *Medium-high effort, low risk.*
7. **Linear `pgrpcpy()` + 64-bit mountids** — [kernel-port.md#K2]. Removes an
   O(n²) on every fork; bigger blast radius, do after #1–#3. *Medium.*
8. **Monotonic `/dev/time`** — [kernel-port.md#K9]. QoL for timing code. *Low.*

Parked (revisit only on a native-port revival): the EDF scheduler fixes — esp.
the **µs-vs-ns unit bug** (`5deae3fbb`) and the **scheduler memory barrier**
before `up->mach = nil`, which ties into the known aarch64 ordering bug class —
plus the VM/pager work and the whole IP stack. See the Tier-3 / native sections
in [kernel-port.md](kernel-port.md) and [ip-stack.md](ip-stack.md).

---

## Method / provenance

- 9front tree: `../9front` (a sibling clone), HEAD ≈ 2026-06-03.
- Each file cites 9front commit hashes; verify with `git -C ../9front show <hash>`.
- "Inferno status" reflects a source check at the time of writing — **re-verify
  before acting**, especially that a named file/function still exists (this tree
  is under active LP64/dual-ABI work).
- Scope chosen with the user: draw + kernel + IP, curated idea lists, crypto
  excluded.
