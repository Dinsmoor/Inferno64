# Inferno64 documentation

This is the documentation tree. It is meant to be read by humans (and the demon
machine) — not babied, but explained, with the gotchas written down where we hit
them. If you are just trying to *run* Inferno64, go back to the top-level
[`README.md`](../README.md) and `make run`. If you want to build it or hack on
it, start at [`ON_BUILDING.md`](ON_BUILDING.md).

## How this tree is organised

- **`ON_<topic>.md`** — topic references, written "so you want to *X*": what the
  thing is, how it actually works here, and the gotchas. They live in
  [`ref/`](ref/) (except [`ON_BUILDING.md`](ON_BUILDING.md), which is up here
  because it's the first thing you read).
- **`DEV_<topic>.md`** — the live development view: what is being worked on right
  now, what is parked. [`DEV_INPRO.md`](DEV_INPRO.md) is the in-progress
  checklist; when an item grows real detail it moves into the `ON_` doc it
  belongs to.
- The dual-ABI story — *why* a Limbo `int` is 32 bits (the LP64-vs-ILP64 decision,
  with per-arch tables) **and** everything the LP64 port added — is one doc:
  [`ref/ON_THE_DUAL_ABI.md`](ref/ON_THE_DUAL_ABI.md).
- **`ref/`** also holds reference material we didn't write — the rendered Limbo
  manuals (`*.html`) and Sean Hinchee's [`limbobyexample/`](ref/limbobyexample/).

## So you want to…

### …write Limbo

| …do this | read |
|---|---|
| write a Limbo program (language, compiler, modules) | [`ref/ON_LIMBO.md`](ref/ON_LIMBO.md) |
| use channels, `spawn`, `alt` (the concurrency model) | [`ref/ON_CONCURRENCY.md`](ref/ON_CONCURRENCY.md) |
| handle errors / exceptions (and why it's two awkward layers) | [`ref/ON_LIMBO_ERROR_HANDLING.md`](ref/ON_LIMBO_ERROR_HANDLING.md) |
| see small worked examples | [`ref/limbobyexample/`](ref/limbobyexample/) |
| debug a *Limbo program* (`/prog`, exceptions, `disdump`) | [`ref/ON_DEBUGGING.md`](ref/ON_DEBUGGING.md) |

### …work on the VM / the port

| …do this | read |
|---|---|
| understand the Dis VM (bytecode, GC, channels) | [`ref/ON_DIS.md`](ref/ON_DIS.md) |
| understand how Dis is realised on a host/ABI | [`ref/ON_DIS_ARCH.md`](ref/ON_DIS_ARCH.md) |
| write or extend the native-code JIT | [`ref/ON_JIT.md`](ref/ON_JIT.md) |
| port emu to a new host system | [`ref/ON_PORTING.md`](ref/ON_PORTING.md) → [`ref/ON_AARCH64_PORT.md`](ref/ON_AARCH64_PORT.md) |
| understand the 32/64-bit dual ABI — *why* Limbo `int` is 32-bit everywhere, the tables, how one tree builds both | [`ref/ON_THE_DUAL_ABI.md`](ref/ON_THE_DUAL_ABI.md) |
| dig into the emulator's architecture | [`ref/ON_EMU.md`](ref/ON_EMU.md) |
| debug the *emu itself* (C-level faults, hangs, cores) | [`ref/ON_EMU_DEBUG.md`](ref/ON_EMU_DEBUG.md) |
| read the kernel internals | [`ref/ON_KERNEL.md`](ref/ON_KERNEL.md) |

### …work on graphics, the web stack, or I/O

| …do this | read |
|---|---|
| use Draw / Tk / prefab, or wm windows | [`ref/ON_GRAPHICS.md`](ref/ON_GRAPHICS.md) |
| do software 3D (raylib-in-Limbo, `$Raster3`) | [`ref/ON_3D.md`](ref/ON_3D.md) |
| decode images (PNG/JPEG → Draw) | [`ref/ON_IMAGEIO.md`](ref/ON_IMAGEIO.md) |
| hack on Charon (the web browser) | [`ref/ON_CHARON.md`](ref/ON_CHARON.md) |
| do network programming / TLS | [`ref/ON_NETWORK.md`](ref/ON_NETWORK.md) |
| understand 9P/Styx | [`ref/ON_9P.md`](ref/ON_9P.md) |
| understand namespaces | [`ref/ON_NAMESPACE.md`](ref/ON_NAMESPACE.md) |

### …extend the C side

| …do this | read |
|---|---|
| vendor a new external C library | [`ref/ON_STB.md`](ref/ON_STB.md) (the worked example — a dedicated guide is TODO) |
| understand why you *can't* load native C modules at runtime | [`ref/ON_DLM.md`](ref/ON_DLM.md) |
| build, pick a profile, run emu directly, catch heap bugs | [`ON_BUILDING.md`](ON_BUILDING.md) |
