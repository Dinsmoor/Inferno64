# Native Inferno kernel for qemu-system-aarch64 -M virt.
# GNU make + host gcc (we are on an aarch64 host); no mk/kencc.
#
#   make            -> ivirt64.elf
#   make run        -> boot it under qemu (-nographic; C-a x quits)

MAKEFLAGS += -rR
.SUFFIXES:

ROOT    := ../..
CONF    := virt64
HOSTBIN := /home/tyler/inferno-os/Linux/aarch64/bin
LIMBO   := $(HOSTBIN)/limbo

O       := build
KERNEL  := ivirt64.elf

CC      := gcc
AS      := gcc
LD      := ld

# Pool-allocator free-tree audit on every alloc/free (os/port/alloc.c).
# Default on for development; `make PARANOID=0` for a faster kernel.
PARANOID ?= 1

INCS    := -I. -I$(ROOT)/Inferno/aarch64/include -I$(ROOT)/include -I$(ROOT)/libinterp
CFLAGS  := -O1 -g -static -ffreestanding -fno-builtin -fno-pic -fno-pie \
	   -fno-stack-protector -fno-strict-aliasing -fno-omit-frame-pointer \
	   -mstrict-align -mcmodel=small \
	   -fplan9-extensions -std=gnu2x -fcommon \
	   -Wno-unused-parameter -Wno-parentheses -Wno-unknown-pragmas \
	   -DKERNDATE=$(shell date +%s) -DPOOLPARANOID=$(PARANOID) \
	   $(INCS)
ASFLAGS := -ffreestanding -fno-pic -I. $(INCS)

PORTC   := alarm alloc allocb chan dev dial dis discall exception exportfs \
	   inferno latin1 nocache nodynld parse pgrp print proc qio qlock \
	   random sysfile taslock xalloc \
	   devcons devroot devenv devprog devpipe devdup

ARCHC   := main trap clock uart rng stubs
ARCHS   := l

INTERPC := alt conv dec disops gc heap link load readmod runt raise stack \
	   string validstk xec comp-aarch64 das-aarch64

KERNC   := abort abs atol charstod cistrcmp cistrncmp cistrstr cleanname \
	   convD2M convM2D convM2S convS2M dofmt exp fcallfmt floor fmt \
	   fmtprint fmtquote fmtstr fmtvprint getfields log memccpy memchr \
	   memcmp memmove memset pow pow10 qsort rune runestrlen sin seprint \
	   smprint sqrt strcat strchr strcmp strcpy strdup strecpy \
	   strlen strncmp strncpy strrchr strstr strtod strtol strtoll \
	   strtoul strtoull tokenize toupper u16 u32 u64 utfecpy utflen \
	   utfnlen utfrrune utfrune vseprint vsmprint vsnprint \
	   frexp-aarch64 nan-aarch64

OBJ     := $(ARCHS:%=$(O)/%.o) $(ARCHC:%=$(O)/%.o) $(PORTC:%=$(O)/port_%.o) \
	   $(INTERPC:%=$(O)/interp_%.o) $(KERNC:%=$(O)/kern_%.o) \
	   $(O)/$(CONF).o $(O)/$(CONF).root.o

all: $(KERNEL)

$(O):
	mkdir -p $(O)

# ---- generated files ----

GENH := $(CONF).root.h errstr.h version.h $(ROOT)/libinterp/runt.h $(ROOT)/libinterp/sysmod.h

$(CONF).c: ../port/mkdevc $(CONF)
	AWK=awk sh ../port/mkdevc $(CONF) > $@

# grouped target (&:) — one mkroot run produces both; without it -j runs
# the recipe twice in parallel and interleaves the output
$(CONF).root.h $(CONF).root.s &: $(CONF) ../port/mkroot data2s ../init/virtinit.dis
	mkdir -p $(ROOT)/chan $(ROOT)/dev $(ROOT)/dis $(ROOT)/env $(ROOT)/net $(ROOT)/prog
	AWK=awk ROOT=$(abspath $(ROOT)) INIT=virtinit DATA2S="sh $(abspath data2s)" sh ../port/mkroot $(CONF)

../init/virtinit.dis: ../init/virtinit.b
	$(LIMBO) -I$(ROOT)/module -o $@ $<

errstr.h: ../port/error.h
	sed 's/extern //;s,;.*/\* , = ",;s, \*/,";,' < ../port/error.h > errstr.h

version.h:
	echo '#define VERSION "kernelwork (native aarch64)"' > $@

$(ROOT)/libinterp/runt.h:
	cd $(ROOT)/libinterp && $(LIMBO) -a -I../module ../module/runt.m > runt.h

$(ROOT)/libinterp/sysmod.h:
	cd $(ROOT)/libinterp && $(LIMBO) -t Sys -I../module ../module/runt.m > sysmod.h

# ---- compile rules ----

HDRS := dat.h fns.h io.h mem.h ../port/portdat.h ../port/portfns.h ../port/lib.h

$(O)/%.o: %.c $(HDRS) $(GENH) | $(O)
	$(CC) $(CFLAGS) -c -o $@ $<

$(O)/%.o: %.S | $(O)
	$(AS) $(ASFLAGS) -c -o $@ $<

$(O)/port_%.o: ../port/%.c $(HDRS) $(GENH) | $(O)
	$(CC) $(CFLAGS) -c -o $@ $<

# Recompile alloc.c when PARANOID changes value (stamp only updates then).
$(O)/paranoid.stamp: force | $(O)
	@[ "`cat $@ 2>/dev/null`" = "$(PARANOID)" ] || echo $(PARANOID) > $@
force: ;
$(O)/port_alloc.o: $(O)/paranoid.stamp

$(O)/interp_%.o: $(ROOT)/libinterp/%.c $(GENH) | $(O)
	$(CC) $(CFLAGS) -c -o $@ $<

$(O)/kern_%.o: $(ROOT)/libkern/%.c | $(O)
	$(CC) $(CFLAGS) -I$(ROOT)/libkern -c -o $@ $<

$(O)/$(CONF).o: $(CONF).c $(CONF).root.h $(HDRS) | $(O)
	$(CC) $(CFLAGS) -c -o $@ $<

$(O)/$(CONF).root.o: $(CONF).root.s | $(O)
	$(AS) $(ASFLAGS) -c -o $@ $<

# ---- link ----

$(KERNEL): $(OBJ) virt64.ld
	$(LD) -T virt64.ld -o $@ $(OBJ) $(shell $(CC) -print-libgcc-file-name)
	@echo "built $@"

run: $(KERNEL)
	qemu-system-aarch64 -M virt -cpu cortex-a53 -m 256 -nographic \
		-device virtio-rng-device -kernel $(KERNEL)

clean:
	rm -rf $(O) $(KERNEL) $(CONF).c $(CONF).root.h $(CONF).root.s errstr.h version.h

.PHONY: all run clean force
