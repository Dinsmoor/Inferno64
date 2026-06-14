# Porting hardware drivers into the native kernel — the os/drivers playbook

This is the file-by-file procedure for bringing a hardware driver into the
native aarch64 kernel's `os/drivers/` pool, the recurring rules that govern
the port, and the worked NIC examples. It is the detail behind
**ON_PORTING.md Part III** (read that for *where drivers sit* among the four
kinds of port, the bus/seam taxonomy, and the board picture). For the kernel
internals a driver plugs into see **ON_KERNEL.md**; for the GICv3/MSI substrate
see the `os/drivers/gic-v3.c` and `pci.c` sources.

The native kernel and 9front are both Plan 9 kernels, so a driver is an
**adaptation, not a rewrite**: the seams are the same structs and registration
calls in both trees. 9front — not U-Boot or Linux — is the first source for any
driver it already carries, and **the matching 64-bit tree** (`pc64`, `arm64`,
`bcm64`, `imx8`, `lx2k`) is the one to copy from; the 32-bit trees carry the
width assumptions this fork exists to remove.

---

## The economics: first driver to need an API pays for it

Porting splits into two tiers, and which tier a driver lands in is predictable
before a line is written:

- **Inferno-era / simple drivers** adapt over the seam with **zero kernel
  changes** (e.g. `ether-igbe`, `ether-rtl8139`).
- **Modern 9front drivers** need kernel support the native tree doesn't have
  yet — but once that support lands for the *first* driver to need it, every
  later driver that needs the same thing rides free.

The boundary is therefore "first driver to need API X pays for X." The Intel
`ether-82563` (e1000e) port paid for the `Bpool` buffer-pool API, the
`MiiPhy*` clause-45 `ethermii`, and the devether type/instance split; once
those landed, `ether-rtl8169`, `ether-x550` and `ether-i225` reused them with
no new kernel work. **Review the candidate's 9front git history first** (below):
the kernel-touching commits in its history are exactly the support it will
demand here, so the review predicts the port's friction.

When a modern driver does need a kernel change, **port 9front's change
faithfully** rather than diverging the driver. The two kernels are the same
Plan 9 code, and 9front's changes were made for good reason; a faithful port
keeps every later driver in that family cheap.

---

## What the seam already gives you

### PCI (`pci.h` / `pci.c`)

`pci.c` enumerates the PCIe bus once at boot through a generic ECAM host bridge
(qemu `-M virt` GPEX, and the same MMIO config layout on real arm64 SoCs) and
exposes the canonical Plan 9 `Pcidev`/`pcimatch` API. A driver's `reset()`/
`pnp()`:

- walks the bus with `pcimatch(p, vid, did)` (`0` == wildcard);
- reads its BARs from `p->mem[i].bar` — **already a CPU address**, assigned by
  `pci.c`. A memory BAR is the identity-mapped MMIO window address with the low
  type bits preserved (`bar & 1` still distinguishes I/O from memory; mask with
  `& ~0xf` for the base). **There is no `vmap()`** — the 9front `vmap(bar,size)`
  call becomes `(void*)(uintptr)(bar & ~0xf)` directly;
- reads its interrupt from `p->intl` — **already a GIC SPI** (the `pci.c` INTx
  swizzle has run);
- calls `pcisetbme(p)` to become a bus master (this is what 9front's
  `pcienable()` maps to — there is no clock/power gating here; `pciclrbme()`
  is the inverse).

`pcicfgr{8,16,32}` / `pcicfgw{8,16,32}` read and write config space.
`mem[6]` each carry `{uvlong bar; int size;}`. The class triple is
`p->ccrb`/`p->ccru`/`p->ccrp`; the BDF macros (`BUSFNO` etc.) and
`PciSVID`/`PciSID`/`PciCapMSIX` constants live in `pci.h`.

### Interrupts: INTx is automatic, MSI-X is one call

- **INTx** arrives as a GIC SPI on `p->intl`. For an **ethernet** driver,
  devether wires the handler from `edev->irq` + `edev->interrupt` — the driver
  sets those two fields and **must not call `intrenable()` itself** (doing both
  double-registers the vector). A non-ether driver (storage) calls
  `intrenable(irq, f, arg, tbdf, name)` itself.
