# qemu-system-aarch64 -M virt.  Pulled into os/aarch64/Makefile by
# HWTARG=virt64 (the default).  A board contributes:
#   BOARDC   — its own sources in os/boards/$(HWTARG)/
#   DRIVERC  — its picks from the shared pool in os/drivers/
#   run      — how to boot the image (optional; boards qemu can't
#              emulate deploy by other means, e.g. tftp from U-Boot)

BOARDC  := board

DRIVERC := uart-pl011 gic-v2 virtio rng-virtio input-virtio ramfb screen \
	   devether ether-virtio sd-virtio pci ether-rtl8139 sd-nvme

# modern virtio (force-legacy=false) is required by the input drivers;
# rng speaks modern too.  ramfb is the display; keyboard+tablet the input.
# user-mode net (slirp): guest 10.0.2.15, gateway/host 10.0.2.2, dns 10.0.2.3
# (see README "Networking" for the in-guest configuration).
QEMUDEVS := -global virtio-mmio.force-legacy=false \
	    -device virtio-rng-device -device ramfb \
	    -device virtio-keyboard-device -device virtio-tablet-device \
	    -netdev user,id=n0 -device virtio-net-device,netdev=n0

# optional persistent disk: make run DISK=/path/to/raw.img
# (create with: truncate -s 64M img; in the guest see README "Persistent storage")
ifneq ($(DISK),)
QEMUDISK := -drive if=none,file=$(DISK),format=raw,id=hd0 \
	    -device virtio-blk-device,drive=hd0
endif

# highmem-ecam=off keeps the PCIe ECAM config window at 0x3f000000 (16
# buses), inside the [0,1G) device-mapped region — see board.h PCIE_*.
# The qemu default puts ECAM high at 0x40_10000000, which the current 4GB
# identity map doesn't cover.
run: $(KERNEL)
	qemu-system-aarch64 -M virt,highmem-ecam=off -cpu cortex-a53 -m 512 -nographic \
		$(QEMUDEVS) $(QEMUDISK) -kernel $(KERNEL)

.PHONY: run
