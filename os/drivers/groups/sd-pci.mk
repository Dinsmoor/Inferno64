# PCI/PCIe storage controller family.  Include from a board.mk to pull the
# standard PCI block-device set in one line:
#
#	include ../drivers/groups/sd-pci.mk
#
# Each controller here registers an SDifc (see sd-pci.conf) and is probed by
# the sd subsystem at boot: its pnp() pcimatch()es a vendor/device id and
# claims the controller only if it is actually present.  So listing the whole
# family costs image size only — a board without the hardware pays nothing at
# runtime.  (The board still provides the shared `pci' bus enumerator and the
# `sd' device itself in its own DRIVERC/config.)
#
# To add a newly-ported controller: add its source stem to DRIVERC here and
# its SDifc name (the symbol's sd<NAME>ifc, minus the "ifc") to sd-pci.conf.
# Nothing board-specific belongs in this file.

# sd-scsi is the shared SCSI command-set helper (not a controller itself);
# AHCI drives its SATA units through it — scsionline/scsibio/scsiverify.
DRIVERC    += sd-ahci sd-nvme sd-scsi

DRIVERCONF += ../drivers/groups/sd-pci.conf