- **MSI-X** is available through `pcimsienable(p, f, arg, name)`: on success it
  allocates one GICv3 ITS LPI, wires the handler `f`, and returns 0; it returns
  -1 when MSI is unavailable (no ITS, or the device has no MSI-X capability), in
  which case fall back to INTx. `sd-nvme` and `sd-ahci` are IRQ-driven through
  this path. (The ITS bring-up is in `os/drivers/gic-v3.c` + `pci.c`.)

### Ethernet (`etherif.h` / `devether.c`)

`addethercard("name", pnp)` registers a driver type; `pnp(Ether*)` claims a
present card and fills the `Ether`. Key differences from 9front's `Ether`:

- **No `port` / `tbdf` fields.** Drop the `e->port`/`e->tbdf` assignments and
  the `plan9.ini port=` override; claim the first inactive controller.
- **`etheriq(Ether*, Block*, int fromwire)`** takes the `fromwire` arg (pass
  `1`).
- **`ifstat` is `long(Ether*, void*, long count, ulong offset)`** — the
  offset/readstr form, **not** 9front's `char*(void*, char*, char*)`. Rewrite:
  build the text into a `malloc`'d buffer with `seprint`, then
  `n = readstr(offset, a, count, buf); free(buf); return n;`. devether passes
  the `Ether*` as the first arg (use `e->ctlr`), even though the Netif
  `promiscuous`/`multicast` callbacks still receive `e->arg`.
- **Link/speed**: there is no `ethersetspeed`/`ethersetlink` (Inferno's Netif
  lacks the queue-resizing machinery). Add a two-line static shim per file that
  sets `e->mbps` / `e->link` directly.
- **devether registry vs instances**: one driver registers many
  `addethercard` names (the Intel family registers ~20); the driver-*type*
  registry (`Maxcard`) is decoupled from the *instance* limit (`MaxEther`).

### Buffers, PHYs, barriers

- **Buffer pools**: `allocb(size)` for the simple ring; the `Bpool` API
  (`iallocbp(&pool)` / `growbp(&pool, n)`, `Block.pool` field) for drivers that
  want a pre-grown per-driver freelist refilled at interrupt time.
- **MII/PHY**: `ethermii.h` carries the `MiiPhy*`-based, clause-45-capable
  helper (`mii()`, `addmiibus()`, `miiane`/`miianec45`, `miistatus`/
  `miistatusc45`, `miimir`/`miimiw`, `miireset`). `ether-mii.c` is the library
  (listed in `DRIVERC`, **not** in the `.conf` link section). A NIC that drives
  an external PHY links against it.
- **Ordering**: `coherence()` is a real per-arch barrier (`dmb ish` on
  aarch64). Issue it between a DMA-buffer write and the doorbell that hands the
  buffer to the device.

---

## The per-file port checklist

Starting from a 9front `ether*.c` / `sd*.c`, the mechanical pass is:

1. **Includes.** Drop `io.h`, `../port/pci.h`, `../port/etherif.h`,
   `../port/ethermii.h`. Add the local seam headers: `etherif.h`, `pci.h`, and
   `ethermii.h` (only if the driver drives a PHY). Keep `../port/error.h`,
   `../port/netif.h`, and `u.h`/`mem.h`/`dat.h`/`fns.h`/`../port/lib.h`.
2. **`PCIWADDR`.** Define it locally, at the width the device's address
   registers actually take (see the width rule below):
   `#define PCIWADDR(x) ((uvlong)PADDR(x))` for a 64-bit-DMA part, `(u32int)`
   for a 32-bit-only one.
3. **Ring/format macros** that came from `io.h`: `ROUNDUP`/`NEXT`/`PREV`
   (`#define ROUNDUP(s,sz) ROUND((s),(sz))`, `#define NEXT(x,n) (((x)+1)%(n))`).
4. **`mallocalign`** → `#define mallocalign(n,a,o,sp) xspanalloc((n),(a),(sp))`.
5. **`ethersetspeed`/`ethersetlink`** static shims (set `e->mbps`/`e->link`).
6. **`ifstat`** rewritten to the native `long(Ether*,void*,long,ulong)` form.
7. **`kproc(name, fn, arg, flags)`** — the native signature has the trailing
   `flags` arg (pass `0`); 9front's has three args.
