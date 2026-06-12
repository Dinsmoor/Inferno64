# Native Inferno kernel for qemu-system-aarch64 -M virt.
# GNU make + host gcc (we are on an aarch64 host); no mk/kencc.
#
#   make            -> ivirt64.elf
#   make run        -> boot it under qemu (-nographic; C-a x quits)

MAKEFLAGS += -rR
.SUFFIXES:

ROOT    := ../..
CONF    := virt64
# the config actually fed to mkdevc/mkroot: the checked-in $(CONF) plus
# the generated full-application root list (see the $(GENCONF) rule)
GENCONF := $(CONF).gen

# limbo (and the prebuilt .dis baked into the root, see README "Building the
# image") come from a HOSTED build: `make all` at some inferno-os repo root.
# Prefer this tree's own hosted build; fall back to the main shared tree.
# Override with: make HOSTBIN=/path/to/Linux/aarch64/bin
ifneq ($(wildcard $(ROOT)/Linux/aarch64/bin/limbo),)
HOSTBIN ?= $(ROOT)/Linux/aarch64/bin
else
HOSTBIN ?= /home/tyler/inferno-os/Linux/aarch64/bin
endif
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
	   inferno latin1 netaux netif nocache nodynld parse pgrp print proc \
	   qio qlock random sysfile taslock xalloc \
	   devcons devroot devenv devmnt devprog devpipe devdup devdraw devpointer devsrv

ARCHC   := main trap clock uart virtio rng vinput ramfb screen stubs \
	   devether ethervirtio

# the native Plan 9-derived TCP/IP stack (os/ip) + #I.  Media: ether +
# loopback (+ the null/pkt utility media ipifc wants).  Skipped: bootp/
# dhcp (static or userspace config), il/gre/esp/rudp/igmp/ipmux/ppp.
IPC     := devip arp ip ipaux ipifc iproute iprouter ipv6 netlog \
	   nullmedium pktmedium ethermedium loopbackmedium plan9 ptclbsum \
	   icmp icmp6 tcp udp
ARCHS   := l

# libmemdraw/libmemlayer file lists follow the libs' own mkfiles
# (COMMONFILES + the Inferno/Plan9 SYSFILES), minus iprint.c: the
# kernel has a real iprint and the lib's is a stub for hosted builds.
# minus iprint (kernel has the real one) and the file-I/O entry points
# (cread/read/write/openmemsubfont want libc open/read — nothing in the
# kernel references them)
MEMDRAWC  := arc cmap defont ellipse fillpoly hwdraw icossin icossin2 \
	     line mesh poly string subfont \
	     alloc cload draw load unload
MEMLAYERC := draw layerop ldelete lhide line load lorigin lsetrefresh \
	     ltofront ltorear unload lalloc
# full libdraw (its mkfile OFILES): the Tk/Draw builtin modules are
# draw-protocol CLIENTS of devdraw, talking through the lib* I/O shims
# in port/discall.c — same architecture as the hosted emu
DRAWC     := alloc allocimagemix arith bezier border buildfont bytesperline \
	     chan cloadimage computil creadimage defont draw drawrepl ellipse \
	     font getdefont getsubfont init line mkfont openfont \
	     poly loadimage readimage readsubfont rectclip \
	     replclipr rgb string stringbg stringsubfont stringwidth subfont \
	     unloadimage window \
	     writeimage writesubfont
# dropped: readcolmap/writecolmap (no callers, want Bio);
# freesubfont/subfontcache/subfontname (libinterp/draw.c defines its own —
# the emu links libdraw as an ARCHIVE so those members are never pulled)

INTERPC := alt conv dec disops gc heap link load readmod runt raise stack \
	   string validstk xec comp-aarch64 das-aarch64 draw tk geom loader \
	   math raster3 keyring crypt ipint

