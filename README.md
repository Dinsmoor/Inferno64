# Inferno64 — Inferno with a 64/32-bit Dis ABI

**Inferno64** is a fork of [Inferno](https://github.com/inferno-os/inferno-os)
whose Dis virtual machine, Limbo compiler, and hosted emulator build for a
**64-bit pointer model** in addition to the original 32-bit one. This means
that Inferno itself, its emu and the Dis VM can run anywhere, Limbo and userspace
should run the same, no matter where you run them (with the exception of
userspace programs that need more addressing space than 32 bits can provide.)

Also in this release is some kick-ass userspace improvements.

Something to be noted, another project (also named Inferno64) is inferior as it
uses an ILP64 ABI model instead of an LP64 one, which means the size of an int
in Limbo (the supposedly super-portable language compiled into Dis bytecode
and run in a VM) is dependant on your platform. This means not only that the Dis
bytecode is incompatible (between 32 and 64 bit pointer archs we know this),
the source Limbo itself is incompatible, and gives undefined behavior.
That inferior project is:  https://github.com/caerwynj/inferno64 

Nothing against that project author by the way, I started work on Inferno64 and
did not know that his project existed, and I tried to use ILP64 (we have a
branch for ILP64 that builds a working emu with JIT and everything,
but it is just inferior for the purposes of Limbo's portability, which was a major
design point of even having the Dis VM in the first place.)

That being said, there are still bugs that exist in every piece of software,
this hobby ABI port notwithstanding. The bugs that remain are either normal
logic bugs, a few use-after-frees, or heap corruption from the 32/64-bit pointer work —
a known, bounded class, that depends on good C pointer handling discipline.
If you run into and want to help catch one (your entire EMU crashes, for example), the
[heap-debugging guide](docs/ON_C_IN_DIS.md#debugging-heap-corruption-when-prevention-fails)
explains why it happens and how to get a clean core + log on the first fault, so we can
fix it.

## Try it out

Clone it and run one command in the project root (assuming you have build-essential):

```sh
make run
```

This will build Inferno64 from source, and should be all you need to poke around.
To do different builds and hack on it such as running emu directly, the JIT,
debugging — see the documentation below.

## Documentation

Most documentation lives under [`docs/`](docs/), organised as an intent based index — start there:
**[`docs/README.md`](docs/README.md)**.

| if you want to: | see |
|---|---|
| prerequisites, build, pick a profile, run emu directly, debug | [`docs/ON_BUILDING.md`](docs/ON_BUILDING.md) |
| Learn about the Limbo language | [`docs/ON_LIMBO.md`](docs/ON_LIMBO.md) |
| Write Limbo userspace applications | [`docs/ref/limbobyexample/`](docs/ref/limbobyexample/) (worked examples) + [concurrency](docs/ON_CONCURRENCY.md) |
| Write C in Inferno in general (Plan 9 dialect, types, and error model) | [`docs/ON_C_IN_INFERNO.md`](docs/ON_C_IN_INFERNO.md) |
| Write C that will interact with the Dis VM (interfaces and wrappers and such, LP64 related considerations) | [`docs/ON_C_IN_DIS.md`](docs/ON_C_IN_DIS.md) |

And there are many other autonomously documented Inferno subsystems there —
[9P/Styx](docs/ON_9P.md), [the kernel](docs/ON_KERNEL.md),
[the emulator](docs/ON_EMU.md), [graphics (Draw/Tk/Prefab)](docs/ON_GRAPHICS.md),
[Charon (the web browser)](docs/ON_CHARON.md), [networking & TLS](docs/ON_NETWORK.md),
[namespaces](docs/ON_NAMESPACE.md), and [the JIT](docs/ON_JIT.md) — again, check
out [`docs/README.md`](docs/README.md)

## Will my code behave the same on every machine?

Yes, YOUR Limbo source code will. Your .dis binaries will likely not.

This is the main reason I went with an LP64 model instead of ILP64. If you try to
distribute a .dis bytecode binary, then no, it will likely not, because turns
out pointer models actually matter a lot. ILP64 guarantees nothing between platforms.

I have a few ideas on how to nicely handle this for users,
(right now I wrote a `hey this .dis file is wrong for this platform: recompile it`
handler, but as for how to make this more portable (allow for distribution of
.dis files) - I might just bundle the source with the .dis files... idk.
It's an open design question for me.

Maybe a package manager that will recompile .dis on every target arch, you upload
the source, the repo will basically do CI. TBD.

## Are you going to try to push your changes to the upstream repository?

No, I am doing my own thing, but if they want to talk to me then that's fine.

## Goals for Tyler's Inferno64

1. Make Inferno run nicely on a LP64 ABI
2. Make JIT compilation worth it
3. Make a proper test suite and harnesses to find memory bugs fast and make debugging easier
4. Modernize some of the userspace applications to where 'i like them' and they are nice to use
5. Make some backward compatible improvements to Limbo (flesh out the undocumented Generics feature, improve compiler hints, etc)
6. Improve Inferno documentation
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

## Credits

This fork includes some others' work:

- **Limbo by Example** (`docs/ref/limbobyexample/`) is by Sean "henesy" Hinchee —
  <https://github.com/henesy/limbobyexample>
- The Dis VM regression suite under `tests/dis/` draws on the test programs in
  caerwynj's **inferno-lab** — <https://github.com/caerwynj/inferno-lab>

Mostly these are included here for convenience

---

Inferno® is a distributed operating system, originally developed at Bell Labs, but now developed and maintained by Vita Nuova® as Free Software.  Applications written in Inferno's concurrent programming language, Limbo, are compiled to its portable virtual machine code (Dis), to run anywhere on a network in the portable environment that Inferno provides.  Unusually, that environment looks and acts like a complete operating system.

Inferno represents services and resources in a file-like name hierarchy.  Programs access them using only the file operations open, read/write, and close.  `Files' are not just stored data, but represent devices, network and protocol interfaces, dynamic data sources, and services.  The approach unifies and provides basic naming, structuring, and access control mechanisms for all system resources.  A single file-service protocol (the same as Plan 9's 9P) makes all those resources available for import or export throughout the network in a uniform way, independent of location. An application simply attaches the resources it needs to its own per-process name hierarchy ('name space').

Inferno can run 'native' on various ARM, PowerPC, SPARC and x86 platforms but also 'hosted', under an existing operating system (including AIX, FreeBSD, IRIX, Linux, MacOS X, Plan 9, and Solaris), again on various processor types.

This repository includes source code for the basic applications, Inferno itself (hosted and native), all supporting software, including the native compiler suite, essential executables and supporting files.