8. **`etheriq(e, b, 1)`** — add the `fromwire` arg.
9. **`scan`/`*pci`**: drop `vmap`/`vunmap` (use the BAR as a CPU address),
   `pcienable` → `pcisetbme`.
10. **`pnp`**: drop `e->port`/`e->tbdf` and the `intrenable()` call; set
    `e->irq = p->intl` and `e->interrupt = <handler>` and let devether wire it.
11. **Error string** lives in the Osenv: `up->errstr` → `up->env->errstr`.

The residue after this pass is the driver's own register logic, untouched.

---

## The rules that bite

### PCIWADDR width must match the device's address registers

`PCIWADDR` is the DMA address a buffer is handed to the device as. Set its width
to **what the device's descriptor / base-address-high registers actually
consume**, not to the host pointer width:

- A **64-bit-capable** part that writes a high dword (`Tdbah`/`Rdbah`,
  descriptor `addr[1]`, a `*raddrhi` register) must use `(uvlong)PADDR` —
  otherwise `pa>>32` is always 0 and the device silently DMAs only to the low
  4 GB. That is invisible on a board whose RAM sits below 4 GB (qemu `-M virt`
  at `0x4000_0000`) and a memory corruptor on one whose buffers do not.
  `ether-82563`, `ether-rtl8169`, `ether-i225` are in this class.
- A genuinely **32-bit-only** part hard-wires its high dwords to 0 and never
  writes a descriptor `addr[1]`; keep `(u32int)PADDR` faithfully.
  `ether-igbe`, `ether-rtl8139`, `ether-82598`, `ether-x550` are in this class
  — promoting them to `uvlong` would be pointless (the truncation happens in
  hardware regardless).

### The dialect is gcc, not kencc

`os/` compiles with **gcc** (`os/native.mk`), 9front with kencc. The mismatches
that actually break a build:

- **MMIO pointers are `volatile`.** gcc at `-O1` narrows a bitfield extraction
  off a non-`volatile` MMIO dereference — `(mmio[REG] >> 24) & 0xFF` becomes a
  single **byte** load at the register's high byte, and a device that only
  answers full-word config reads returns 0 for it. The full word reads fine;
  only the narrowed field is wrong. Declare every device-register pointer
  `volatile u32int*`, or load the whole word into a local before picking it
  apart.
- **Two anonymous members that nest the same type collide.** Inferno's `Rendez`
  embeds an anonymous `Lock`, so a struct that embeds **both** a bare `Lock;`
  and a `Rendez;` (a common 9front idiom: `struct Ctlr { Lock; QLock; Rendez;
  … }`) injects two anonymous `Lock`s at one level — gcc `-fplan9-extensions`
  rejects it as duplicate members where kencc tolerates it. **Name one of the
  members** (e.g. `Rendez rendez;`, then `sleep(&c->rendez)`/`wakeup(&c->rendez)`)
  so its inner `Lock` is not promoted into the outer scope; keep the explicit
  `Lock;` as the distinct interrupt-mask lock that `ilock(c)` resolves to. This
  preserves 9front's exact locking semantics.
- `USED` takes a single argument; `nil`, `uchar`/`ulong`, anonymous-struct
  field promotion (`Netif;`) and `SET` all work — follow an existing
  `os/drivers/*.c` as the model.

### PIO drivers map their I/O BAR as MMIO

An x86 driver that reaches its registers with `inb`/`outl` on an I/O BAR ports
by pointing its `csr*` accessors at the BAR as a plain MMIO address. `pci.c`
maps an I/O BAR into the PCIe I/O window as a CPU address, so the accessors
become `volatile` dereferences of `ctlr->port` (typed `uintptr`):
`#define csr32r(c,r) (*(volatile u32int*)((c)->port+(r)))`. `ether-rtl8139` and
`ether-rtl8169` both use this trick.

### DMA is assumed cache-coherent