# libmath: the $Math builtin's engine.  fdlibm e_*/k_* export __ieee754_*
# (no clash); the s_* files and pow10 export plain names, so KERNC below
# drops libkern's sin/floor/pow10 in favor of these.  FPcontrol-Inferno
# maps Plan 9 FP control onto getfcr/setfcr (l.S); the FPCR trap-enable
# bits are RAZ/WI on qemu's cortex-a53, so nothing actually traps.
MATHC   := blas dtoa fdim FPcontrol-Inferno gemm g_fmt gfltconv pow10 \
	   e_acos e_acosh e_asin e_atan2 e_atanh e_cosh e_exp e_fmod \
	   e_hypot e_j0 e_j1 e_jn e_lgamma_r e_log e_log10 e_pow \
	   e_rem_pio2 e_remainder e_sinh e_sqrt k_cos k_rem_pio2 k_sin \
	   k_tan s_asinh s_atan s_cbrt s_ceil s_copysign s_cos s_erf \
	   s_expm1 s_fabs s_finite s_floor s_ilogb s_log1p s_nextafter \
	   s_rint s_scalbn s_sin s_tan s_tanh

# crypto: the $Keyring/$Crypt/$IPints engines (lists from the libs' own
# mkfiles).  Minus libsec genrandom.c: stubs.c serves genrandom from
# virtio-rng instead of its X9.17-over-DES3 PRNG.  The kernel-side
# hooks libsec expects (truerand, _genrandomqlock, sysfatal, werrstr)
# all exist in os/port already — native kernels always linked libsec.
SECC    := des desmodes desECB desCBC des3ECB des3CBC aes blowfish idea \
	   hmac md5 md5block md4 sha1 sha1block sha2 sha256block sha512block \
	   sha1pickle md5pickle rc4 prng fastrand nfastrand \
	   probably_prime smallprimetest genprime dsaprimes gensafeprime \
	   genstrongprime rsagen rsafill rsaencrypt rsadecrypt rsaalloc \
	   rsaprivtopub eggen egencrypt egdecrypt egalloc egprivtopub egsign \
	   egverify dsagen dsaalloc dsaprivtopub dsasign dsaverify

MPC     := mpaux mpfmt strtomp mptobe mptole betomp letomp mpadd mpsub \
	   mpcmp mpfactorial mpmul mpleft mpright mpvecadd mpvecsub \
	   mpvecdigmuladd mpveccmp mpdigdiv mpdiv mpexp mpmod mpextendedgcd \
	   mpinvert mprand crt mptoi mptoui mptov mptouv

KRC     := dsaalg egalg rsaalg

# the whole Tk widget library (lists from libtk/mkfile + mkfile-std)
TKC     := ebind grids image packr panel parse utils varbl windw xdata \
	   canvs canvu carcs cbits cimag cline coval cpoly crect ctext cwind \
	   colrs entry extns frame buton label listb menus scale scrol \
	   textu textw tindx tmark ttags twind

# (sin/floor/pow10 come from libmath now, and strtod from its dtoa.c — see MATHC)
KERNC   := abort abs atol charstod cistrcmp cistrncmp cistrstr cleanname \
	   convD2M convM2D convM2S convS2M dofmt exp fcallfmt fmt \
	   fmtprint fmtquote fmtstr fmtvprint getfields log memccpy memchr \
	   memcmp memmove memset pow qsort rune runestrlen seprint \
	   smprint sqrt strcat strchr strcmp strcpy strdup strecpy \
	   strlen strncmp strncpy strrchr strstr strtol strtoll \
	   strtoul strtoull tokenize toupper u16 u32 u64 utfecpy utflen \
	   utfnlen utfrrune utfrune vseprint vsmprint vsnprint \
	   frexp-aarch64 nan-aarch64

OBJ     := $(ARCHS:%=$(O)/%.o) $(ARCHC:%=$(O)/%.o) $(PORTC:%=$(O)/port_%.o) \
	   $(IPC:%=$(O)/ip_%.o) \
	   $(INTERPC:%=$(O)/interp_%.o) $(KERNC:%=$(O)/kern_%.o) \
	   $(MEMDRAWC:%=$(O)/md_%.o) $(MEMLAYERC:%=$(O)/ml_%.o) \
	   $(DRAWC:%=$(O)/dr_%.o) $(TKC:%=$(O)/tk_%.o) \
	   $(MATHC:%=$(O)/ma_%.o) \
	   $(SECC:%=$(O)/sec_%.o) $(MPC:%=$(O)/mp_%.o) $(KRC:%=$(O)/kr_%.o) \
	   $(O)/$(CONF).o $(O)/$(CONF).root.o

