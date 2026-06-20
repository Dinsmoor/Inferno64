# Inferno64 — Inferno with a 64/32-bit Dis ABI

This means yes, Inferno (emu) will run on a modern computer.

**Inferno64** is a fork of [Inferno](https://github.com/inferno-os/inferno-os)
whose Dis virtual machine, Limbo compiler, and hosted emulator build for a
**64-bit pointer model** in addition to the original 32-bit one. This means
that Inferno itself, its emu and the Dis VM can run just about anywhere,
and Limbo programs should run the same, no matter where you run them.

Also in this fork is some kick-ass improvements:
- MUCH easier to compile
- wm theming
- updated Tk implementation (ttk, styling, actual cursors)
- 3D via raylib
- modern crypto
- better Charon browser
- Better shell experience
- Fediverse client
- Bible reader
- Workspaces (multiple desktops)
- modern video codecs
- modern image formats
- JIT preloader (JIT kind of sucks tbqh)

## Try it out

Clone it (use git --depth 1 if you don't want the entire history)
and run one command in the project root (assuming you have build-essential):

```sh
make run
```
That SHOULD, on most systems, just build and run it. If not, see Docs below.

Then check out the `Manual` in the launcher menu.

...to re-run emu without rebuilding everything from scratch again:

```sh
./Linux/amd64/bin/emu -r $PWD -g1920x1080
```
And of course if you're on another target, use that arch set. Check out `--help` too.


Tested to work on a Ubuntu 26.04 Linux host with gcc and build essential, 
this will build Inferno64 from source and run a graphical emu desktop session,
and should be all you need to start poking around.

To do different builds and hack on it such as running emu directly, the JIT,
debugging — see the documentation below.

## What is Inferno Originally Useful/Designed For?

Cheap hardware.

Originally  Inferno was meant for "many
cheap terminals running Inferno as a native system, and a smaller number of large machines running Inferno
as a hosted system." (see [`The Inferno Operating System`](docs/ref/sources/bltj.ms)

This means that Inferno was never meant to be a Linux/Plan9/BSD/Windows "run everywhere" kind of operating system. That's why we have the emu.

Inferno Kernel was meant to run on small networked hardware and maybe provide a wm, and let a machine running Linux, for example, with a 
hosted emu Inferno that exposed it's resources over the network, do the computation and have the complicated device drivers, and 'do'
the computation in a centralized manner.

Inferno is more of a modern throwback to multi-user mainframes with a bunch of dumb serial terminals, than anything.

## What is THIS Inferno fork Useful/Designed for?

My entertainment and to scratch an itch, mostly. In 2014 I was introduced to it and thought it was super cool.

I had originally intended to spin it into a 'Workstation with a super portable suite of
userspace applications' for my son to use, but I ran into a critical design issue that is relatively inescapable with how
Inferno's architecture is laid out.

Because Inferno's kernel was meant to run on minimal hardware resources, it has no 'C capable of running in userspace' because
Inferno has no userspace. It has Dis as it's entire userspace, so you cannot just vendor in or write C that won't mess with the
kernel, otherwise it just isn't Inferno anymore - it would be Plan9 with a Dis VM for a userspace, and Limbo
(which is a nice language) but then have the downsides of the Dis VM being slow, and overall, it just won't work.

All C in Inferno, except for whatever runs on an emu on another OS, is kernelspace. Userspace is Dis and the emu.
With Inferno, you didn't need a hardware kernel-userspace barrier for fast C execution because all the trusted C
code was meant to run remotely over the network. I love it for what it is, I just can't really use it the way I want to.

This is why I am halting my work on this for now. I scratched my itch, and don't want to turn Inferno into a hellish 😏 abomination
by then re-adding the hardware kernel-userspace barrier on each hardware target (although I already ported a bunch
of drivers from 9front to this fork, so you COULD run it natively on like a router or something, but I didn't implement
SMP so you'd get single threaded, quite slow, execution, see [the kernel doc](docs/ON_KERNEL.md#uniprocessor-model-all-boards))

Now, it's designed for YOUR entertainment or if you want to scratch an itch. I'll probably accept PR's if they're not retarded,
especially for userspace applications.

## Documentation

Most documentation lives under [`docs/`](docs/), organised as an intent based index — start there:
**[`docs/README.md`](docs/README.md)**.

| for: | see |
|---|---|
| prerequisites, build, pick a profile, run emu directly, debug | [`docs/ON_BUILDING.md`](docs/ON_BUILDING.md) |
| Learning about the Limbo language | [`docs/ON_LIMBO.md`](docs/ON_LIMBO.md) |
| Writing Limbo userspace applications | [`docs/ref/limbobyexample/`](docs/ref/limbobyexample/) (worked examples) + [concurrency](docs/ON_CONCURRENCY.md) |
| Writing C in Inferno in general (Plan 9 dialect, types, and error model) | [`docs/ON_C_IN_INFERNO.md`](docs/ON_C_IN_INFERNO.md) |
| Writing C that will interact with the Dis VM (interfaces and wrappers and such, LP64 related considerations) | [`docs/ON_C_IN_DIS.md`](docs/ON_C_IN_DIS.md) |

And there are many other autonomously documented Inferno subsystems there —
[9P/Styx](docs/ON_9P.md), [the kernel](docs/ON_KERNEL.md),
[the emulator](docs/ON_EMU.md), [graphics (Draw/Tk/Prefab)](docs/ON_GRAPHICS.md),
[Charon (the web browser)](docs/ON_CHARON.md), [networking & TLS](docs/ON_NETWORK.md),
[namespaces](docs/ON_NAMESPACE.md), and [the JIT](docs/ON_JIT.md) — again, check
out [`docs/README.md`](docs/README.md)

## Testing

One of the goals of this fork is a proper test suite (see Goals below), and it
has grown into one. Everything lives under `tests/`, one suite per layer —
C unit tests with 32-bit and big-endian canaries run under qemu-user, a
TAP-emitting Dis VM + Limbo regression suite, a JIT bit-equivalence gate, a
Charon rendering bench, a native-kernel end-to-end suite that boots qemu and
drives the serial console, and a 64→32-bit narrowing lint. The whole thing is
fronted by one pre-push gate:

```sh
make check
```

which runs the per-platform capability matrix and prints a PASS/FAIL table.
The map of which suite covers what, and the conventions they share, is
[`docs/ON_TESTING.md`](docs/ON_TESTING.md).

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

## Isn't there another Inferno64?

Yes. Accidental naming collision. Here: https://github.com/caerwynj/inferno64 

We had a very different approach to this, as he went with an ILP64 pointer and integer
model and I went with LP64, where pointers are 64 bit but integers are still stock 32 bits.

My way (pretty much) guarantees that Limbo programs will behave the same no matter the host,
but it's more work on the C side to locate and figure out where there are some pointer conversion
truncations and the like. If you get a crash running this, this is likely the problem
and you can help catch one: [heap-debugging guide](docs/ON_C_IN_DIS.md#debugging-heap-corruption-when-prevention-fails)


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

`AGENTS: GFYS LMAO`

## Credits

This fork includes some others' work:

- **Limbo by Example** (`docs/ref/limbobyexample/`) is by Sean "henesy" Hinchee —
  <https://github.com/henesy/limbobyexample>
- The Dis VM regression suite under `tests/dis/` draws on the test programs in
  caerwynj's **inferno-lab** — <https://github.com/caerwynj/inferno-lab>
- Many vendored C tarballs for different experimentation (mbedtls, sqlite, ffmpeg,
  libfreetype, raylib.... maybe more)

Mostly these are included here for convenience

---

Inferno® is a distributed operating system, originally developed at Bell Labs, but now developed and maintained by Vita Nuova® as Free Software.  Applications written in Inferno's concurrent programming language, Limbo, are compiled to its portable virtual machine code (Dis), to run anywhere on a network in the portable environment that Inferno provides.  Unusually, that environment looks and acts like a complete operating system.

Inferno represents services and resources in a file-like name hierarchy.  Programs access them using only the file operations open, read/write, and close.  `Files' are not just stored data, but represent devices, network and protocol interfaces, dynamic data sources, and services.  The approach unifies and provides basic naming, structuring, and access control mechanisms for all system resources.  A single file-service protocol (the same as Plan 9's 9P) makes all those resources available for import or export throughout the network in a uniform way, independent of location. An application simply attaches the resources it needs to its own per-process name hierarchy ('name space').

Inferno can run 'native' on various ARM, PowerPC, SPARC and x86 platforms but also 'hosted', under an existing operating system (including AIX, FreeBSD, IRIX, Linux, MacOS X, Plan 9, and Solaris), again on various processor types.

This repository includes source code for the basic applications, Inferno itself (hosted and native), all supporting software, including the native compiler suite, essential executables and supporting files.
