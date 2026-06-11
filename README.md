# Inferno64 — Inferno with a 64-bit Dis ABI

**Inferno64** is a fork of [Inferno](https://github.com/inferno-os/inferno-os)
whose Dis virtual machine, Limbo compiler, and hosted emulator build for a
**64-bit pointer model** in addition to the original 32-bit one. Upstream
Inferno assumes a 32-bit Dis pointer/register slot, so on a 64-bit host the
emulator could only run with a 32-bit toolchain (or `-m32`); this fork makes the
Dis ABI itself 64-bit-clean, including an **AArch64 (ARM64) JIT**.

**IMPORTANT:** THIS PORT IS NOT PROVED TO BE BUG FREE. This will boot into
the emu on aarch64 and you can do *most* desktop GUI work, but certain things
may still be broken. Feel free to try it, and if you do run into a crash or
emu or wm freezes, then report it in a reproducible way and I'll see if I can
fix it.

The bugs that remain are mostly heap corruption from the 32/64-bit pointer work —
a known, bounded class, not black magic. If you want to help catch one, the
[heap-debugging guide](docs/ref/ON_C_IN_DIS.md#debugging-heap-corruption-when-prevention-fails)
explains *why* it happens and how to get a clean core + log on the first fault.

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
running emu directly, the JIT, debugging — see the documentation below.

## Documentation

The documentation lives under [`docs/`](docs/), organised as a
"**so you want to…**" index — start there:
**[`docs/README.md`](docs/README.md)**.

| if you want to… | see |
|---|---|
| the full "so you want to…" doc index | [`docs/README.md`](docs/README.md) |
| prerequisites, build, pick a profile, run emu directly, debug | [`docs/ON_BUILDING.md`](docs/ON_BUILDING.md) |
| why your code behaves the same on every host (the 32/64-bit story) | [`docs/ref/ON_C_IN_DIS.md`](docs/ref/ON_C_IN_DIS.md) |

## Will my code behave the same on every machine?

**Yes — that's the whole point of Inferno.** You write Limbo, the compiler turns it
into portable Dis bytecode, and the virtual machine runs it the same way on every
host: a 32-bit ARM board and a 64-bit server give identical results — same
arithmetic, same overflow, same layout — *as long as the emulator has been ported
to that host correctly*. Your **source code never changes**; at most the compiled
`.dis` is rebuilt for a different machine.

Keeping that promise on modern 64-bit machines (where a pointer is 64 bits but a
Limbo `int` is deliberately still 32) took real work down in the C core. If you're
going to hack on the C side, that's the one thing worth understanding — the full
story, with per-platform tables, is in
**[`docs/ref/ON_C_IN_DIS.md`](docs/ref/ON_C_IN_DIS.md)**.

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

- **Limbo by Example** (`docs/ref/limbobyexample/`) is by Sean "henesy" Hinchee —
  <https://github.com/henesy/limbobyexample>
- The LP64 regression suite under `tests/lp64/` draws on the test programs in
  caerwynj's **inferno-lab** — <https://github.com/caerwynj/inferno-lab>

Mostly these are included here for convenience

---

Inferno® is a distributed operating system, originally developed at Bell Labs, but now developed and maintained by Vita Nuova® as Free Software.  Applications written in Inferno's concurrent programming language, Limbo, are compiled to its portable virtual machine code (Dis), to run anywhere on a network in the portable environment that Inferno provides.  Unusually, that environment looks and acts like a complete operating system.

Inferno represents services and resources in a file-like name hierarchy.  Programs access them using only the file operations open, read/write, and close.  `Files' are not just stored data, but represent devices, network and protocol interfaces, dynamic data sources, and services.  The approach unifies and provides basic naming, structuring, and access control mechanisms for all system resources.  A single file-service protocol (the same as Plan 9's 9P) makes all those resources available for import or export throughout the network in a uniform way, independent of location. An application simply attaches the resources it needs to its own per-process name hierarchy ('name space').

Inferno can run 'native' on various ARM, PowerPC, SPARC and x86 platforms but also 'hosted', under an existing operating system (including AIX, FreeBSD, IRIX, Linux, MacOS X, Plan 9, and Solaris), again on various processor types.

This repository includes source code for the basic applications, Inferno itself (hosted and native), all supporting software, including the native compiler suite, essential executables and supporting files.
