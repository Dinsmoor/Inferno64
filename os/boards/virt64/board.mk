# qemu-system-aarch64 -M virt.  Pulled into os/aarch64/Makefile by
# HWTARG=virt64 (the default).  A board contributes:
#   BOARDC   — its own sources in os/boards/$(HWTARG)/
#   DRIVERC  — its picks from the shared pool in os/drivers/
#   run      — how to boot the image (optional; boards qemu can't
#              emulate deploy by other means, e.g. tftp from U-Boot)

BOARDC  := board

# Interrupt controller: GIC=v2 (default) or GIC=v3.  Exactly one gic-* driver
# is linked; v3 also needs the matching qemu machine (the run target adds
# gic-version=3 below).  The redistributors sit in the [0,1G) device map and
# the high ECAM block, so no extra MMU work.
GIC     ?= v2

DRIVERC := uart-pl011 gic-$(GIC) virtio rng-virtio input-virtio ramfb screen \
	   devether ether-virtio sd-virtio pci sd-nvme \
	   sd-scsi sd-ahci devusb usbxhci usbxhcipci

# PCI driver families (auto-probed; cost image size only when absent).
# The board keeps its own virtio transport drivers above; portable PCI
# device families come from the shared manifests in ../drivers/groups.
include ../drivers/groups/ether-pci.mk

# modern virtio (force-legacy=false) is required by the input drivers;
# rng speaks modern too.  ramfb is the display; keyboard+tablet the input.
# user-mode net (slirp): guest 10.0.2.15, gateway/host 10.0.2.2, dns 10.0.2.3
# (see README "Networking" for the in-guest configuration).
QEMUDEVS := -global virtio-mmio.force-legacy=false \
	    -device virtio-rng-device -device ramfb \
	    -device virtio-keyboard-device -device virtio-tablet-device \
	    -device qemu-xhci,id=xhci -device usb-kbd \
	    -netdev user,id=n0 -device virtio-net-device,netdev=n0

# optional persistent disk: make run DISK=/path/to/raw.img
# (create with: truncate -s 64M img; in the guest see README "Persistent storage")
ifneq ($(DISK),)
QEMUDISK := -drive if=none,file=$(DISK),format=raw,id=hd0 \
	    -device virtio-blk-device,drive=hd0
endif

# Default machine: PCIe ECAM is high (0x40_10000000, 256 buses), which the
# arch MMU now maps via board.h L1MAP_HIECAM_* (T0SZ=25, [256G,257G) device
# block).  No highmem-ecam=off needed — see board.h PCIE_ECAM_PHYS.
# GIC=v3 selects the GICv3 driver and the matching qemu machine.
ifeq ($(GIC),v3)
QEMUMACH := virt,gic-version=3
else
QEMUMACH := virt
endif
run: $(KERNEL)
	qemu-system-aarch64 -M $(QEMUMACH) -cpu cortex-a53 -m 512 -nographic \
		$(QEMUDEVS) $(QEMUDISK) -kernel $(KERNEL)

.PHONY: run