all: $(KERNEL)

$(O):
	mkdir -p $(O)

# ---- generated files ----

GENH := $(GENCONF).root.h errstr.h version.h $(ROOT)/libinterp/runt.h $(ROOT)/libinterp/sysmod.h \
	$(ROOT)/libinterp/drawmod.h $(ROOT)/libinterp/tkmod.h $(ROOT)/libinterp/loadermod.h \
	$(ROOT)/libinterp/mathmod.h $(ROOT)/libinterp/raster3mod.h \
	$(ROOT)/libinterp/keyring.h $(ROOT)/libinterp/keyringif.h \
	$(ROOT)/libinterp/cryptmod.h $(ROOT)/libinterp/ipintsmod.h

# The full application set: the checked-in config lists only structure;
# the generated config appends every file under these trees (the hosted
# build's dis/ plus the checked-in data trees), so the image carries the
# whole system.  Regenerated every run, but the file is only touched when
# the list changes, so the root isn't rebaked needlessly.
ROOTTREES := dis fonts icons lib module man locale

$(GENCONF): $(CONF) force
	@{ cat $(CONF); (cd $(ROOT) && find $(ROOTTREES) -type f ! -name '*.sbl' 2>/dev/null | sort | sed 's,^,\t/,'); } > $@.tmp; \
	if cmp -s $@.tmp $@; then rm -f $@.tmp; else mv $@.tmp $@; echo "regenerated $@"; fi

$(CONF).c: ../port/mkdevc $(GENCONF)
	AWK=awk sh ../port/mkdevc $(GENCONF) > $@

# grouped target (&:) — one mkroot run produces both; without it -j runs
# the recipe twice in parallel and interleaves the output
# ROOTDEPS: every file the config bakes in, so a recompiled .dis or font
# actually lands in the image (the config lists them as absolute-in-tree
# paths; turn into real paths relative to ROOT)
ROOTDEPS := $(shell awk '/^root/{inroot=1;next} /^[a-z]/{inroot=0} inroot && $$1 ~ /^\// {print "$(ROOT)" $$1}' $(GENCONF) 2>/dev/null)

$(GENCONF).root.h $(GENCONF).root.s &: $(GENCONF) ../port/mkroot data2s ../init/virtinit.dis $(wildcard $(ROOTDEPS))
	mkdir -p $(ROOT)/chan $(ROOT)/dev $(ROOT)/dis $(ROOT)/env $(ROOT)/mnt $(ROOT)/n $(ROOT)/net $(ROOT)/prog $(ROOT)/tmp $(ROOT)/usr/inferno
	AWK=awk ROOT=$(abspath $(ROOT)) INIT=virtinit DATA2S="sh $(abspath data2s)" sh ../port/mkroot $(GENCONF)

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

$(ROOT)/libinterp/drawmod.h:
	cd $(ROOT)/libinterp && $(LIMBO) -t Draw -I../module ../module/runt.m > drawmod.h

$(ROOT)/libinterp/tkmod.h:
	cd $(ROOT)/libinterp && $(LIMBO) -t Tk -I../module ../module/runt.m > tkmod.h

$(ROOT)/libinterp/loadermod.h:
	cd $(ROOT)/libinterp && $(LIMBO) -t Loader -I../module ../module/runt.m > loadermod.h

$(ROOT)/libinterp/mathmod.h:
	cd $(ROOT)/libinterp && $(LIMBO) -t Math -I../module ../module/runt.m > mathmod.h

$(ROOT)/libinterp/raster3mod.h:
	cd $(ROOT)/libinterp && $(LIMBO) -t Raster3 -I../module ../module/runt.m > raster3mod.h

$(ROOT)/libinterp/keyring.h:
	cd $(ROOT)/libinterp && $(LIMBO) -t Keyring -I../module keyringif.m > keyring.h

$(ROOT)/libinterp/keyringif.h:
	cd $(ROOT)/libinterp && $(LIMBO) -a -I../module keyringif.m > keyringif.h

$(ROOT)/libinterp/cryptmod.h:
	cd $(ROOT)/libinterp && $(LIMBO) -t Crypt -I../module ../module/runt.m > cryptmod.h

