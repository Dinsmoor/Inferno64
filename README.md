# Inferno64 — Inferno with a 64-bit (LP64) Dis ABI

**Inferno64** is a fork of [Inferno](https://github.com/inferno-os/inferno-os)
whose Dis virtual machine, Limbo compiler, and hosted emulator build for a
**64-bit (LP64) pointer model** in addition to the original 32-bit one. Upstream
Inferno assumes a 32-bit Dis pointer/register slot, so on a 64-bit host the
emulator could only run with a 32-bit toolchain (or `-m32`); this fork makes the
Dis ABI itself 64-bit-clean, including a from-scratch **AArch64 (ARM64) JIT**.

## One source tree, either ABI

The same source tree builds for **either** Dis ABI, chosen automatically by the
host's pointer width — build on a 32-bit system and you get the 32-bit ABI, build
on a 64-bit system and you get the 64-bit ABI:

- `include/isa.h` defines `IBY2PTR = sizeof(void*)` — the size of a Dis
  pointer/register slot. All width-dependent layout (frame slots, pointer-typed
  fields, GC pointer-map granularity) is expressed symbolically in terms of
  `IBY2PTR` versus `IBY2WD` (the 4-byte Dis word, unchanged).
- The `.dis` object magic carries a pointer-width tag: a 32-bit build stamps and
  accepts `XMAGIC`/`SMAGIC`, a 64-bit build uses `XMAGIC8`/`SMAGIC8`. The magic is
  stamped by the compiler (`limbo/com.c`) and checked by the loader
  (`libinterp/load.c`), so a VM never silently executes a foreign-layout module;
  a wrong-width module is rejected (`exDiswidth`) and the shell recompiles it from
  source when available.
- A compile-time assertion in `libinterp/xec.c` (`sizeof(void*) == IBY2PTR`) makes
  any width mismatch a build error rather than a memory-corruption bug.

The two ABIs' `.dis` binaries are not interchangeable, but `.b`/`.m` Limbo source,
the test suites, and the build tooling are shared — there is no separate branch to
maintain per ABI.

## What was done

- LP64-correct Dis VM and loader (pointer/word width discipline, big/real
  constant encoding, exception unwinding, string-case tables, GC maps).
- A complete **AArch64 hosted emulator** (`emu`/`emu-g`) and host toolchain
  (`limbo`, `mk`, `iyacc`), plus `Linux/amd64` glue.
- A from-scratch **AArch64 Dis JIT** (`libinterp/comp-aarch64.c`) — the first
  64-bit JIT back-end for Inferno. Off by default (interpreter); enabled with
  `emu -c1`/`-c2`.
- The GUI stack (draw, Tk, prefab, vendored FreeType) runs under X11 on LP64.

The regression battery in `tests/lp64/` (8 suites, 166 assertions) passes 166/166
both interpreted and JIT-compiled (`-c1`) on the AArch64 host, including the Limbo
compiler compiling itself.

For implementation detail and the durable engineering notes, see `ref/AGENTS_*.md`
(start with `ref/AGENTS_INPRO.md`).

> Note: the self-hosting Limbo compiler `appl/cmd/limbo/isa.m` carries `IBY2PTR`
> as a literal constant (Limbo has no `sizeof`), so for a 32-bit build of the
> in-tree `/dis` toolchain that value must be set to 4 to match the build ABI.

---

Inferno® is a distributed operating system, originally developed at Bell Labs, but now developed and maintained by Vita Nuova® as Free Software.  Applications written in Inferno's concurrent programming language, Limbo, are compiled to its portable virtual machine code (Dis), to run anywhere on a network in the portable environment that Inferno provides.  Unusually, that environment looks and acts like a complete operating system.

Inferno represents services and resources in a file-like name hierarchy.  Programs access them using only the file operations open, read/write, and close.  `Files' are not just stored data, but represent devices, network and protocol interfaces, dynamic data sources, and services.  The approach unifies and provides basic naming, structuring, and access control mechanisms for all system resources.  A single file-service protocol (the same as Plan 9's 9P) makes all those resources available for import or export throughout the network in a uniform way, independent of location. An application simply attaches the resources it needs to its own per-process name hierarchy ('name space').

Inferno can run 'native' on various ARM, PowerPC, SPARC and x86 platforms but also 'hosted', under an existing operating system (including AIX, FreeBSD, IRIX, Linux, MacOS X, Plan 9, and Solaris), again on various processor types.

This repository includes source code for the basic applications, Inferno itself (hosted and native), all supporting software, including the native compiler suite, essential executables and supporting files.
