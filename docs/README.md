# Inferno64 documentation

This is the documentation tree. It is meant to be read by humans (and the demon
machine) — not babied, but explained, with the gotchas written down where we hit
them. If you are just trying to *run* Inferno64, go back to the top-level
[`README.md`](../README.md) and `make run`. If you want to build it or hack on
it, start at [`ON_BUILDING.md`](ON_BUILDING.md).

## How this tree is organised

- **`ON_<topic>.md`** — topic references, written "so you want to *X*": what the
  thing is, how it actually works here, and the gotchas. They live right here at
  the top of `docs/`; [`ON_BUILDING.md`](ON_BUILDING.md) is the one to read first.
- **`DEV_<topic>.md`** — the live development view: what is being worked on right
  now, what is parked. [`DEV_INPRO.md`](DEV_INPRO.md) is the in-progress
  checklist; when an item grows real detail it moves into the `ON_` doc it
  belongs to.
- The dual-ABI story — *why* a Limbo `int` is 32 bits (the LP64-vs-ILP64 decision,
  with per-arch tables) **and** everything the LP64 port added — is one doc:
  [`ON_C_IN_DIS.md`](ON_C_IN_DIS.md).
- **`ref/`** holds reference material we *didn't* write — the original Bell Labs /
  Vita Nuova manuals and papers as **rendered `*.pdf`** (`dis`, `limbo`, `styx`,
  `sh`, `acid`, `mk`, `compiler`, …) plus a couple of `*.html`, with the troff
  `*.ms` originals tucked under [`ref/sources/`](ref/sources/) for preservation,
  and Sean Hinchee's [`limbobyexample/`](ref/limbobyexample/). See
  [`ref/README.md`](ref/README.md) for the index of what every paper is and which
  living `ON_*.md` doc supersedes it.

## So you want to…

### …write Limbo

| …do this | read |
|---|---|
| write a Limbo program (language, compiler, modules) | [`ON_LIMBO.md`](ON_LIMBO.md) |
| use channels, `spawn`, `alt` (the concurrency model) | [`ON_CONCURRENCY.md`](ON_CONCURRENCY.md) |
| handle errors / exceptions (and why it's two awkward layers) | [`ON_LIMBO_ERROR_HANDLING.md`](ON_LIMBO_ERROR_HANDLING.md) |
| see small worked examples | [`ref/limbobyexample/`](ref/limbobyexample/) |
| debug a *Limbo program* (`/prog`, exceptions, `disdump`) | [`ON_DEBUGGING.md`](ON_DEBUGGING.md) |

### …work on the VM / the port

| …do this | read |
|---|---|
| understand the Dis VM (bytecode, GC, channels) | [`ON_DIS.md`](ON_DIS.md) |
| understand how Dis is realised on a host/ABI | [`ON_DIS_ARCH.md`](ON_DIS_ARCH.md) |
| write or extend the native-code JIT | [`ON_JIT.md`](ON_JIT.md) |
| port emu to a new host system | [`ON_PORTING.md`](ON_PORTING.md) → [`ON_AARCH64_PORT.md`](ON_AARCH64_PORT.md) |
| understand the 32/64-bit dual ABI — *why* Limbo `int` is 32-bit everywhere, the tables, how one tree builds both | [`ON_C_IN_DIS.md`](ON_C_IN_DIS.md) |
| dig into the emulator's architecture | [`ON_EMU.md`](ON_EMU.md) |
| debug the *emu itself* (C-level faults, hangs, cores) | [`ON_EMU_DEBUG.md`](ON_EMU_DEBUG.md) |
| read the kernel internals | [`ON_KERNEL.md`](ON_KERNEL.md) |

### …work on graphics, the web stack, or I/O

| …do this | read |
|---|---|
| use Draw / Tk / prefab, or wm windows | [`ON_GRAPHICS.md`](ON_GRAPHICS.md) |
| do software 3D (raylib-in-Limbo, `$Raster3`) | [`ON_3D.md`](ON_3D.md) |
| decode images (PNG/JPEG → Draw) | [`ON_IMAGEIO.md`](ON_IMAGEIO.md) |
| hack on Charon (the web browser) | [`ON_CHARON.md`](ON_CHARON.md) |
| do network programming / TLS | [`ON_NETWORK.md`](ON_NETWORK.md) |
| understand 9P/Styx | [`ON_9P.md`](ON_9P.md) |
| understand namespaces | [`ON_NAMESPACE.md`](ON_NAMESPACE.md) |

### …extend the C side

| …do this | read |
|---|---|
| write C in the codebase at all (Plan 9 dialect, types, error model) | [`ON_C_IN_INFERNO.md`](ON_C_IN_INFERNO.md) |
| write C that touches the Dis VM (the integer model + the one hazard) | [`ON_C_IN_DIS.md`](ON_C_IN_DIS.md) |
| debug or prevent heap corruption | [`ON_C_IN_DIS.md`](ON_C_IN_DIS.md#debugging-heap-corruption-when-prevention-fails) |
| vendor a new external C library | [`ON_C_IN_INFERNO.md`](ON_C_IN_INFERNO.md) → [`ON_STB.md`](ON_STB.md) (worked example) |
| understand why you *can't* load native C modules at runtime | [`ON_DLM.md`](ON_DLM.md) |
| build, pick a profile, run emu directly, catch heap bugs | [`ON_BUILDING.md`](ON_BUILDING.md) |