$(ROOT)/libinterp/ipintsmod.h:
	cd $(ROOT)/libinterp && $(LIMBO) -t IPints -I../module ../module/ipints.m > ipintsmod.h

# ---- compile rules ----

HDRS := dat.h fns.h io.h mem.h virtio.h screen.h etherif.h \
	../port/portdat.h ../port/portfns.h ../port/lib.h ../port/netif.h ../ip/ip.h

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

$(O)/ip_%.o: ../ip/%.c $(HDRS) | $(O)
	$(CC) $(CFLAGS) -c -o $@ $<

$(O)/interp_%.o: $(ROOT)/libinterp/%.c $(GENH) | $(O)
	$(CC) $(CFLAGS) -c -o $@ $<

$(O)/md_%.o: $(ROOT)/libmemdraw/%.c | $(O)
	$(CC) $(CFLAGS) -c -o $@ $<

$(O)/ml_%.o: $(ROOT)/libmemlayer/%.c | $(O)
	$(CC) $(CFLAGS) -c -o $@ $<

$(O)/dr_%.o: $(ROOT)/libdraw/%.c | $(O)
	$(CC) $(CFLAGS) -c -o $@ $<

$(O)/tk_%.o: $(ROOT)/libtk/%.c | $(O)
	$(CC) $(CFLAGS) -I$(ROOT)/libtk -c -o $@ $<

$(O)/kern_%.o: $(ROOT)/libkern/%.c | $(O)
	$(CC) $(CFLAGS) -I$(ROOT)/libkern -c -o $@ $<

$(O)/ma_%.o: $(ROOT)/libmath/%.c | $(O)
	$(CC) $(CFLAGS) -I$(ROOT)/libmath -c -o $@ $<

$(O)/ma_%.o: $(ROOT)/libmath/fdlibm/%.c | $(O)
	$(CC) $(CFLAGS) -I$(ROOT)/libmath -c -o $@ $<

# libsec includes "os.h" from libmp/port (its mkfile does the same)
$(O)/sec_%.o: $(ROOT)/libsec/port/%.c | $(O)
	$(CC) $(CFLAGS) -I$(ROOT)/libmp/port -c -o $@ $<

$(O)/mp_%.o: $(ROOT)/libmp/port/%.c | $(O)
	$(CC) $(CFLAGS) -I$(ROOT)/libmp/port -c -o $@ $<

$(O)/kr_%.o: $(ROOT)/libkeyring/%.c $(GENH) | $(O)
	$(CC) $(CFLAGS) -c -o $@ $<

$(O)/$(CONF).o: $(CONF).c $(GENCONF).root.h $(HDRS) | $(O)
	$(CC) $(CFLAGS) -c -o $@ $<

$(O)/$(CONF).root.o: $(GENCONF).root.s | $(O)
	$(AS) $(ASFLAGS) -c -o $@ $<

# ---- link ----

$(KERNEL): $(OBJ) virt64.ld
	$(LD) -T virt64.ld -o $@ $(OBJ) $(shell $(CC) -print-libgcc-file-name)
	@echo "built $@"

# modern virtio (force-legacy=false) is required by the input drivers;
# rng speaks modern too.  ramfb is the display; keyboard+tablet the input.
# user-mode net (slirp): guest 10.0.2.15, gateway/host 10.0.2.2, dns 10.0.2.3
# (see README "Networking" for the in-guest configuration).
QEMUDEVS := -global virtio-mmio.force-legacy=false \
	    -device virtio-rng-device -device ramfb \
	    -device virtio-keyboard-device -device virtio-tablet-device \
	    -netdev user,id=n0 -device virtio-net-device,netdev=n0

run: $(KERNEL)
	qemu-system-aarch64 -M virt -cpu cortex-a53 -m 512 -nographic \
		$(QEMUDEVS) -kernel $(KERNEL)

clean:
	rm -rf $(O) $(KERNEL) $(CONF).c $(GENCONF) $(GENCONF).root.h $(GENCONF).root.s \
		$(CONF).root.h $(CONF).root.s errstr.h version.h

.PHONY: all run clean force
