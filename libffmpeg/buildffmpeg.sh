#!/bin/sh
# buildffmpeg.sh -- extract the bundled FFmpeg tarball and build a lean, fully
# portable static decode build for the Inferno emu.
#
# Unlike the other vendored C trees (libstb / libwebp single-header
# amalgamations, the libfreetype source drop), FFmpeg is far too large and
# interdependent to commit unpacked or to amalgamate, so we vendor only the
# upstream *tarball* (libffmpeg/ffmpeg-<ver>.tar.xz) and unpack + configure +
# build it here, at C-build time.  The product is the set of static libav*/
# libsw* archives under $SRC/ ; libffmpeg/mkfile then folds their objects, plus
# the Inferno glue (ffwrap.o), into one libffmpeg.a for the emu link.
#
# The build is deliberately minimal and portable, matching the philosophy of
# the other vendorings (no SIMD/asm, no host-specific anything):
#   * --disable-everything then re-enable only the modern web/video DECODE set;
#   * --disable-asm / --disable-x86asm : pure C, so no nasm/yasm needed and the
#     same objects build on any target arch (arm64, amd64, ...);
#   * --enable-small --disable-debug --disable-runtime-cpudetect : smallest libs
#     (FFmpeg itself carries no -g; the Inferno glue is built by the mkfile);
#   * --disable-network --disable-programs --disable-doc --disable-autodetect :
#     no sockets, no ffmpeg/ffprobe binaries, no external-lib probing -- the
#     decoders read from memory buffers we feed them, never the host.
#
# Env in (exported by the mkfile): FFCC (the arch $CC, e.g. "gcc -c -m64") and
# AR.  We split FFCC into the compiler program (first word) for --cc and any
# -m* ABI flag for --extra-cflags; the -c (compile-only) flag is dropped because
# configure needs a compiler it can also link with.  Re-running is cheap: if the
# archives already exist and are newer than the tarball, we do nothing.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
cd "$here"

tarball=$(ls ffmpeg-*.tar.xz 2>/dev/null | head -1)
[ -n "$tarball" ] || { echo "buildffmpeg.sh: no ffmpeg-*.tar.xz in $here" >&2; exit 1; }

ver=$(echo "$tarball" | sed -n 's/^ffmpeg-\(.*\)\.tar\.xz$/\1/p')
SRC="$here/ffmpeg-$ver"

AR=${AR:-ar}

# Split FFCC ("gcc -c -m64") -> CC_BASE (compiler program) + EXTRA_CFLAGS (ABI
# flags only).  Drop -c (configure links its probes) and -o (no output here).
FFCC=${FFCC:-gcc}
CC_BASE=""
EXTRA_CFLAGS=""
for tok in $FFCC; do
	case "$tok" in
	-c|-o) ;;					# compile-only / output: skip
	-m*)   EXTRA_CFLAGS="$EXTRA_CFLAGS $tok" ;;	# ABI flag: keep
	-*)    ;;					# other flags: configure supplies its own
	*)     [ -z "$CC_BASE" ] && CC_BASE="$tok" ;;	# first bareword = the compiler
	esac
done
[ -n "$CC_BASE" ] || CC_BASE=gcc

# The archives the emu link ultimately needs.  swscale = colour-convert/scale to
# RGBA; swresample is pulled in by avformat/avcodec; avutil underpins all.
LIBS="libavformat/libavformat.a libavcodec/libavcodec.a \
	libswscale/libswscale.a libswresample/libswresample.a \
	libavutil/libavutil.a"

# Two phases, independently guarded:
#   A. the EXPENSIVE unpack+configure+make of the libav*/libsw* archives -- run
#      only when an archive is missing or older than the tarball;
#   B. the CHEAP merge of those archives into obj/*.o (ld -r) -- run whenever
#      obj/ is missing, so a `mk clean` (which keeps the built archives but drops
#      obj/) re-merges without recompiling the world.
archives_built=1
for l in $LIBS; do
	if [ ! -f "$SRC/$l" ] || [ "$here/$tarball" -nt "$SRC/$l" ]; then
		archives_built=0
		break
	fi
done

