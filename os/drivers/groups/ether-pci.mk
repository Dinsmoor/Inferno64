# PCI/PCIe Ethernet driver family.  Include from a board.mk to pull the
# standard PCI NIC set in one line:
#
#	include ../drivers/groups/ether-pci.mk
#
# Every driver here auto-probes the PCI bus at boot (devether etherreset ->
# the driver's pnp(), which pcimatch()es its vendor/device id) and claims a
# card only if it is actually present.  So listing the whole family costs
# image size only — a board without the hardware pays nothing at runtime.
#
# To add a newly-ported driver: add its source stem to DRIVERC here and its
# link name (the etherNAMElink symbol's NAME) to ether-pci.conf.  Nothing
# board-specific belongs in this file.

# ether-mii is the shared MII/PHY helper library (not a card itself); NICs
# that drive an external PHY — igbe — link against it.
DRIVERC    += ether-rtl8139 ether-igbe ether-mii

DRIVERCONF += ../drivers/groups/ether-pci.conf
