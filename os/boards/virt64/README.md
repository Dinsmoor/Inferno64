# virt64 — native aarch64 Inferno for qemu -M virt

The first bare-metal aarch64 port of the Inferno kernel (`os/` tree,
not hosted emu). Boots under `qemu-system-aarch64 -M virt` to an
interactive Inferno shell on the PL011 serial console.

This file documents both the virt64 board and the shared aarch64
build it rides on.

## Layout: arch core, drivers, boards

The build is factored for multiple boards:

- `os/aarch64/` — the arch core every aarch64 board shares: entry +
  vectors + MMU skeleton (l.S), traps (trap.c), generic timer
  (clock.c), main.c, and the Makefile with the big lib lists (Dis,
  draw/Tk, libsec/mp, mbedTLS, os/ip). l.S handles the EL2→EL1 drop
  and builds the identity map from the board's `L1MAPENT0..3`.
- `os/drivers/` — board-agnostic drivers, one file each: uart-pl011,
  gic-v2, the virtio-mmio transport + rng/input/net/blk drivers,
  ramfb, screen (memory-Memimage framebuffer), devether.
- `os/boards/virt64/` (this directory) — what makes a board: `board.h`
  (addresses, IRQ ids, RAM base/size, MMU map, PSCI conduit), `board.c`
  (the `boardinit`/`boardready`/`rtctime` hooks), `board.mk` (which
  drivers to link, how to `make run`), `kernel.ld` (load address), and
  the kernel config `virt64` (devices, builtin modules, root
  structure).

The interrupt controller is behind a four-call seam (`intcinit`,
`intcenable`, `intcdisable`, `intcdispatch` — see fns.h), so a GICv3
board adds a driver, not a trap.c fork.