if [ "$archives_built" = 1 ] && [ -d "$here/obj" ] && ls "$here/obj"/*.o >/dev/null 2>&1; then
	echo "buildffmpeg.sh: ffmpeg $ver already built and merged"
	exit 0
fi

if [ "$archives_built" = 0 ]; then
	echo "buildffmpeg.sh: unpacking ffmpeg $ver"
	rm -rf "$SRC"
	tar xJf "$here/$tarball" -C "$here"
	[ -d "$SRC" ] || { echo "buildffmpeg.sh: tarball did not unpack to $SRC" >&2; exit 1; }
fi

cd "$SRC"

if [ "$archives_built" = 0 ]; then
echo "buildffmpeg.sh: configuring ffmpeg $ver (lean portable decode build)"
./configure \
	--cc="$CC_BASE" \
	--extra-cflags="$EXTRA_CFLAGS" \
	--disable-everything \
	--disable-asm --disable-x86asm \
	--disable-runtime-cpudetect \
	--enable-small --disable-debug \
	--disable-programs --disable-doc \
	--disable-network --disable-autodetect \
	--disable-shared --enable-static \
	--disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
	--disable-avdevice --disable-avfilter \
	--enable-avcodec --enable-avformat --enable-swscale --enable-swresample \
	--enable-decoder=h264,hevc,vp8,vp9,av1,mpeg4,mpeg2video,mjpeg,h263,aac,mp3,flac \
	--enable-parser=h264,hevc,vp8,vp9,av1,mpeg4video,mpegvideo,mjpeg,aac,mpegaudio,flac \
	--enable-demuxer=mov,matroska,mpegts,mpegps,avi,flv,mp3,flac,wav,ogg,h264,hevc \
	--enable-protocol=file \
	>configure.log 2>&1 || { echo "buildffmpeg.sh: configure failed; see $SRC/configure.log" >&2; tail -20 configure.log >&2; exit 1; }

echo "buildffmpeg.sh: compiling ffmpeg $ver (this is the slow part; content-cached after)"
jobs=$( (nproc 2>/dev/null) || echo 4 )
make -j"$jobs" $LIBS >build.log 2>&1 || { echo "buildffmpeg.sh: make failed; see $SRC/build.log" >&2; tail -30 build.log >&2; exit 1; }

for l in $LIBS; do
	[ -f "$SRC/$l" ] || { echo "buildffmpeg.sh: expected archive $l not produced" >&2; exit 1; }
done
fi	# archives_built == 0

# Merge each libav*/libsw* archive into ONE relocatable object via a partial
# link (ld -r --whole-archive), then drop the merged objects in a flat obj/ dir
# for the mkfile to fold into libffmpeg.a.  We must NOT just `ar x` the archives:
# libavcodec.a carries DUPLICATE member names (two different cabac.o, two
# parser.o), and `ar x` writes them to the same path so the later one silently
# clobbers the earlier -- dropping e.g. ff_init_cabac_decoder and breaking the
# emu link.  `ld -r --whole-archive` pulls in every member (duplicate names and
# all) and resolves them correctly, so the one merged object per library carries
# the complete code.  Folding everything into the single libffmpeg.a then lets
# ld resolve the libav* inter-library references internally, so the emu link
# needn't care about their order.
# Use the real linker for the partial link, NOT mk's $LD (which is the gcc
# driver "gcc -m64" -- gcc -r is not the same as ld -r and chokes here).  Honour
# an explicit FFLD override for exotic toolchains.
LD=${FFLD:-ld}
objdir="$here/obj"
rm -rf "$objdir"
mkdir -p "$objdir"
pfx=0
for l in $LIBS; do
	a="$SRC/$l"
	out="$objdir/ffmerged${pfx}.o"
	"$LD" -r -o "$out" --whole-archive "$a" --no-whole-archive \
		|| { echo "buildffmpeg.sh: partial link of $l failed" >&2; exit 1; }
	[ -f "$out" ] || { echo "buildffmpeg.sh: $out not produced" >&2; exit 1; }
	pfx=$((pfx + 1))
done

n=$(ls "$objdir"/*.o 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || { echo "buildffmpeg.sh: no merged objects produced" >&2; exit 1; }

# Redirect the libc allocator symbols FFmpeg references to our pool-bridge shims
# (libffmpeg/ffalloc.c).  emu replaces global malloc/free/realloc with its own
# pool allocator, but FFmpeg allocates aligned memory with posix_memalign (libc)
# and frees with free() -- which would bind to emu's pool and panic ("alloc:D2B
# ... not in pools") on a pointer the pool never produced.  Rewriting these three
# names in the MERGED FFMPEG OBJECTS ONLY (not emu, not the Inferno glue) routes
# every av_malloc/av_free/av_realloc through ffshim_*, which allocate and free
# consistently from emu's pool with the 16-byte alignment av_malloc expects.
# The symbols actually referenced were confirmed with `nm obj/*.o` to be exactly:
# posix_memalign, free, realloc (everything else is av_* funnelling through them).
OBJCOPY=${OBJCOPY:-objcopy}
if ! command -v "$OBJCOPY" >/dev/null 2>&1; then
	echo "buildffmpeg.sh: $OBJCOPY not found; need objcopy to redirect FFmpeg's" >&2
	echo "  allocator symbols onto emu's pool (set OBJCOPY=... if it is named otherwise)" >&2
	exit 1
fi
for o in "$objdir"/*.o; do
	"$OBJCOPY" \
		--redefine-sym posix_memalign=ffshim_posix_memalign \
		--redefine-sym free=ffshim_free \
		--redefine-sym realloc=ffshim_realloc \
		"$o" || { echo "buildffmpeg.sh: objcopy allocator redirect failed on $o" >&2; exit 1; }
done

# Stable, version-independent name for the unpacked tree so the mkfile's ffwrap.c
# include path (-Iffmpeg) need not know the version.
rm -f "$here/ffmpeg"
ln -s "ffmpeg-$ver" "$here/ffmpeg"

echo "buildffmpeg.sh: ffmpeg $ver static libs ready ($n objects in obj/)"
