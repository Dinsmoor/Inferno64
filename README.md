# Inferno64 — Inferno with a 64-bit (ILP64) Dis ABI

**Inferno64** is a fork of [Inferno](https://github.com/inferno-os/inferno-os)
whose Dis virtual machine, Limbo compiler, and hosted emulator run on a **64-bit
pointer model**, including an **AArch64 (ARM64) JIT**. Upstream Inferno assumes a
32-bit Dis pointer/register slot, so on a 64-bit host the emulator could only run
with a 32-bit toolchain (or `-m32`); this fork makes the Dis ABI itself
64-bit-clean.

Inferno64 uses the **ILP64** model: a Limbo `int`, a `big`, a pointer, and a Dis
register slot are all 64 bits wide. There's also an older **LP64** variant — `int`
stays 32-bit and only pointers widen — that lives on a branch; it works, but its
split between word-width and pointer-width made heap-corruption bugs miserable to
track down, which is why ILP64 is the way forward. See
[LP64 vs ILP64](#lp64-vs-ilp64--two-ways-to-be-64-bit) below for the full
comparison and what each means for Limbo and C development.

**IMPORTANT:** THIS PORT IS NOT PROVED TO BE BUG FREE. This will boot into
the emu on aarch64 and you can do *most* desktop GUI work, but certain things
may still be broken. Feel free to try it, and if you do run into a crash or
emu or wm freezes, then report it in a reproducible way and I'll see if I can
fix it.

Moving to ILP64 deliberately killed off the worst bug class — the pointer
truncation that drove the heap corruption under LP64 — so it should be sturdier,
but it is not proved clean. If you want to help catch what's left, see
[Debugging](BUILDING.md#debugging-catching-the-heap-bugs) in the build guide for
how to set up an emu session that reliably captures a core dump + logs.

For the nasty class where the crash lands nowhere near the cause, there's a
built-in electric-fence mode (`LIMBRULFENCEMEMSIZE`) that quarantines one heap
size-class so a stray or use-after-free write faults *at the culprit* — it's what
finally pinned a years-old free-tree corruption to a use-after-free in proc-group
teardown.

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
| per-subsystem references (Dis, JIT, kernel, graphics, Charon, …) | [`ref/AGENTS_*.md`](ref/) |

## Are you going to try to push your changes to the upstream repository?

No, I am doing my own thing, but if they want to talk to me then that's fine.

## Goals for Inferno64

1. Make Inferno run natively (Dis/hosted emu) on a 64-bit (ILP64) ABI
2. Implement JIT compilers for some major LP64 architectures
3. Make a proper test suite and harnesses to find memory bugs fast and make debugging easier
4. Modernize some of the userspace applications to where 'i like them'
  - Charon - modern tls, minimal CSS3 and HTML5 and JS engines.
  - Acme - merge some of the work from the 9front weirdos if it's any good
  - Sh - take some of the good from bash (readline, autocomplete, etc) to make it nicer to use
5. Make some improvements to Limbo (flesh out the undocumented Generics feature, etc)
6. Improve ease of access to 'basically how does this work' style documentation
7. Whatever else I want (might port the kernel too, may be able to take from the 9front doofuses)

## LP64 vs ILP64 — two ways to be 64-bit

There are two ways to make Dis 64-bit. Inferno64 went with **ILP64**; the earlier
**LP64** approach still works and lives on a branch (`ilp64` was where ILP64 was
developed, pushed as `Dinsmoor/Inferno64`). The difference is one question: *how
wide is a Limbo `int`?*

| | **ILP64** (Inferno64) | **LP64** (older, on a branch) |
|---|---|---|
| Limbo `int` | **64-bit** (`IBY2WD=8`) | 32-bit (`IBY2WD=4`) |
| pointer / register slot | 64-bit (`IBY2PTR=8`) | 64-bit (`IBY2PTR=8`) |
| core invariant | `int == big == WORD == PTR == 8` | `WORD != PTR` (4 vs 8) |
| `.dis` word | 8 bytes | 4 bytes |

ILP64 collapses everything to a single 8-byte width, which is simpler internally
and is why it's the trunk — but in doing so it **redefines `int` to be 64-bit**.
LP64 keeps the classic Limbo semantics (an `int` is still 32 bits) but pays for it
by having to keep word-width and pointer-width separate *everywhere* in the
compiler and VM — and that split is what made the heap-corruption bugs so hard to
chase.

### Pros and cons

**ILP64 (what Inferno64 uses)**

- ➕ Deletes the `WORD != PTR` hazard class outright — one width means no
  truncation-on-store bugs and no `tint`/`tptr` bookkeeping. This is the main
  reason for the switch: it removes the pointer-truncation that drove the LP64
  heap corruption.
- ➕ Matches caerwynj/inferno64, the de-facto upstream 64-bit Inferno, so there's
  a reference answer-key; `big` becomes a no-op alias of `int`.
- ➕ Validated: the regression suite is 178/178 under both the interpreter (`-c0`)
  and the AArch64 JIT (`-c1`), the GUI comes up under both, and an amd64 JIT
  backend is staged.
- ➖ `int` is no longer 32-bit, which **changes the language**. Every 32-bit
  boundary needs sign-extension care (Styx wire fields, `print` verbs, `.dis`
  constants). Most are fixed, but the 32-bit *constant masking* (`h & ~(1<<31)`
  idioms used in ~48 files) is deliberately left 32-bit — a standing semantic
  seam.
- ➖ C↔Limbo bitcasts all break: Limbo `int`(8) ≠ C `int`(4), so `Draw_Rect`(32B)
  ≠ C `Rectangle`(16B). Fixed with field-wise converters, but every future
  C/Limbo struct share must *convert*, never cast.
- ➖ 2× memory for all int data, and it gives up the true dual-ABI build.

**LP64 (older, still on a branch)**

- ➕ `int` keeps its documented 32-bit meaning — overflow/wraparound, `1<<31`
  hash idioms, `~0` sentinels (`NOFID`), and 32-bit wire fields all behave the
  way the existing Limbo code expects, no per-boundary auditing.
- ➕ C↔Limbo structs are bit-identical: Limbo `int`(4) == C `int`(4), so
  `Draw_Point`/`Draw_Rect` map straight onto C `Point`/`Rectangle` and you can
  reinterpret-cast across the boundary.
- ➕ Smaller footprint (every `int` stays 4 bytes), and one source tree can still
  target a 32-bit Dis.
- ➖ The `WORD != PTR` hazard class is permanent: any compiler/VM slot that holds
  an address must be pointer-width (the `tint`-vs-`tptr` discipline), and one
  missed site is a silent pointer truncation — exactly the heap-corruption bugs
  (e.g. closing a loaded Charon window) that were too annoying to debug.
- ➖ Diverges from caerwynj/inferno64, so there's no reference implementation to
  diff against.

It works, it's just not where active development is — the rest of this section is
mostly about ILP64.

### What this means if you're hacking on it

**Writing Limbo (ILP64):** `int` is 64-bit, so `big` and `int` are the same
thing. Code that assumed a 32-bit `int` (hash functions that mask to 32 bits,
anything packing an `int` into a 4-byte wire/file field) needs to sign-extend or
mask explicitly at that boundary. Integer constants are still treated as
32-bit-wide, so `~0` and `1<<31` idioms keep working — but a value that *relies*
on 32-bit overflow will not wrap. (On the LP64 branch `int` is 32-bit and `big` is
64-bit, exactly like upstream Limbo, so those old idioms behave as written.)

**Writing C — builtins, devices, the VM (ILP64):** the rule is *never bitcast a C
struct onto a Limbo struct* — a C `int` is still 4 bytes while a Limbo `int` is now
8, so `Point`/`Rectangle`-style structs have different layouts and sizes. Convert
field-by-field (see the `IRECT`/`DRECT` helpers and `limbopoints()`), and
sign-extend any 32-bit value you read off the wire or out of a `.dis` into a 64-bit
Dis word. (On the LP64 branch it was the opposite discipline: a Dis word is 4
bytes, a pointer is 8, and any temp/slot/operand carrying an address had to be
pointer-width — the `tptr` type, never `int` — or it truncated a pointer and
corrupted the heap; C structs could be cast directly because the int widths
matched.)

The full story (every fix, the bug classes, and the reasoning) is in
[`LP64_NOTES.md`](LP64_NOTES.md) and [`ref/AGENTS_DUALABI.md`](ref/AGENTS_DUALABI.md).

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