To add a board (e.g. bpi-r4): `mkdir os/boards/bpi-r4`, write the five
files above (start by copying this board's), drop new drivers in
`os/drivers/`, list them in its board.mk, and `make HWTARG=bpi-r4`.
Nothing in os/aarch64 or os/drivers should need a board #ifdef; if it
does, the fact belongs in board.h or behind a hook.

## Building the image

```sh
cd os/aarch64
make                 # → ivirt64.elf (this IS the image: one self-contained ELF)
make run             # qemu -M virt -cpu cortex-a53 -m 512 -kernel ivirt64.elf -nographic
make HWTARG=virt64   # explicit board select (virt64 is the default)
make USERSPACE=headless  # smaller baked root: no fonts/icons/man (36MB → 20MB)
make PARANOID=0      # faster kernel: skip the pool free-tree audit on every alloc/free
make clean           # removes every board's build-*/ and i*.elf
```

There is no disk or initrd: the kernel ELF embeds its entire root
filesystem (devroot), so `-kernel ivirt64.elf` is the whole boot story.
Generated files (the conf C, the baked root, errstr.h, version.h) land
in `build-$(HWTARG)/`, so boards build side by side.

### Prerequisites

- an aarch64 host with gcc + binutils (the kernel is built natively with
  the host toolchain as a freestanding cross-dialect compile — no
  mk/kencc: `-fplan9-extensions -std=gnu2x -fcommon -mstrict-align
  -ffreestanding -fno-builtin`; GNU as for l.S; per-board linker script
  `kernel.ld`, virt64 links at 0x40200000)
- `qemu-system-aarch64` to run it
- a **hosted** Inferno build somewhere, for two things the Makefile
  pulls in: the `limbo` compiler binary and the prebuilt `.dis` files
  baked into the root. The Makefile looks for `$(ROOT)/Linux/aarch64/
  bin/limbo` (i.e. `make all` was run at this repo's root) and falls
  back to the main shared tree at `/home/tyler/inferno-os`; override
  with `make HOSTBIN=/path/to/Linux/aarch64/bin`.

### How the image is assembled

The config file `virt64` (same format as the classic os ports) lists
the devices, builtin modules and the *structure* of the root; the
Makefile generates `build-virt64/virt64.gen` from it by appending every
file under the USERSPACE profile's trees (`full` = `dis/ fonts/ icons/
lib/ module/ man/ locale/` — the whole hosted-build application set,
~5800 files / ~40MB; `headless` drops fonts/icons/man). Two awk
generators from `os/port/` then consume `virt64.gen` (run from inside
the build dir):

- `mkdevc virt64.gen > conf.c` — turns the `dev`/`mod`/`code`/`init`
  sections into the device table, conf strings and `virtinit()` glue.
- `mkroot virt64.gen` — walks the `root` section and bakes every path
  into `virt64.gen.root.{h,s}`; directories become empty mountpoints,
  files are embedded byte-for-byte (by `.incbin` reference — see
  `data2s`; as `.byte` text the root would be ~6x its size and minutes
  of assembly). This is the root filesystem the kernel serves through
  devroot.

`../init/virtinit.b` is the init module (compiled with the hosted
`limbo` at build time); it sets up the namespace and execs
`/dis/sh.dis` on the console. `errstr.h` and `version.h` are generated
too — all of these are `make clean`-ed and rebuilt, never edited.

### The dis/ prebuilts (gotcha)

Everything under the repo-root `dis/` tree is **gitignored** build
output of the hosted build. A fresh clone has no `dis/sh.dis` to bake,
and this Makefile does not build them. Populate them by running the
hosted build (`make all` at the repo root, see docs/ON_BUILDING.md) —
or `rsync -a --exclude='*.sbl'` the `dis/` tree from another built
checkout. Whatever is under the ROOTTREES is what gets baked.

### Adding a file to the baked-in root

Drop it under one of the ROOTTREES (`dis/ fonts/ icons/ lib/ module/
man/ locale/`) at the path you want inside Inferno and `make` — the
generated root list picks it up, and a recompiled `.dis` is re-baked
automatically (the root rule depends on every baked file). Only a
file *outside* those trees needs a line in the `root` section of the
`virt64` config. Growing the image is fine; it all lives in the
512MB of guest RAM.

### Build knobs

`PARANOID` (default 1) sets `poolparanoid` in port/alloc.c (free-tree
audit on every alloc/free); the Makefile stamps the value so flipping
it recompiles alloc.c without a `make clean`. `HOSTBIN` as above.

With the full application root the audit is *felt*: every alloc/free
walks the whole free tree, so allocation-heavy work (rayteapot's .obj
parse, charon) crawls — minutes instead of seconds.  Keep PARANOID=1
while hunting memory bugs; build `make PARANOID=0` for an image meant
for interactive use.

### Running it

- Headless console in the terminal: `make run` (C-a x quits).
- As a window on an X display: see "Graphical session" below for the
  full recipe (ramfb + virtio input devices).
- Scripted/CI: `-display none -serial tcp:127.0.0.1:PORT,server=on,wait=on`
  and drive the console over the socket (use `wait=on`: the kernel
  boots faster than a client can connect, so `wait=off` loses the
  banner). See "Debugging" below for the gdb stub.

## Graphical session

With a display the kernel boots straight into a wm desktop (toolbar
with start menu, Tk shell windows, working mouse + keyboard):

```sh
DISPLAY=:3 qemu-system-aarch64 -M virt -cpu cortex-a53 -m 512 \
    -kernel ivirt64.elf \
    -global virtio-mmio.force-legacy=false \
    -device virtio-rng-device -device ramfb \
    -device virtio-keyboard-device -device virtio-tablet-device \
    -display gtk -serial vc -monitor none
```

The pieces, all in this directory:

- **ramfb.c** — display: qemu's fw_cfg-configured scanout of guest RAM
  (everything fw_cfg is big-endian, including directory entries).
- **screen.c** — gscreen Memimage over the 1024x768 XRGB32 framebuffer;
  kernel console text renders into it; devdraw attaches to it.
- **virtio.c / vinput.c** — modern (v2) virtio-mmio transport +
  virtio-keyboard/tablet drivers; the tablet's absolute coordinates
  mean no pointer grab.  `-global virtio-mmio.force-legacy=false` is
  required (input devices are modern-only, and the flag flips every
  transport, so rng speaks modern too).
- Kernel links libmemdraw/libmemlayer (devdraw's rasterizer), full
  libdraw + libtk + the Draw/Tk/Loader builtin modules (clients of
  devdraw via the lib* shims in port/discall.c, same architecture as
  emu).
- The root bakes the whole application set (see "How the image is
  assembled"), so /lib/wmsetup runs at toolbar start: plumber, the
  wm/warmup background-JIT splash, and the full start menu
  (Shell/Acme/Edit/Charon/Manual/Files + Games/Misc/System) all work.
- virtinit binds #i/#m/#s, mounts a heap-backed `memfs` over /tmp and
  /usr/inferno (devroot is read-only; acme et al. need writable temp
  and $home space — this is also why devmnt is in the config), and
  spawns `wm/wm` under its own sh; the serial console sh starts a few
  seconds later (see below).

Two hard-won lessons baked into the code:

- **quotefmtinstall() is load-bearing.**  Without it %q prints
  literally and swallows its argument — and the whole wm<->client
  window protocol is %q-formatted strings, so windows are requested
  with garbage rects and silently never appear, while Tk reports
  success.  (Diagnosed by tracing wm's request channel.)
- **The console and the GUI share kbdq.**  devcons used to sleep
  holding the kbd qlock (GUI startup hung until a serial byte arrived)
  and a console reader could steal interleaved bytes of GUI typing;
  both fixed in port/devcons.c, and init orders the readers so wm's
  keyboard client is the senior sleeper.

The serial console remains on the qemu `vc` tab; while a GUI owns
/dev/keyboard the console sh parks (it resumes if the keyboard is
closed).

## Networking

The kernel links the native Plan 9-derived TCP/IP stack (`os/ip`: tcp,
udp, icmp, icmp6, ipifc + ether/loopback media) behind `#I` (devip),
with `#l` (devether, simplified from os/pc — no ISA/PCI probing) over a
virtio-net driver (ethervirtio.c) on the modern virtio-mmio transport.
The transport negotiates the device-class feature word for the driver
(`virtiodevinit(d, accept0)`; ethervirtio accepts F_MAC and reads the
MAC out of config space).

`make run` attaches qemu user-mode networking (slirp): the guest is
10.0.2.15/24, the host is reachable as the gateway 10.0.2.2, DNS at
10.0.2.3. There is no DHCP client wired up; configure statically from
the shell:

	bind -a '#l' /net
	bind -a '#I' /net
	echo bind ether /net/ether0 > /net/ipifc/clone
	echo add 10.0.2.15 255.255.255.0 > /net/ipifc/0/ctl
	echo add 0 0 10.0.2.2 > /net/iproute

then e.g. `ip/ping -n 3 10.0.2.2`, or fetch a page from an HTTP server
on the host: `webgrab -o /tmp/x http://10.0.2.2:8000/` (slirp answers
guest connections to 10.0.2.2 from the host loopback). `netstat` reads
the conversation directories.

Skipped on purpose: bootp/dhcp (static or userspace config), il, gre,
esp, igmp, ipmux, ppp.

### Name resolution

Works out of the box once the interface is up — no ndb edits needed.
The stock /lib/ndb/local (baked into the image) already lists public
resolvers (8.8.8.8, 1.1.1.1) under `infernosite=`, and slirp NATs
outbound UDP, so:

	ndb/cs &
	ndb/dns &
	ndb/dnsquery example.com         # real A records
	webgrab -o /tmp/x http://example.com/

ndb/cs serves /net/cs via devsrv (`#s`, file2chan) and the kernel's
dial() consults it, so every dialer — webgrab, charon, mount —
resolves hostnames from then on.  (ndb/dns answers /net/dns and speaks
UDP to the resolvers itself.)

### Import/export (Styx over TCP)

The namespace travels both ways, same as hosted Inferno.  Export the
bare-metal kernel's namespace:

	styxlisten -A 'tcp!*!6666' export /

and any Styx client can mount it; with `make run`'s slirp the host
reaches the guest through a forward (`hostfwd=tcp:127.0.0.1:9996-:6666`
on the -netdev), e.g. from a hosted emu on the host:

	mount -A 'tcp!127.0.0.1!9996' /n/remote

— verified: the host emu reads the guest's memfs /tmp and the guest's
/net (the kernel IP stack, served over that same IP stack).  The other
direction works too: serve from a hosted emu (`styxlisten -A
'tcp!*!9997' export /`) and on the guest

	mount -A 'tcp!10.0.2.2!9997' /n/remote

Mountpoints under /n (`/n/remote`, `/n/local`, …) are part of the baked
root — devroot is read-only, so a mountpoint that isn't in the config's
root section doesn't exist.  Add new ones there (and to the Makefile's
mkdir line).  `-A` on both ends skips Inferno authentication; wire up
keys/getauthinfo if you want it.

## Persistent storage

`#S` is the portable devsd (os/port/devsd.c) over sdvirtio.c, a
virtio-blk driver on the same modern virtio-mmio transport (three-
descriptor request chains, one in flight per disk, interrupt
completion).  Give qemu a raw image:

	truncate -s 64M disk.img
	make run DISK=disk.img

and in the guest the disk is /dev/sd00 (ctl/data/raw) after
`bind -a '#S' /dev`.  Filesystems are userspace Styx servers, as
everywhere in Inferno — kfs(4) turns the disk into a real writable
Inferno fs:

	bind -a '#S' /dev
	mount -c {disk/kfs -r /dev/sd00/data} /n/kfs   # first time: ream
	mount -c {disk/kfs /dev/sd00/data} /n/kfs      # thereafter

Verified: a file written under /n/kfs survives a full qemu restart.
devsd partitions (`part name start end` into /dev/sd00/ctl) work as in
Plan 9 if you want more than the whole-disk `data` partition; the raw
SCSI interface returns I/O errors by design (virtio-blk speaks no
SCSI).

## TLS

`#T` is os/port/devtls.c — the emu devtls (mbedTLS-backed TLS 1.2/1.3,
same ctl protocol, used by `Dial->pushtls`/`dialtls` and so by webgrab
and charon) adapted for the kernel: the CA bundle is read through the
kernel's own file I/O and parsed in memory, because the kernel's
mbedTLS build is freestanding.

That build compiles the vendored libmbedtls sources against
`mbedtls-kconfig.h` (the default config minus files, sockets, clock
syscalls and /dev/urandom) plus `tlsshim.c`: snprintf onto the Plan 9
fmt engine, time() from the PL031-backed seconds(), a real gmtime_r so
x509 validity dates are actually checked, inet_pton for IP-literal
hostnames, and entropy from virtio-rng
(MBEDTLS_ENTROPY_HARDWARE_ALT).

The Mozilla CA bundle is baked at /lib/tls/ca-certificates.crt
(lib/tls in the repo), which is the kernel devtls default, so
certificate verification is ON and works out of the box.  Verified
under qemu both ways: a server signed by an unknown CA is refused
("X509 - Certificate verification failed"), and after binding that CA
over /lib/tls/ca-certificates.crt the same `webgrab
https://10.0.2.2:8443/` fetch succeeds against a TLS 1.3 server on the
host loopback.

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
- Entropy: rng.c is a polled virtio entropy driver on the modern
  virtio-mmio transport (virtio.c) — boot with `-device
  virtio-rng-device` (make run does; qemu fills slots from the last
  one down, hence the probe scans all 32).
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