The seam assumes cache-coherent DMA: the device snoops the CPU cache, so a
driver issues only `coherence()` ordering and **no explicit cache maintenance**.
A 9front `dmaflush()` call therefore becomes a no-op here. This holds for qemu
`-M virt`, coherent arm64 boards, and amd64. A **non-coherent** SoC breaks it:
its DMA drivers need real clean-before-send / invalidate-after-receive
discipline around every device-visible buffer — write those helpers before the
first such driver, not after the first corruption hunt (ON_PORTING.md Part II).
The other two standing seam assumptions are **identity DMA mapping**
(`PCIWADDR == PADDR`, no IOMMU/`dma-ranges` offset) and a **little-endian
host** (raw native-int register access); both hold for every near-term target.

---

## Reviewing 9front git history before a port

For each candidate, read `git log --oneline -- sys/src/9/pc/<driver>.c` in a
9front checkout and look for **kernel-touching commits** — they name the support
the driver will demand:

- `devether: provide ethersetspeed()…` → handled by the link/speed shim.
- `…use 64-bit physical addresses…` → the `PCIWADDR` width decision.
- `…use block pool` / `move common ethermii to port/` → `Bpool` / `MiiPhy*`
  ethermii, already landed.
- `pcN drivers: use pcienable()…` → the `pcisetbme` seam.
- `kernel: massive pci code rewrite` → the `Pcidev` API surface.

A history full of these against APIs already in the native tree predicts a
clean port; one against an API not yet present predicts that this driver is the
one that pays for it.

---

## Group manifests

Drivers ship to a board through group manifests under `os/drivers/groups/`,
included from a `board.mk` with one line
(`include ../drivers/groups/ether-pci.mk`):

- **`<group>.mk`** appends source stems to `DRIVERC` and the config fragment to
  `DRIVERCONF`. `ether-mii` (library-only) goes in `DRIVERC` but not the link
  section.
- **`<group>.conf`** has a `link` section listing each driver's link name (the
  `etherNAMElink` symbol's `NAME`); `mkdevc` accumulates these into the board's
  `.gen`, emitting an `addethercard()` call per name. Keep it in sync with
  `DRIVERC`.

Every PCI driver auto-probes at boot and claims a card only if present, so
listing the whole family costs image size only — a board without the hardware
pays nothing at runtime.

---

## Build and validate

```
cd os/aarch64 && make image HWTARG=virt64 USERSPACE=headless GIC=v3
```

Then boot under qemu with the matching `-device`, headless:

```
qemu-system-aarch64 -M virt,gic-version=3 -cpu cortex-a53 -m 512 -nographic \
    -kernel ivirt64.elf -device <nic>,netdev=n0 -netdev user,id=n0
```

A driver **lands by being proven against the matching qemu `-device`**, not on
a board. When qemu `-M virt` does not emulate the part (most modern 10G/2.5G
NICs), the driver is **build-test only**: confirm it compiles, links into
`ivirt64.elf`, and the kernel boots **regression-clean** — a still-working
control NIC attaches (`#l0: …`), the new driver registers via `addethercard`,
finds no card, and stands down with no panic or reset-timeout. End-to-end
traffic for those waits on real silicon.

---

## Status — PCI NICs ported

| Driver | Part | DMA | Kernel changes it paid for | Validation |
|--------|------|-----|----------------------------|-----------|
| `ether-rtl8139` | Realtek 8139 | 32-bit | none | qemu `-device rtl8139` |
| `ether-igbe` | Intel e1000 (8254x) | 32-bit | none (CLS default fix) | qemu `-device e1000` |
| `ether-82563` | Intel e1000e (8257x) | 64-bit | Bpool, MiiPhy* ethermii, devether registry split | qemu `-device e1000e` |
| `ether-rtl8169` | Realtek 8169/8168 | 64-bit | none (rode 82563's) | build-test |
| `ether-82598` | Intel 82598/82599 10G | 32-bit | none | build-test |
| `ether-x550` | Intel X550 10G | 32-bit | none | build-test |
| `ether-i225` | Intel i225/i226 2.5G | 64-bit | none (clause-45 ethermii + Bpool already in) | build-test |

Storage (`sd-ahci`, `sd-nvme`, `sd-scsi`, `sd-virtio`) and the virtio NIC ride
the same seam; NVMe and AHCI are IRQ-driven through `pcimsienable`/`intrenable`.
The legacy `vga*` family is **not** ported — the native kernel renders to a
`Memimage` and imports/exports the display over the namespace (ON_PORTING.md
Part II).
