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
- **MSI-X is wired through the GICv3 ITS; INTx is the fallback.** `pcimsienable()`
      (`pci.c`) walks the capability list (`pcicapfind`), finds the MSI-X cap
      (ID `0x11`), allocates a GICv3 LPI for the device's requester id via
      `intcmsialloc()`, points table entry 0 at `GITS_TRANSLATER`, and enables
      MSI-X; a driver that gets `0` back is IRQ-driven, one that gets `-1`
      (no ITS, i.e. GICv2; or no MSI-X cap) falls back to `intrenable(p->intl,…)`
      on the legacy line. The four INTx lines still arrive as GIC SPI 3–6
      (`board.h PCIINTA`), slot-swizzled the way qemu's gpex wires them. MSI (cap
      ID `0x05`, config-space message register rather than a BAR table) is not yet
      parsed — devices that expose only MSI take the INTx fallback. Proven with
      `sd-nvme` under `qemu -M virt,gic-version=3`.
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
- **IRQ-driven completion via MSI-X.** `nvmeenable()` calls `pcimsienable()`; on
      success completions arrive as a GICv3 LPI (`nvmeintr` off the MSI vector),
      with a short poll fallback in `wcmd()` so a lost interrupt can't hang. Where
      there is no ITS (GICv2) the driver falls back to INTx. The CQ phase bit is
      still the source of truth — the interrupt just replaces the busy spin.
- **`mallocalign → xspanalloc` (never freed).** Queues are allocated once at
      attach, so the lack of a free path is harmless until controllers hot-unplug.

## `sd-ahci` — AHCI / SATA (the most simplified)

- **IRQ-driven completion — done (`sd-ahci.c`).** Data I/O sleeps on a per-`Drive`
      `Rendez` woken by `iainterrupt`; `iario()` no longer busy-spins on `PxCI`, so
      the scheduler runs during storage I/O. The AHCI line is a plain GIC SPI (no
      MSI), so it works under both `GIC=v2` and `GIC=v3`. The subtlety: qemu
      re-asserts the post-reset D2H FIS while the port settles, so the usual W1C
      idiom (write back only the `PxIS` bits just read) races that re-post — the
      missed bit pins `GHC.IS` into an SPI storm. The fix is to clear **all** `PxIS`
      bits (W1C of `~0`), after `PxSERR`; `updatedrive()` does this and `iaverify()`
      flushes the stale bring-up latches before arming `PxIE=Adhrs` once a drive is
      `Dready`. Bring-up stays polled (`m->ticks` does not advance there). Proven on
      qemu `ich9-ahci`: full 64 MB read on v2 and v3, coexisting with NVMe MSI-X.
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
  - **An ITS for LPIs → MSI-X — done (`gic-v3.c`, `GIC=v3`).** `itsinit()` hands
        the redistributor the **LPI Configuration** + **Pending** tables
        (`GICR_PROPBASER`/`GICR_PENDBASER`, `GICR_CTLR.EnableLPIs`), allocates the
        **ITS command queue** (`GITS_CBASER`/`GITS_CWRITER`) and the device +
        collection tables (`GITS_BASER<n>`), and maps collection 0 to this
        redistributor (**MAPC**). `intcmsialloc()` allocates an LPI, builds the
        device **ITT**, and issues **MAPD**/**MAPTI**/**INV**/**SYNC**; the caller
        points the device's MSI-X message at `GITS_TRANSLATER`. `intcdispatch`
        treats only intids 1020–1023 as special so LPIs (≥8192) dispatch and EOI
        normally. GICv2 keeps `intcmsialloc` stubbed to `-1` (INTx). Proven under
        `qemu -M virt,gic-version=3` with `sd-nvme`. INTx is unaffected.
- **High ECAM map — done.** The default `qemu -M virt` runs unmodified: `l.S`
      widens VA to 39 bits (`T0SZ=25`) and `board.h` maps a `[256 G, 257 G)`
      device block covering both the high ECAM and the GICv3 redistributors. See
      `pci.c` above. Only the unused 64-bit MMIO window remains unmapped; a forced
      64-bit prefetchable BAR would need a 40-bit VA (`T0SZ=24`, an L0 table) and
      a window allocator — contingent on a device we do not emulate.

## Path to completion (the dependency spine)

The per-driver gaps above are not independent. One keystone and a couple of
self-contained items account for nearly all of them:

- **MSI is the keystone — landed.** PCI capability-list parsing (`pci.c`
  `pcicapfind`/`pcimsienable`) and the GICv3 **ITS** (`gic-v3.c` `itsinit`/
  `intcmsialloc`) ship together: parsing has no delivery target without the ITS,
  and the ITS has nothing to translate without parsing. Both are in tree and
  proven against qemu's gpex + `gic-version=3`.
- **IRQ-driven storage — done.** `sd-nvme` harvests its completion queue from the
  MSI-X LPI (poll fallback retained); `sd-ahci` sleeps on a `Rendez` woken from
  its GIC SPI handler (the post-reset `PxIS` re-post that storms is handled by a
  W1C-of-`~0` clear, see its section). Both let the scheduler run during I/O, and
  coexist under `gic-version=3` (NVMe LPI + AHCI SPI).
- **USB enumerator + HID is the high-value Limbo-side item.** It is the one
  completion that is mostly a userspace/Limbo build, and the one that makes a
  native machine interactively usable from real USB input.
- **The "only-bites-on-real-hardware" items** — the `<4 GB` DMA pool
  (`ether-rtl8139`), per-device dcache flush ranges (shared DMA shim), the
  40-bit VA window (high ECAM), and SMMU translation (shared `PCIWADDR` shim) —
  are each self-contained and invisible under qemu, to be closed when a board
  that actually enforces the behaviour shows up. `ON_PORTING.md` Part II tracks
  the first such board (BPI-R4).
