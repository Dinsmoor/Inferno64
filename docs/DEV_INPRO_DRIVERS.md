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
      them. MSI needs capability-list parsing and a GICv3 ITS.
- **Flat topology.** BAR sizing is single-level and there is no PCI-PCI bridge
      recursion, because qemu virt presents a flat root bus. A board with bridges
      needs window assignment and bridge walking.

## `sd-nvme` — NVMe

- [ ] **`rio()` is a stub; I/O goes through `bio()`.** The native (older Inferno)
      devsd has no `sdfakescsi` CDB layer, so SCSI-passthrough and the `ctl`
      query path are absent. Full support ports `sdfakescsi`.
- **One namespace.** The driver assumes namespace #1 (qemu exposes one). Real
      support enumerates the namespace list.
- **`mallocalign → xspanalloc` (never freed).** Queues are allocated once at
      attach, so the lack of a free path is harmless until controllers hot-unplug.

## `sd-ahci` — AHCI / SATA (the most simplified)

- [ ] **Fully polled — no interrupts.** Port interrupts stay masked (`p->ie = 0`)
      because an unmasked `PxIE` makes qemu re-assert the post-reset D2H FIS as a
      perpetual GIC SPI storm. `checkdrive()`/`ahciwait()` spin with `delay()`
      (the scheduler's `m->ticks` does not advance in polled bring-up). Full
      support harvests completions from the IRQ via `updatedrive()`.
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
      kernel HID driver. Until then a plugged `usb-kbd` is detected at the port
      but produces no input.
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

- [ ] **GICv2 only.** Every 9front `gic.c` is GICv2; a GICv3 controller (the
      `ICC_*` system-register CPU interface plus redistributors) is written fresh
      behind the same four intc calls. It is the sole interrupt-controller gap and
      gates MSI and modern SoCs. See `ON_PORTING.md` ("GICv3 is the one driver
      9front can't supply").
- **High ECAM map — done.** The default `qemu -M virt` runs unmodified: `l.S`
      widens VA to 39 bits (`T0SZ=25`) and `board.h` maps a `[256 G, 257 G)`
      device block covering both the high ECAM and the GICv3 redistributors. See
      `pci.c` above. Only the unused 64-bit MMIO window remains unmapped.
