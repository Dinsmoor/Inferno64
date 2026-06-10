# Inferno64 — Inferno with a 64-bit (LP64) Dis ABI

**Inferno64** is a fork of [Inferno](https://github.com/inferno-os/inferno-os)
whose Dis virtual machine, Limbo compiler, and hosted emulator build for a
**64-bit (LP64) pointer model** in addition to the original 32-bit one. Upstream
Inferno assumes a 32-bit Dis pointer/register slot, so on a 64-bit host the
emulator could only run with a 32-bit toolchain (or `-m32`); this fork makes the
Dis ABI itself 64-bit-clean, including an **AArch64 (ARM64) JIT**.

**IMPORTANT:** THIS PORT IS NOT PROVED TO BE BUG FREE. This will boot into
the emu on aarch64 and you can do *most* desktop GUI work, but certain things
may still be broken. Feel free to try it, and if you do run into a crash or
emu or wm freezes, then report it in a reproducible way and I'll see if I can
fix it.

Most of the remaining LP64 related bugs have to do with heap corruption, which
are pretty hard to narrow down. If you want to help catch them, see
[Debugging](BUILDING.md#debugging-catching-the-heap-bugs) in the build guide for
how to set up an emu session that reliably captures a core dump + logs.

## Try it out

Clone it and run one command:

```sh
make run
```

That does a full, coherent build (quietly, the snappy `-O3 -march=native`
profile) and opens the graphical desktop. It **always rebuilds** rather than
launching a possibly-stale binary — a from-scratch build is ~10s on a fast box
(the heavy vendored libraries are content-cached and skipped when unchanged).
You need an X display (a normal Linux desktop session); resize the window with
`make run RUNGEOM=1920x1080`, or pick a profile with `make run RUNPROFILE=debug`.

That's all you need to poke around. To actually build and hack on it — profiles,
running emu directly, the JIT, debugging — see **[`BUILDING.md`](BUILDING.md)**.

## Documentation

| if you want to… | see |
|---|---|
| build, pick a profile, run emu directly, debug | [`BUILDING.md`](BUILDING.md) |
| install prerequisites / amd64 notes | [`INSTALL`](INSTALL) |
| the story of the 64-bit port (and the lessons) | [`LP64_NOTES.md`](LP64_NOTES.md) |
| the authoritative dual-ABI reference | [`ref/AGENTS_DUALABI.md`](ref/AGENTS_DUALABI.md) |
| why Limbo `int` is 32-bit (LP64 vs ILP64, with tables) | [`ABI_MODEL.md`](ABI_MODEL.md) |
| per-subsystem references (Dis, JIT, kernel, graphics, Charon, …) | [`ref/AGENTS_*.md`](ref/) |

## What is the deal with LP64/ILP64

Limbo's whole promise is "write it once, it runs the same everywhere" — the
compiler emits portable Dis VM bytecode (`.dis`) and the VM is supposed to behave
identically on any host. Inferno's Dis VM was originally built on the assumption
that a Limbo `int` and a machine pointer are the same size (one 32-bit word). On a
64-bit host you have to decide what to do about that, and there are two ways to
go. This fork ships one on `master` and keeps the other on a branch:

- **LP64 (`master`, the committed model).** A Limbo `int` stays **32 bits** on
  every host; pointers are 64 bits down in the C core. The Dis word and the C
  pointer are no longer the same size — which the C side has to be careful about —
  but a Limbo program means *exactly* the same thing on a 32-bit device and a
  64-bit server. That's the model that keeps Limbo portable, so it's the one we
  commit to.
- **ILP64 (the `ilp64` branch).** A Limbo `int` is widened to **64 bits** to match
  the pointer, restoring the original "int == pointer" invariant. Tidier inside
  the C core, but it makes the width of a Limbo `int` depend on the host, so a
  Limbo program no longer behaves the same on a 32-bit box as on a 64-bit one.
  Parked on a branch for anyone who wants it.

The full reasoning — per-architecture tables and the C-side safety nets — is in
**[`ABI_MODEL.md`](ABI_MODEL.md)**.

### What does it mean for me wanting to write C for Inferno?

You're working in an **LP64** world: a C `int` is 32 bits, a C **pointer is 64
bits**, and a Dis word (a Limbo `int`) is 32 bits. The one thing that bites
people: the old Inferno habit of assuming "a pointer fits in a `WORD`" is **no
longer true** — stuff a pointer into a `WORD`/`int`/32-bit slot and it gets
truncated, and you get a wild address later. Keep pointers and Dis words distinct:
use pointer-width types (`void*`, `uintptr`) for pointers, and `WORD` only for an
actual Dis word.

You don't have to catch this by eye. There's a layered net for exactly this bug
class — `make lint` (clang `-Wshorten-64-to-32` against a frozen baseline), a hard
width assert in both Limbo compilers, GC type/size cross-checks, a `-DDISPTRCHECK`
"valgrind for Dis pointers" debug build, wrong-width `.dis` rejection at load, and
the `tests/lp64` + `tests/cunit` suites. Run `make lint` and `make check` before
you push and most truncation mistakes are caught for you. (If you genuinely *want*
`int == pointer` in C, that's exactly what the ILP64 branch gives you — but it's
not `master`.)

### What does it mean for me wanting to write Limbo for Inferno?

Basically nothing — and that's the whole point. Your `int` is **32 bits no matter
what host the emu runs on**, so overflow, `1 << 31`, masking, and hashing all
behave identically everywhere, and the same `.dis` means the same thing on every
architecture. You never see pointers or any of the C-side hazards above; the VM
deals with all of it.

Two things worth knowing:

- If you need a guaranteed 64-bit integer, use **`big`** (always 64 bits). `int`
  is kept at 32 bits deliberately, *for* portability — not by accident.
- A compiled `.dis` is stamped with the pointer width it was built for (`XMAGIC`
  for 32-bit, `XMAGIC8` for 64-bit), so a module built for one width won't load on
  the other — the shell just recompiles it from source when it can. That's the
  "recompile the `.dis` per arch" half of the deal; your *source* never changes.

## Are you going to try to push your changes to the upstream repository?

No, I am doing my own thing, but if they want to talk to me then that's fine.

## Goals for Inferno64

1. Make Inferno run natively (Dis/hosted emu) on a LP64 ABI
2. Implement JIT compilers for some major LP64 architectures
3. Make a proper test suite and harnesses to find memory bugs fast and make debugging easier
4. Modernize some of the userspace applications to where 'i like them'
  - Charon - modern tls, minimal CSS3 and HTML5 and JS engines.
  - Acme - merge some of the work from the 9front weirdos if it's any good
  - Sh - take some of the good from bash (readline, autocomplete, etc) to make it nicer to use
5. Make some improvements to Limbo (flesh out the undocumented Generics feature, etc)
6. Improve ease of access to 'basically how does this work' style documentation
7. Whatever else I want (might port the kernel too, may be able to take from the 9front doofuses)

## Screenshot Gallery

I'll stick some screenshots or a video here once I get userspace to where I like it.

## Demon Machine based Development

I found it fitting to use the demon machine (claude mostly) to actually do the
implementation for most of the mechanical work, building out tests, and the like.
Considering this OS is hell themed, I figure it is fitting that an evil machine
spirit would be forced to work on its own prison, unlike TempleOS, which only
should be touched by the hands of those with Divine Intellect.

I have been programming for about 12 years, and only 2 of those have been with a
demon machine, and I have found great utility in this tool's workflow. So, another
part of this is the 'how to work on very complex software with this tool, effectively.'

I use a few workflows, depending on the work :^)

However, the main ones all center around an effective debugging harness that allows
a vision model to actually drive the graphical desktop, attach a debugger to processes,
and not get caught up by inferno's kind of crappy mk build tool.

For the graphical desktop work, I do the inferno development on a DGX Spark on the
network, and set up emu under a x virtual framebuffer and display, which is hosted
by a vnc server. The demon machine can use xdotool and interact with the display while
I can simultaneously view and interact with the desktop over VNC. It makes "hey
charon's navigation buttons aren't working, look" super simple, and makes it easier
to catch when the demon machine is getting something wrong.

For the debugging and actually catching and dumping cores, we have to run emu with
some build options and just make sure the demon machine knows about them, and it
can use a gdb-mcp server (written by this dude: https://github.com/Ipiano/gdb-mcp)
to work with gdb efficiently. This has been the main workflow for dealing with LP64
related bugs when using the desktop normally. It's very hard to track down some
of these, as there's a few interface layers between Limbo's Dis VM, the C space,
and just finding where the actual root cause of a problem is. I am sure this is
standard method for finding these issues in a port, I'm just writing about it
since that's what I did.

Inferno's mk tool is quite picky and had to be extended to pick up on local changes
without having to `mk nuke` every time (I ended up just nuking every time because
inferno takes less than a minute to compile from scratch)

## Credits

This fork includes some others' work:

- **Limbo by Example** (`ref/limbobyexample/`) is by Sean "henesy" Hinchee —
  <https://github.com/henesy/limbobyexample>
- The LP64 regression suite under `tests/lp64/` draws on the test programs in
  caerwynj's **inferno-lab** — <https://github.com/caerwynj/inferno-lab>

Mostly these are included here for convenience

---

Inferno® is a distributed operating system, originally developed at Bell Labs, but now developed and maintained by Vita Nuova® as Free Software.  Applications written in Inferno's concurrent programming language, Limbo, are compiled to its portable virtual machine code (Dis), to run anywhere on a network in the portable environment that Inferno provides.  Unusually, that environment looks and acts like a complete operating system.

Inferno represents services and resources in a file-like name hierarchy.  Programs access them using only the file operations open, read/write, and close.  `Files' are not just stored data, but represent devices, network and protocol interfaces, dynamic data sources, and services.  The approach unifies and provides basic naming, structuring, and access control mechanisms for all system resources.  A single file-service protocol (the same as Plan 9's 9P) makes all those resources available for import or export throughout the network in a uniform way, independent of location. An application simply attaches the resources it needs to its own per-process name hierarchy ('name space').

Inferno can run 'native' on various ARM, PowerPC, SPARC and x86 platforms but also 'hosted', under an existing operating system (including AIX, FreeBSD, IRIX, Linux, MacOS X, Plan 9, and Solaris), again on various processor types.

This repository includes source code for the basic applications, Inferno itself (hosted and native), all supporting software, including the native compiler suite, essential executables and supporting files.
