# Native Inferno kernel — the amd64 (x86-64) arch file.  Everything shared
# (board selection, USERSPACE root profiles, the Dis/draw/IP/TLS lib lists,
# generated files, compile rules, link) lives in ../native.mk; this file
# states only what is amd64's.
#
#   make image-pc64    (from the repo root; see ../native.mk)
#
# amd64 is LP64 exactly like aarch64, so the whole Dis ABI and every
# width-clean driver carry over unchanged — only the arch core differs.

KARCH        := amd64
ARCHC        := main trap clock arch stubs tlsshim
ARCHS        := l
# -mno-red-zone: interrupts run on the kernel stack and would clobber the
# SysV red zone.  small model + no-pic: identity-mapped, all code < 2GB.
# SSE stays ON (libmath doubles); the trap stubs FXSAVE around handlers.
ARCHCFLAGS   := -mno-red-zone -mcmodel=small
INTERP_ARCHC := comp-amd64 das-amd64
KERN_ARCHC   := frexp-amd64 nan-amd64

# Host is usually aarch64 here, so cross by default; on an x86-64 host the
# native toolchain is used.  Override with CROSS= to force either way.
HOSTARCH := $(shell uname -m)
ifeq ($(HOSTARCH),x86_64)
CROSS        ?=
else
CROSS        ?= x86_64-linux-gnu-
endif

# qemu's multiboot loader only accepts a 32-bit ELF container.  The kernel
# is fully linked (no relocations), so rewrite the elf64-x86-64 executable
# to elf32-i386 in place — same 64-bit code and load addresses, 32-bit
# headers.  Runs after the link (POSTLINK hook in native.mk).
POSTLINK = $(CROSS)objcopy -O elf32-i386 $(KERNEL) $(KERNEL).tmp && mv -f $(KERNEL).tmp $(KERNEL)

include ../native.mk
