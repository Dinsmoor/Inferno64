# qemu-system-x86_64.  Pulled into os/amd64/Makefile by HWTARG=pc64.
# A board contributes:
#   ARCH     — the CPU arch it builds for == os/<ARCH>/ (toolchain/ABI).
#              `make image-pc64` from the repo root reads this and dispatches
#              to os/amd64, so you never name the arch by hand.
#   BOARDC   — its own sources in os/boards/$(HWTARG)/
#   DRIVERC  — its picks from the shared pool in os/drivers/
#   run      — how to boot the image

ARCH    := amd64

BOARDC  := board

# `screen` is the devdraw<->framebuffer glue; `ramfb-pc` is the qemu ramfb
# display over x86 fw_cfg port I/O.  q35 always has an i8042 (PS/2 kbd+mouse)
# for input — no -device needed.  Next: virtio-pci for net/sd.
DRIVERC := screen ramfb-pc i8042

# ramfb is the framebuffer; q35's built-in i8042 gives PS/2 kbd+mouse.
QEMUDEVS := -device ramfb

# `make run` brings up the GUI window (qemu's default display) with the
# serial console multiplexed onto stdio.  On a headless box use the test
# harness (QMP screendump) or add `-display vnc=:N`.
run: $(KERNEL)
	qemu-system-x86_64 -M q35 -m 512 \
		$(QEMUDEVS) -serial mon:stdio -kernel $(KERNEL)

# headless serial-only boot (no display), for quick bring-up checks
runserial: $(KERNEL)
	qemu-system-x86_64 -M q35 -m 512 -nographic -kernel $(KERNEL)

.PHONY: run runserial
