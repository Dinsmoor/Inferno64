# In-Progress — native drivers: stubs, shims, and what full support needs

This is the **driver follow-up checklist** for the native kernel's `os/drivers`
pool. Every driver here is a **first pass proven against `qemu -M virt`** and
nothing else yet; this file records, per driver, what is stubbed, shimmed, or
simplified to reach that point, and what a full implementation on real silicon
would add. The durable porting model and seams are in `ON_PORTING.md` (Part III);
this file is the "what's not finished" view that sits beside it.

Two rules frame everything below:

- **qemu is the first-pass oracle.** A shim is acceptable when qemu's emulation
  makes it correct (identity-mapped DMA, cache-coherent DMA, no DMA boundary
  enforcement, INTx-only delivery). The same shim is a real gap on hardware that
  doesn't share that behaviour. Each row says which.
- **MMIO register pointers are `volatile`.** Not an O0 pragma — `volatile` is the
  language-standard guarantee against load narrowing/reordering, honoured the
  same by gcc and mingw, at zero runtime cost. See `ON_PORTING.md`
  ("MMIO register pointers are `volatile`") for the hazard that motivates it.

## Shared PCIe seam shims (every PCI driver)

The PCI drivers compile against a small block of `#define` shims at the top of
each file. They are correct on qemu virt; they are the seam where a real board
substitutes real plumbing.

| Shim | Files | Correct because (qemu) | Hardware needs |
|---|---|---|---|
| `PCIWADDR(x) → PADDR(x)` | sd-nvme, sd-ahci, ether-rtl8139, usbxhcipci | PCI DMA address == physical address | SMMU/IOMMU translation when DMA addr ≠ phys |
| `vmap(pa,n) → KADDR(pa)`, `vunmap → USED` | sd-nvme, usbxhcipci | BARs sit in the identity-mapped `[0,1G)` device window | a real `vmap` that allocates kernel VA + page-table entries |
| `pcienable/pcidisable → (0)/USED` | sd-nvme, usbxhcipci | the enumerator already enabled decode + bus-master | per-device clock/power/decode gating |
| `dmaflush(rw,a,n) → coherence()` | sd-nvme, sd-ahci, usbxhci | emulated DMA is cache-coherent with the CPU | dcache clean/invalidate-range around every device buffer |
| `PCIWADDR` cast to 32-bit | ether-rtl8139 | the 8139 is a 32-bit-DMA part; qemu RAM is low | a bounce buffer / DMA pool guaranteed below 4 GB |

## `pci.c` — the ECAM enumerator

- **High ECAM is mapped; high 64-bit MMIO is not (and is unused).** Config space
      is the default machine's high ECAM (`0x40_10000000`, 1 MB/bus, 256 buses);
      the arch MMU reaches it with a `[256 G, 257 G)` device block (`board.h`
      `L1MAP_HIECAM_*`, `T0SZ=25` widening VA to 39 bits in `l.S`). That same
      block also covers the GICv3 redistributors at `0x40_00000000`. The qemu
      `-M virt,highmem-ecam=off` low ECAM (`0x3f000000`) still works if
      `PCIE_ECAM_PHYS` is pointed back. The 64-bit MMIO window at
      `0x80_00000000` (512 G) stays unmapped: `pcibars()` assigns every BAR from
      the low 32-bit window and zeroes 64-bit BAR high halves, so no device
      lands there. A device with a forced 64-bit prefetchable BAR would need a
      40-bit VA (`T0SZ=24`, an L0 table) and a window allocator.
- **INTx legacy interrupts only, no MSI/MSI-X.** The four legacy lines arrive as
      GIC SPI 3–6 (`board.h PCIINTA`), slot-swizzled the way qemu's gpex wires
      them. Full support: walk the capability list for MSI (cap ID `0x05`) and
      MSI-X (cap ID `0x11`), read the MSI-X table's BAR + offset, and allocate
      per-vector entries. MSI is only *plumbing* on its own — it has no delivery
      target until the GICv3 ITS exists, so PCI MSI parsing and the ITS (see
      "Kernel-wide gaps") are two halves of **one** deliverable. qemu's gpex does
      expose MSI-X tables, so this is testable in-tree once the ITS lands.
