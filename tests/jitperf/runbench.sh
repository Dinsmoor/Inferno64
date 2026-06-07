#!/usr/bin/env bash
#
# runbench.sh - JIT-vs-interpreter throughput harness for the pure-Limbo STFT
# spectrogram benchmark (tests/jitperf/stft.b).
#
# It compiles stft.b with the LP64 `limbo`, synthesizes a deterministic
# linear-chirp WAV, then runs the SAME .dis under several emu configurations:
#
#   c0       emu -c0      pure interpreter (baseline)
#   c1       emu -c1      Dis JIT (native code)
#   c1B      emu -c1 -B   Dis JIT, array bounds-checks disabled
#
# for two arithmetic kernels:
#
#   float    `real` (IEEE double) butterflies
#   fixed    Q15 fixed-point (32-bit int) butterflies + shifts
#
# For each (kernel, config) it records the in-Limbo steady-state transform time
# (min + median over -iter runs; the timed region is pure-Limbo windowing+FFT+
# magnitude only) and the whole-process wall time (which includes module load +
# JIT compile -- the "choppiness" cost). It then asserts the rendered PNGs are
# byte-identical across configs for a given kernel: the interpreter and the JIT
# must agree bit-for-bit, so this doubles as a JIT-correctness regression.
#
# NOTE: needs a tree built AFTER the $Imageio encode() addition (the bench
# writes a PNG via $Imageio->encode). Run `make all` first. On aarch64 the JIT
# currently punts floating point (SOFTFP, comp-aarch64.c), so the `float`
# kernel is expected to show little JIT speedup until that is un-punted; the
# `fixed` kernel exercises the natively-compiled integer path.
#
# Usage:  tests/jitperf/runbench.sh
#   env knobs: N (FFT size, default 1024), HOP (default N/4), ITER (default 30),
#              SR (chirp sample rate, default 8000), DUR (chirp seconds, 4),
#              KERNELS ("float fixed"), CONFIGS ("c0 c1 c1B").
#
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
case "$(uname -m)" in aarch64|arm64) ARCH=aarch64;; x86_64|amd64) ARCH=amd64;; *) ARCH=$(uname -m);; esac
# Use the full `emu` (not emu-g): the benchmark touches no graphics, but the
# headless emu-g build is currently broken (its config pulls in raster3) and its
# committed binary is stale. The full emu runs this compute-only workload fine
# without a display. DISPLAY is cleared so a stray draw can't hit a live X.
EMU="${EMU:-$ROOT/Linux/$ARCH/bin/emu}"
LIMBO="$ROOT/Linux/$ARCH/bin/limbo"
export DISPLAY=
BUILD="$ROOT/tests/jitperf/_build"
IBUILD="/tests/jitperf/_build"          # same dir, as an inferno path (emu root = $ROOT)
TIMEOUT="${TIMEOUT:-120}"

N="${N:-1024}"
HOP="${HOP:-0}"                          # 0 -> stft.b default (N/4)
ITER="${ITER:-30}"
SR="${SR:-8000}"
DUR="${DUR:-4}"
KERNELS="${KERNELS:-float fixed}"
CONFIGS="${CONFIGS:-c0 c1 c1B}"

[ -x "$EMU" ]   || { echo "missing emu-g ($EMU) - run 'make all' first" >&2; exit 2; }
[ -x "$LIMBO" ] || { echo "missing limbo ($LIMBO) - run 'make all' first" >&2; exit 2; }

mkdir -p "$BUILD"

# --- compile the benchmark ---
if ! out=$("$LIMBO" -I "$ROOT/module" -I "$ROOT/appl/lib" -o "$BUILD/stft.dis" "$ROOT/tests/jitperf/stft.b" 2>&1); then
	echo "FATAL: stft.b failed to compile:" >&2
	echo "$out" >&2
	exit 2
fi

WAV="$IBUILD/chirp.wav"

# emu flags for each named config
cfg_flags() {
	case "$1" in
	c0)  echo "-c0";;
	c1)  echo "-c1";;
	c1B) echo "-c1 -B";;
	*)   echo "-c0";;
	esac
}

# kernel -> stft.b mode flag
kern_flag() { [ "$1" = fixed ] && echo "-fix" || echo ""; }

run_emu() {  # <emu-flags> <program-args...>  ; echoes program stdout
	local flags="$1"; shift
	# shellcheck disable=SC2086
	EMUPOOLCHECK=0 timeout "$TIMEOUT" "$EMU" $flags -r"$ROOT" /dis/sh.dis -c "$*" 2>&1
}

