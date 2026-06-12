# Native Inferno kernel — the aarch64 arch file.  Everything shared
# (board selection, USERSPACE root profiles, the Dis/draw/IP/TLS lib
# lists, generated files, compile rules, link) lives in ../native.mk;
# this file states only what is aarch64's.
#
#   make [image] [HWTARG=virt64] [USERSPACE=full|headless]   (see ../native.mk)

KARCH        := aarch64
ARCHC        := main trap clock stubs tlsshim
ARCHS        := l
ARCHCFLAGS   := -mstrict-align -mcmodel=small
INTERP_ARCHC := comp-aarch64 das-aarch64
KERN_ARCHC   := frexp-aarch64 nan-aarch64
CROSS        ?=   # native on an aarch64 host; set e.g. aarch64-linux-gnu- to cross

include ../native.mk