- **Flat topology, no bridge recursion.** BAR sizing is single-level because qemu
      virt presents a flat root bus. Full support: detect header-type `0x01`
      bridges, assign primary/secondary/subordinate bus numbers, and program each
      bridge's memory / prefetch / I-O base+limit windows so child BARs fall
      inside the parent window. Exercise it with `-device pcie-pci-bridge` or a
      real board.

## `sd-nvme` — NVMe

- [ ] **`rio()` is a stub; I/O goes through `bio()`.** The native (older Inferno)
      devsd has no `sdfakescsi` CDB layer, so SCSI-passthrough and the `ctl`
      query path are absent. Full support ports `sdfakescsi` (same port the AHCI
      driver needs).
- **One namespace.** The driver assumes namespace #1 (qemu exposes one). Full
      support: `Identify` (CNS=2) the active-namespace-ID list, then `Identify
      Namespace` (CNS=0) each, and attach an `Sdunit` per namespace.
- [ ] **Polled completion queue.** The driver spins on the CQ phase bit instead
      of taking the controller's interrupt. Full support harvests the completion
      queue from the MSI vector — and therefore co-gates on PCI MSI + the GICv3
      ITS (see `pci.c` and "Kernel-wide gaps").
- **`mallocalign → xspanalloc` (never freed).** Queues are allocated once at
      attach, so the lack of a free path is harmless until controllers hot-unplug.

## `sd-ahci` — AHCI / SATA (the most simplified)

