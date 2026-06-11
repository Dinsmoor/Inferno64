# os/virt64 — native aarch64 Inferno for qemu -M virt

The first bare-metal aarch64 port of the Inferno kernel (`os/` tree,
not hosted emu). Boots under `qemu-system-aarch64 -M virt` to an
interactive Inferno shell on the PL011 serial console.

## Building the image

```sh
cd os/virt64
make            # → ivirt64.elf (this IS the image: one self-contained ELF)
make run        # qemu-system-aarch64 -M virt -cpu cortex-a53 -m 256 -kernel ivirt64.elf -nographic
make PARANOID=0 # faster kernel: skip the pool free-tree audit on every alloc/free
make clean      # also removes the generated virt64.c / *.root.* / errstr.h / version.h
```

There is no disk or initrd: the kernel ELF embeds its entire root
filesystem (devroot), so `-kernel ivirt64.elf` is the whole boot story.

### Prerequisites

- an aarch64 host with gcc + binutils (the kernel is built natively with
  the host toolchain as a freestanding cross-dialect compile — no
  mk/kencc: `-fplan9-extensions -std=gnu2x -fcommon -mstrict-align
  -ffreestanding -fno-builtin`; GNU as for l.S; custom linker script
  `virt64.ld`, link address 0x40200000)