now_ms() { date +%s%3N; }

# --- synthesize the chirp WAV once (does not need the JIT or $Imageio) ---
echo "generating chirp: ${SR} Hz x ${DUR}s -> $BUILD/chirp.wav"
gen=$(run_emu "-c0" "$IBUILD/stft.dis -gen $WAV -sr $SR -dur $DUR")
if [ ! -s "$BUILD/chirp.wav" ]; then
	echo "FATAL: chirp generation failed:" >&2
	echo "$gen" >&2
	exit 2
fi

JSON="$BUILD/results.json"
: > "$JSON"
echo "{" >> "$JSON"
echo "  \"params\": {\"n\": $N, \"hop\": \"${HOP:-N/4}\", \"iter\": $ITER, \"sr\": $SR, \"dur\": $DUR}," >> "$JSON"
echo "  \"runs\": [" >> "$JSON"

printf '\n%-7s %-5s %8s %8s %9s %9s   %s\n' "KERNEL" "CFG" "min_ms" "med_ms" "speedup" "wall_ms" "png"
printf -- '------- ----- -------- -------- --------- ---------   ---\n'

fail=0
firstrun=1
for kern in $KERNELS; do
	kf=$(kern_flag "$kern")
	base_med=""        # c0 median for this kernel, for speedup ratios
	prev_png=""        # first config's png, to diff the rest against
	for cfg in $CONFIGS; do
		flags=$(cfg_flags "$cfg")
		hoparg=""; [ "$HOP" != "0" ] && hoparg="-hop $HOP"
		png="$IBUILD/spec_${kern}_${cfg}.png"
		pngfs="$BUILD/spec_${kern}_${cfg}.png"

		t0=$(now_ms)
		out=$(run_emu "$flags" "$IBUILD/stft.dis $kf -n $N $hoparg -iter $ITER $WAV $png")
		t1=$(now_ms)
		wall=$((t1 - t0))

		line=$(printf '%s\n' "$out" | grep '"min_ms"' | tail -1)
		if [ -z "$line" ]; then
			echo "  !! ${kern}/${cfg}: no result line. emu output:" >&2
			printf '%s\n' "$out" | sed 's/^/     /' >&2
			fail=1
			continue
		fi
		minms=$(printf '%s' "$line" | sed -n 's/.*"min_ms":\([0-9]*\).*/\1/p')
		medms=$(printf '%s' "$line" | sed -n 's/.*"med_ms":\([0-9]*\).*/\1/p')
		csum=$(printf '%s' "$line" | sed -n 's/.*"csum":\([0-9]*\).*/\1/p')

		speed="-"
		if [ "$cfg" = c0 ]; then
			base_med="$medms"
		elif [ -n "$base_med" ] && [ "$medms" -gt 0 ] 2>/dev/null; then
			speed=$(awk "BEGIN{printf \"%.2fx\", $base_med/$medms}")
		fi

		# PNG byte-identity check across configs of the same kernel
		note=""
		if [ -z "$prev_png" ]; then
			prev_png="$pngfs"
		elif [ -f "$prev_png" ] && [ -f "$pngfs" ]; then
			if ! cmp -s "$prev_png" "$pngfs"; then
				note=" DIFFERS!"
				fail=1
			fi
		fi

		printf '%-7s %-5s %8s %8s %9s %9s   %s%s\n' "$kern" "$cfg" "$minms" "$medms" "$speed" "$wall" "spec_${kern}_${cfg}.png" "$note"

		[ "$firstrun" = 1 ] || echo "    ," >> "$JSON"
		firstrun=0
		printf '    {"kernel":"%s","config":"%s","min_ms":%s,"med_ms":%s,"wall_ms":%s,"csum":%s,"speedup":"%s"}' \
			"$kern" "$cfg" "${minms:-0}" "${medms:-0}" "$wall" "${csum:-0}" "$speed" >> "$JSON"
	done
done

echo "" >> "$JSON"
echo "  ]" >> "$JSON"
echo "}" >> "$JSON"

echo
echo "results: $JSON ; spectrograms: $BUILD/spec_*.png"
if [ "$fail" != 0 ]; then
	echo "FAIL: a config produced no result, or interp/JIT PNGs differ (possible JIT miscompile)." >&2
	exit 1
fi
echo "OK: all configs ran; interp/JIT PNGs byte-identical per kernel."