- [ ] **Fully polled — no interrupts.** Port interrupts stay masked (`p->ie = 0`)
      because an unmasked `PxIE` makes qemu re-assert the post-reset D2H FIS as a
      perpetual GIC SPI storm. `checkdrive()`/`ahciwait()` spin with `delay()`
      (the scheduler's `m->ticks` does not advance in polled bring-up). Full
      support: enable `PxIE`, clear `PxIS`/`GHC.IS` in the handler, and harvest
      completed command slots via `updatedrive()` off the GIC vector. This is the
      headline gap — it is also what lets the scheduler tick during storage I/O.
- **Drive-ready gate relaxed.** Bring-up accepts qemu's post-reset task value
      `0x30` (WRERR|SEEK, no DRDY); real hardware posts `0x50`. No change needed —
      the relaxed gate also accepts real hardware.
- [ ] **ICH AHCI-mode poke is hardcoded for qemu's `ich9-ahci`.** Gate it behind
      real-ICH detection for the future x86_64 target.
- **Hard-disk path only.** `debug/prid/datapi = 0`; ATAPI/packet and
      port-multiplier handling are off. `sdfakescsi` is not used — block I/O rides
      the generic `sd-scsi` `bio` path. `upamalloc → (pa)` (BAR already mapped).

## `sd-scsi` — generic SCSI block helpers

- **Local 2-arg `sdmalloc(p,sz)` shim** matches the boot-loader `sdscsi` vintage
  these helpers came from. Intentional, not a gap.

## USB — `devusb` + `usbxhci` + `usbxhcipci`

The host-controller stack is complete and proven (controller reset → command/
event rings → DCBAA → run → root hub → port detects a connected device). What is
missing is everything *above* the controller.

- [ ] **No device enumerator, no class drivers.** 9front runs bus enumeration and
      HID (`nusb/kb`) as **userspace** programs against the `#u` endpoint files;
      the native kernel has neither. The Inferno-native design is a Limbo process
      that walks `#u`, addresses devices, reads descriptors, and turns an
      interrupt endpoint into keyboard/mouse events — namespace files, not a
      kernel HID driver. The xHCI enumerator follows the controller's command
      sequence: on a port-status-change, reset the port, then **Enable Slot** →
      build the Input Context → **Address Device** → `GET_DESCRIPTOR(device)` for
      class/VID/PID → read the config descriptor → **Configure Endpoint** (one
      transfer ring per endpoint, set up one at a time) → `SET_CONFIGURATION`. The
      HID class step then turns a boot-protocol interrupt-IN endpoint into
      key/pointer events on the existing input path. Until both exist a plugged
      `usb-kbd` is detected at the port but produces no input. This is the only
      deliverable here whose completion is mostly a **Limbo/userspace** build, not
      a kernel gap.
- **`mallocalign`/`freealign` is a real aligned allocator** (the native pool has
      none and the driver frees its rings), but it **ignores the `span`
      no-boundary-cross argument** — harmless under qemu, to be honoured on real
      hardware with DMA boundary limits.
- **Framework shims, all intentional:** `eqlock → qlock` (native `qlock` is not
      error-unwinding like 9front's), `isaconfig → 0` (no ISA bus; controllers
      come from the PCI link function), and `Hci` spells out `type/port/irq`
      instead of embedding `ISAConf` (native `ISAConf.type` is a `char[]`, which
      collides with `hp->type = "xhci"`).

## Kernel-wide gaps (not per-driver)

- **GICv2 and GICv3 (single-cpu).** Both drivers (`gic-v2.c`, `gic-v3.c`) sit
      behind the same four intc calls; the board picks one (`board.mk GIC=v2|v3`,
      default v2; v3's run target adds `gic-version=3`). GICv3 brings up the
      distributor with affinity routing (`GICD_IROUTER`), wakes this cpu's
      redistributor (SGIs/PPIs live there now, not the distributor), and drives
      the `ICC_*` system-register CPU interface — EL1 reaches it because `l.S`
      sets `ICC_SRE_EL2.Enable` on the EL2→EL1 drop. Remaining GICv3 gaps:
  - [ ] **SMP redistributor walk + IPIs.** `intcinit` wakes only *this* cpu's
        redistributor. Full SMP: per-cpu redistributor init (each cpu clears its
        own `GICR_WAKER.ProcessorSleep`, sets SGI/PPI groups+priorities, enables
        its `ICC_*` interface) plus SGI generation via `ICC_SGI1R_EL1` for
        cross-cpu preempt / TLB shootdown. Co-gates on the kernel becoming SMP at
        all.
  - [ ] **An ITS for LPIs → MSI/MSI-X.** This is the concrete, sizeable piece and
        the delivery target PCI MSI parsing needs (the two ship together). Steps:
        (1) allocate + hand the redistributor the **LPI Configuration table**
        (1 byte/LPI: priority+enable) and per-redistributor **Pending table**,
        program `GICR_PROPBASER`/`GICR_PENDBASER`, set `GICR_CTLR.EnableLPIs`;
        (2) allocate the **ITS command queue** (`GITS_CBASER`/`GITS_CWRITER`) and
        the device + collection tables (`GITS_BASER<n>`); (3) per device allocate
        an **ITT** and issue **MAPD** (DeviceID→ITT), **MAPC** (collection→this
        redistributor), **MAPTI/MAPI** (DeviceID+EventID→INTID+collection), then
        **INV/SYNC** to publish; (4) point the device's MSI-X message at
        `GITS_TRANSLATER` with the EventID as data. qemu models the ITS under
        `gic-version=3`, so it is testable in-tree. INTx is unaffected (still GIC
        SPI).
- **High ECAM map — done.** The default `qemu -M virt` runs unmodified: `l.S`
      widens VA to 39 bits (`T0SZ=25`) and `board.h` maps a `[256 G, 257 G)`
      device block covering both the high ECAM and the GICv3 redistributors. See
      `pci.c` above. Only the unused 64-bit MMIO window remains unmapped; a forced
      64-bit prefetchable BAR would need a 40-bit VA (`T0SZ=24`, an L0 table) and
      a window allocator — contingent on a device we do not emulate.

## Path to completion (the dependency spine)

The per-driver gaps above are not independent. One keystone and a couple of
self-contained items account for nearly all of them:

- **MSI is the keystone.** PCI capability-list parsing (`pci.c`) and the GICv3
  **ITS** ("Kernel-wide gaps") are two halves of one deliverable: parsing has no
  delivery target without the ITS, and the ITS has nothing to translate without
  parsing. Land them together against qemu's gpex + `gic-version=3`.
- **IRQ-driven storage rides on MSI.** Once MSI delivers, the AHCI and NVMe
  "polled completion" gaps each gain a real vector to harvest from
  (`updatedrive()` / completion-queue handler) instead of spinning.
- **USB enumerator + HID is the high-value Limbo-side item.** It is the one
  completion that is mostly a userspace/Limbo build, and the one that makes a
  native machine interactively usable from real USB input.
- **The "only-bites-on-real-hardware" items** — the `<4 GB` DMA pool
  (`ether-rtl8139`), per-device dcache flush ranges (shared DMA shim), the
  40-bit VA window (high ECAM), and SMMU translation (shared `PCIWADDR` shim) —
  are each self-contained and invisible under qemu, to be closed when a board
  that actually enforces the behaviour shows up. `ON_PORTING.md` Part II tracks
  the first such board (BPI-R4).
