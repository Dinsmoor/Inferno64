# Inferno64 — Inferno with a 64-bit (LP64) Dis ABI

**IMPORTANT:** THIS PORT IS NOT PROVED TO BE BUG FREE. This will boot into
the emu on aarch64 and you can do *most* desktop GUI work, but certain things
may still be broken. Feel free to try it, and if you do run into a crash or
emu or wm freezes, then report it in a reproducable way and I'll see if I can
fix it.

Most of the remaining LP64 related bugs have to do with heap corruption, which
are pretty hard to narrow down. To best catch them:

<details>
<summary><strong>How to set up an emu session that reliably captures a core dump + logs</strong></summary>

The goal of the setup below is that the *very first* time something faults you
get a clean core dump + log, instead of having to reproduce an intermittent
crash after the fact.

**1. Tell the host kernel where to drop cores (once per boot):**

```sh
sudo mkdir -p /tmp/inferno-cores
echo '/tmp/inferno-cores/core.%e.%p.%t' | sudo tee /proc/sys/kernel/core_pattern
```

(`%e` program, `%p` pid, `%t` timestamp. The directory must exist and be
writable. To make it survive reboots put `kernel.core_pattern=...` in
`/etc/sysctl.d/`.)

**2. Raise the core-size limit in the shell you launch emu from:**

```sh
ulimit -c unlimited
```

**3. Leave ASLR on.** Several of these bugs only surface at high addresses, so
do **not** run emu under `setarch -R` (ASLR-off). Run emu normally so the host
randomizes the address space — that is what provokes the fault.

**4. Launch emu with the crash/observability env vars:**

```sh
ulimit -c unlimited
env EMUCRASH=1 EMUWATCHDOG=60 \
    ./Linux/aarch64/bin/emu -r"$PWD" -g1280x800 wm/wm
```

  - `EMUCRASH=1` — a wild/illegal Dis fault aborts the process immediately
    (dumping a core) instead of being swallowed into a Dis exception that can
    silently wedge the VM. **This is the important one** — without it an
    intermittent heap-corruption fault often just leaves a zombie/hung emu and
    the evidence is gone.
  - `EMUWATCHDOG=60` — if the VM hangs for 60s (e.g. a deadlock rather than a
    hard fault) the watchdog prints a dump of every Dis thread so you can see
    who is stuck and where.
  - You can also `kill -USR2 <emu-pid>` at any time to force the same Dis
    thread dump from a live (or apparently-hung) emu.

**5. When you get a core, hand it straight to gdb:**

```sh
gdb ./Linux/aarch64/bin/emu /tmp/inferno-cores/core.emu.<pid>.<ts>
(gdb) bt              # host C backtrace at the fault
(gdb) info registers  # the faulting address is usually a smashed pointer
```

The fault message emu prints on the way down names the Dis module, the builtin
(e.g. `Charon[$Sys]`), and a `pc=`; map that `pc` back to a Limbo source line
with the module's `.sbl` file (`limbo -g` output) to find the exact line that
faulted. See `ref/AGENTS_DEBUGGING.md` for the full workflow.

</details>

**Inferno64** is a fork of [Inferno](https://github.com/inferno-os/inferno-os)
whose Dis virtual machine, Limbo compiler, and hosted emulator build for a
**64-bit (LP64) pointer model** in addition to the original 32-bit one. Upstream
Inferno assumes a 32-bit Dis pointer/register slot, so on a 64-bit host the
emulator could only run with a 32-bit toolchain (or `-m32`); this fork makes the
Dis ABI itself 64-bit-clean, including an **AArch64 (ARM64) JIT**.

## Building

From a clean checkout or a fresh `git worktree`, the only command you need is:

```sh
make all                 # Linux/aarch64 host (the default)
make OBJTYPE=amd64 all    # x86-64 host instead
```

`make all` is the only coherent build: it builds the C side first (host
libraries, the `limbo` compiler, the `emu` binary), then compiles the whole
Limbo tree under `appl/` to `.dis`. It needs no pre-existing toolchain — it
bootstraps `mk` with the host `gcc` automatically. A full nuke+rebuild is cheap
(~1 min) and is the safe default; the half-builds `make emu` / `make dis` are
gated behind `FORCE=1` because a stale `.dis` against a freshly built ABI is a
real, debugged crash class.

See [`INSTALL`](INSTALL) for prerequisites, the amd64 notes, and the full details.

## Running

Launch the hosted emulator straight out of the build tree. `-r"$PWD"` makes the
repo root the Inferno root, and the final argument is the first Dis program to
run:

```sh
# graphical desktop (needs an X display; pick a window size)
./Linux/aarch64/bin/emu -r"$PWD" -g1280x800 wm/wm

# just a shell, no GUI
./Linux/aarch64/bin/emu -r"$PWD" /dis/sh.dis
```

To run Dis through the **AArch64 JIT** (native code compiler) instead of the
interpreter, add `-c1`:

```sh
./Linux/aarch64/bin/emu -c1 -r"$PWD" -g1280x800 wm/wm
```

`-c` takes a numeric level (`-c1`…`-c9`); any non-zero value turns the compiler
on, `-c0` (the default) is the pure interpreter. `emu -v` prints `compile` vs
`interp` so you can confirm which is active. Leave the `-B` flag (which disables
the JIT's array-bounds checks) **off** while chasing the heap bugs.

On an x86-64 host the binary lives at `./Linux/amd64/bin/emu` instead. For a
headless box, run emu under a virtual framebuffer (e.g. `Xvfb :3` + a VNC server)
and point `DISPLAY` at it before launching `wm/wm`.

When you are chasing one of the heap-corruption bugs, launch emu with the
crash/observability env vars instead — see the collapsible section at the top of
this file.

## Are you going to try to push your changes to the upstream repository?

No, I am doing my own thing, but if they want to talk to me then that's fine.

## Goals for Inferno64

1. Make Inferno run natively (Dis/hosted emu) on a LP64 ABI
2. Implement JIT compilers for some major LP64 archetectures
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
Considering this OS is hell themed, I figure it is fitting thatan evil machine
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
I can simultaniously view and interact with the desktop over VNC. It makes "hey
charon's navigation buttons aren't working, look" super simple, and makes it easier
to catch when the demon machine is getting something wrong.

For the debugging and actually catching and dumping cores, we have to run emu with
some build options and just make sure the demon machine knows about them, and it
can use a gdb-mcp server (written by this dude: https://github.com/Ipiano/gdb-mcp 
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