- `qemu-system-aarch64` to run it
- a **hosted** Inferno build somewhere, for two things the Makefile
  pulls in: the `limbo` compiler binary and the prebuilt `.dis` files
  baked into the root. The Makefile looks for `$(ROOT)/Linux/aarch64/
  bin/limbo` (i.e. `make all` was run at this repo's root) and falls
  back to the main shared tree at `/home/tyler/inferno-os`; override
  with `make HOSTBIN=/path/to/Linux/aarch64/bin`.

### How the image is assembled

The config file `virt64` (same format as the classic os ports) drives
two awk generators from `os/port/`:

- `mkdevc virt64 > virt64.c` — turns the `dev`/`link`/`code`/`init`
  sections into the device table, conf strings and `virtinit()` glue.
- `mkroot virt64 > virt64.root.{h,s}` — walks the `root` section and
  bakes every listed path into assembly via `data2s`; directories
  become empty mountpoints, files are embedded byte-for-byte. This is
  the root filesystem the kernel serves through devroot.

`../init/virtinit.b` is the init module (compiled with the hosted
`limbo` at build time); it sets up the namespace and execs
`/dis/sh.dis` on the console. `errstr.h` and `version.h` are generated
too — all of these are `make clean`-ed and rebuilt, never edited.

### The dis/ prebuilts (gotcha)

Everything under the repo-root `dis/` tree is **gitignored** build
output of the hosted build. A fresh clone has no `dis/sh.dis` to bake,
and this Makefile does not build them. Populate them by running the
hosted build (`make all` at the repo root, see docs/ON_BUILDING.md) —
or copy the handful of needed files from another built tree. The
`root` section of `virt64` is the authoritative list of what must
exist.

### Adding a file to the baked-in root

1. Make sure the file exists under the repo root at the path you want
   it to have inside Inferno (e.g. a new tool: build it hosted so
   `dis/foo.dis` exists).
2. Add that path to the `root` section of the `virt64` config file.
3. `make` — mkroot regenerates `virt64.root.s` and the file appears in
   the booted system. Growing the image is fine; it all lives in the
   256MB of guest RAM.

### Build knobs

`PARANOID` (default 1) sets `poolparanoid` in port/alloc.c (free-tree
audit on every alloc/free); the Makefile stamps the value so flipping
it recompiles alloc.c without a `make clean`. `HOSTBIN` as above.

### Running it

- Headless console in the terminal: `make run` (C-a x quits).
- As a window on an X display (e.g. the shared VNC display):
  `DISPLAY=:3 qemu-system-aarch64 -M virt -cpu cortex-a53 -m 256
  -kernel ivirt64.elf -device virtio-rng-device -display gtk -serial vc
  -monitor none`.
- Scripted/CI: `-display none -serial tcp:127.0.0.1:PORT,server=on,wait=on`
  and drive the console over the socket (use `wait=on`: the kernel
  boots faster than a client can connect, so `wait=off` loses the
  banner). See "Debugging" below for the gdb stub.

## Hardware (qemu -M virt)

| device | where |
|---|---|
| PL011 UART | 0x09000000, GIC intid 33 |
| GICv2 | dist 0x08000000, cpu 0x08010000 |
| generic timer | CNTP (physical), PPI intid 30 |
| RAM | 0x40000000, kernel loaded at +0x200000 |
| virtio-mmio | 32 transports at 0x0a000000 + N*0x200, intids 48+N |

## Current scope / deliberate simplifications

- MMU and caches ON: TTBR0-only identity map, two 1GB block entries
  (device + RAM) built in l.S before the boot stack; T0SZ=32, MAIR
  idx0=WB-normal/idx1=device-nGnRnE (recipe adapted from 9front
  sys/src/9/arm64 l.s/mem.c).
- Dis JIT ON (`cflag 1`): one 4MB xalloc-backed code arena, single-arena
  mode (`jitsinglearena` in libinterp/comp-aarch64.c — a second arena
  would break the `[jitlo,jithi)` native-PC dispatch test in xec.c, so
  overflow falls back to the interpreter). `segflush()` in main.c does
  the dc cvau/ic ivau dance.
- Single CPU (see "SMP" below).
- Entropy: rng.c is a polled legacy virtio-mmio driver for the qemu
  entropy device — boot with `-device virtio-rng-device` (make run does;
  qemu puts it in the last free slot, hence the probe scans all 32).
  Without the device, genrandom() falls back to a seeded xorshift
  (NOT crypto-grade).
- `poolparanoidcheck()` in port/alloc.c audits the allocator free tree
  on every alloc/free; `make PARANOID=0` turns it off (development
  default is on).

## SMP: investigated, deliberately not done

PSCI is present and verified working: qemu -M virt (no EL3) emulates
PSCI 1.1 firmware with the **hvc conduit**, so plain EL1 `hvc #0`
reaches it (`psci_call` in l.S). The boot banner probes `PSCI_VERSION`,
`archreboot()` uses `SYSTEM_RESET` (a `reboot` write to /dev/sysctl
really reboots now) and `halt()` uses `SYSTEM_OFF`. Secondary CPUs
would start via `CPU_ON` (0xC4000003, mpidr, entry-pa, ctxid), arriving
at EL1, MMU off — same recipe 9front sys/src/9/arm64 uses.

So bring-up is the easy part. The kernel stays UP because the payoff
is near zero and the plumbing is not:

- **The workload can't use it.** Every Limbo prog is multiplexed by the
  Dis scheduler (`isched`/`vmachine()` in port/dis.c) inside one kernel
  proc, and libinterp's heap/GC have no cross-CPU locking. A second CPU
  could only run device kprocs, and this kernel's devices are a UART
  and an entropy device.
- **`m` and `up` are single globals** (dat.h; `MACHP(n)` only knows
  CPU0). MP needs per-CPU Mach/Proc — tpidr_el1 (or a reserved x18)
  plus `m`/`up` as accessor macros — mechanical, but it touches
  everything that includes dat.h, i.e. all of port/ and libinterp/.
- **No IPIs or interrupt routing.** GICv2 needs per-CPU GICC init,
  SGIs for cross-CPU preemption, and ITARGETSR routing; intrenable()
  has no concept of a target CPU.
- **Lock discipline needs an MP audit.** `_tas` is ldxr/stxr with an
  acquire-side dmb, but the release side and ilock's cross-CPU
  semantics were only ever exercised UP here. (The hosted emu had
  exactly this bug on aarch64 — unlock without a release barrier
  corrupting the pool free tree — so treat it as expected, not
  hypothetical.) The port scheduler itself is closer to ready: the
  locked global runq + `canlock` in runproc() are inherited from
  Plan 9's MP design.

If Dis ever gets an MP execution model, start with per-CPU m/up and
the lock audit; CPU_ON is the trivial last step.

## gcc-vs-kencc porting rules learned here

- gcc has callee-saved registers; `Label` holds x19-x29 + d8-d15 and
  `setlabel` is `__attribute__((returns_twice))`.
- IRQs are not call boundaries: trap stubs save/restore the FULL FP
  context (q0-q31 + fpcr/fpsr), because gcc emits SIMD in memmove etc.
- `FPsave/FPrestore` (Dis timeslice switch) save ONLY FPenv
  {fpsr,fpcr}: q regs are caller-saved at the `r->xec(r)` boundary and
  the trap stubs cover interrupts. Saving the full register file into
  the 16-byte `Osenv.fpu` was a ~500-byte heap scribble per timeslice
  (free-tree parent corruption, found with a gdb hardware watchpoint).
- LP64 pool quantum must be 63 (`QUANTA` in port/alloc.c): a free-tree
  node needs 64 bytes; the 32-bit-era 31 made pooladd scribble past
  32-byte split fragments.

## Debugging

Deterministic boot makes gdb scripts replayable:

```sh
qemu-system-aarch64 -M virt ... -display none \
    -serial tcp:127.0.0.1:PORT,server=on,wait=off -gdb tcp::PORT -S &
gdb -batch -x script.gdb     # conditional breaks, ignore counts, hw watchpoints
```

Hardware watchpoints on a corrupted address catch the scribbler
red-handed. Kill stray instances with `killall -q qemu-system-aarch64`
(a `pkill -f` pattern matching the qemu cmdline also matches your own
shell wrapper and kills it).
