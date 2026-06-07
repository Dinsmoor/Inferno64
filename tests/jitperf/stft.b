implement Stft;

#
# stft.b -- Short-Time Fourier Transform spectrogram, in PURE LIMBO.
#
# This is the headline JIT/interp throughput benchmark for tests/jitperf.  It
# reads a WAV, frames + Hann-windows it, runs a radix-2 Cooley-Tukey FFT per
# frame, takes magnitudes, and writes an Inferno-colormap PNG spectrogram.
#
# Two arithmetic kernels, selectable at run time:
#   float  (default)  -- `real` (IEEE double) butterflies.
#   -fix              -- Q15 fixed-point (32-bit `int`) butterflies + shifts.
#
# Why two: the aarch64 Dis JIT (libinterp/comp-aarch64.c) compiles integer
# arithmetic to native code but PUNTS all floating point (SOFTFP) -- so the
# fixed-point kernel exercises the natively-compiled path and the float kernel
# (until FP is un-punted) measures the punt ceiling.  Running the SAME .dis
# under `emu -c0` vs `emu -c1` isolates interp-vs-JIT for each kernel.
#
# IMPORTANT for a fair measurement: the timed region is windowing + FFT +
# magnitude only -- all pure Limbo.  WAV decode, dB/colormap, and PNG encode
# (the last is native C, $Imageio) happen OUTSIDE the timed loop.  math->sin/
# cos are called only to PRECOMPUTE the window + twiddle tables, never inside
# the hot loop.  math->sqrt (per bin, native) is the one native call inside the
# timed region; it is identical in count across -c0/-c1 and both kernels, so it
# does not bias the interp-vs-JIT ratio.
#
# Usage:
#   stft -gen FILE [-sr HZ] [-dur SECS]      # synthesize a linear-chirp WAV
#   stft [-fix] [-n N] [-hop H] [-iter K] IN.wav [OUT.png]
#
# A JSON result line is printed to stdout:
#   {"mode":"float","n":1024,"hop":256,"frames":F,"iters":K,
#    "min_ms":M,"med_ms":D,"csum":C,"png":"OUT.png"}
# The csum is a checksum of the rendered RGBA -- it MUST match between -c0 and
# -c1 for a given kernel (a JIT miscompile would change it); the runner also
# diffs the PNG bytes directly.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "imageio.m";
	imageio: Imageio;

Stft: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

QBITS:	con 15;			# Q15 fixed-point fractional bits
QONE:	con 1 << QBITS;		# 32768
FLOORDB: con -80.0;		# spectrogram dynamic-range floor (dB below peak)
MAXFRAMES: con 2000;		# cap image width / work so a huge WAV can't blow up

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	stderr = sys->fildes(2);

	mode := "float";
	n := 1024;
	hop := 0;
	iters := 20;
	srate := 8000;
	dur := 4;
	genpath := "";
	pos: list of string;

	if(argv != nil)
		argv = tl argv;			# drop program name
	while(argv != nil){
		a := hd argv;
		argv = tl argv;
		case a {
		"-fix" =>	mode = "fixed";
		"-gen" =>	(genpath, argv) = nextarg(argv);
		"-n" =>		(s, r) := nextarg(argv); n = int s; argv = r;
		"-hop" =>	(s, r) := nextarg(argv); hop = int s; argv = r;
		"-iter" =>	(s, r) := nextarg(argv); iters = int s; argv = r;
		"-sr" =>	(s, r) := nextarg(argv); srate = int s; argv = r;
		"-dur" =>	(s, r) := nextarg(argv); dur = int s; argv = r;
		* =>		pos = a :: pos;
		}
	}

	# generate-a-WAV mode: synthesize a chirp and exit
	if(genpath != ""){
		err := genchirp(genpath, srate, dur);
		if(err != nil)
			fatal(err);
		sys->print("wrote %s (%d Hz, %d s, linear chirp)\n", genpath, srate, dur);
		return;
	}

	# positional args were pushed in reverse
	infile := "";
	outfile := "";
	pos = rev(pos);
	if(pos != nil){ infile = hd pos; pos = tl pos; }
	if(pos != nil){ outfile = hd pos; }
	if(infile == "")
		fatal("usage: stft [-fix] [-n N] [-hop H] [-iter K] IN.wav [OUT.png]");
	if(outfile == "")
		outfile = "/tmp/spectrogram.png";

	if(!ispow2(n) || n < 2)
		fatal(sys->sprint("FFT size %d is not a power of two", n));
	if(hop <= 0)
		hop = n / 4;			# 75% overlap, matching rspektrum
	if(iters < 1)
		iters = 1;

	imageio = load Imageio Imageio->PATH;
	if(imageio == nil)
		fatal("cannot load $Imageio (need a rebuilt emu)");

	(samples, wsr, rerr) := readwav(infile);
	if(rerr != nil)
		fatal(rerr);
	ns := len samples;

	nf := 1;
	if(ns >= n)
		nf = (ns - n) / hop + 1;
	if(nf > MAXFRAMES)
		nf = MAXFRAMES;

	half := n / 2;

	# --- precompute window + twiddle tables (OUTSIDE the timed region) ---
	hann := array[n] of real;
	hannq := array[n] of int;
	for(i := 0; i < n; i++){
		w := 0.5 * (1.0 - math->cos(2.0 * Math->Pi * real i / real (n - 1)));
		hann[i] = w;
		hannq[i] = int (w * real QONE);
	}
	costab := array[n] of real;
	sintab := array[n] of real;
	cosq := array[n] of int;
	sinq := array[n] of int;
	for(i = 0; i < n; i++){
		ang := 2.0 * Math->Pi * real i / real n;
		costab[i] = math->cos(ang);
		sintab[i] = -math->sin(ang);		# forward transform
		cosq[i] = int (costab[i] * real (QONE - 1));
		sinq[i] = int (sintab[i] * real (QONE - 1));
	}

	# scratch + output, reused across timing iterations
	ref_re := array[n] of real;
	ref_im := array[n] of real;
	fix_re := array[n] of int;
	fix_im := array[n] of int;
	mag := array[nf] of array of real;
	for(i = 0; i < nf; i++)
		mag[i] = array[half] of real;

	fixmode := mode == "fixed";

	# float kernel works on `real` samples; convert once, outside timing
	fsamples: array of real;
	if(!fixmode){
		fsamples = array[ns] of real;
		for(i = 0; i < ns; i++)
			fsamples[i] = real samples[i];
	}

	# --- timed region: run the STFT `iters` times, keep min + median ---
	times := array[iters] of int;
	for(it := 0; it < iters; it++){
		t0 := sys->millisec();
		if(fixmode)
			stftfix(samples, n, hop, nf, hannq, cosq, sinq, fix_re, fix_im, mag);
		else
			stftflt(fsamples, n, hop, nf, hann, costab, sintab, ref_re, ref_im, mag);
		times[it] = sys->millisec() - t0;
	}
	isort(times);
	minms := times[0];
	medms := times[iters / 2];

	# --- render PNG (OUTSIDE the timed region) ---
	(rgba, csum) := colorize(mag, nf, half);
	(png, eerr) := imageio->encode(nf, half, rgba);
	if(eerr != nil)
		fatal("png encode: " + eerr);
	werr := writefile(outfile, png);
	if(werr != nil)
		fatal(werr);

	sys->print("{\"mode\":\"%s\",\"n\":%d,\"hop\":%d,\"sr\":%d,\"frames\":%d,\"iters\":%d,\"min_ms\":%d,\"med_ms\":%d,\"csum\":%d,\"png\":\"%s\"}\n",
		mode, n, hop, wsr, nf, iters, minms, medms, csum, outfile);
}

# ---- the STFT kernels (PURE LIMBO; this is what the JIT either helps or not) ----

# Float (IEEE double) kernel.
stftflt(s: array of real, n, hop, nf: int, hann, costab, sintab, re, im: array of real, mag: array of array of real)
{
	ns := len s;
	half := n / 2;
	for(f := 0; f < nf; f++){
		off := f * hop;
		for(i := 0; i < n; i++){
			x := 0.0;
			if(off + i < ns)
				x = s[off + i] * hann[i];
			re[i] = x;
			im[i] = 0.0;
		}
		fftflt(re, im, n, costab, sintab);
		row := mag[f];
		for(i = 0; i < half; i++){
			rr := re[i];
			ii := im[i];
			row[i] = math->sqrt(rr * rr + ii * ii);
		}
	}
}

# Fixed-point Q15 kernel (32-bit int multiply + arithmetic shift -> the
# natively-JITted opcode path on aarch64).
stftfix(s: array of int, n, hop, nf: int, hann, cwt, swt: array of int, re, im: array of int, mag: array of array of real)
{
	ns := len s;
	half := n / 2;
	for(f := 0; f < nf; f++){
		off := f * hop;
		for(i := 0; i < n; i++){
			x := 0;
			if(off + i < ns)
				x = (s[off + i] * hann[i]) >> QBITS;
			re[i] = x;
			im[i] = 0;
		}
		fftfix(re, im, n, cwt, swt);
		row := mag[f];
		for(i = 0; i < half; i++){
			rr := real re[i];
			ii := real im[i];
			row[i] = math->sqrt(rr * rr + ii * ii);
		}
	}
}

# In-place radix-2 Cooley-Tukey FFT, float.  costab[t]=cos(2pi t/n),
# sintab[t]=-sin(2pi t/n); the stage twiddle for half-size m uses index
# k*(n/len).
fftflt(re, im: array of real, n: int, costab, sintab: array of real)
{
	# decimation-in-time bit-reversal permutation
	j := 0;
	for(i := 1; i < n; i++){
		bit := n >> 1;
		while((j & bit) != 0){
			j ^= bit;
			bit >>= 1;
		}
		j ^= bit;
		if(i < j){
			tr := re[i]; re[i] = re[j]; re[j] = tr;
			ti := im[i]; im[i] = im[j]; im[j] = ti;
		}
	}
	ln := 2;
	while(ln <= n){
		m := ln >> 1;
		tstep := n / ln;
		i := 0;
		while(i < n){
			for(k := 0; k < m; k++){
				tw := k * tstep;
				wr := costab[tw];
				wi := sintab[tw];
				ar := re[i + k + m];
				ai := im[i + k + m];
				tr := ar * wr - ai * wi;
				ti := ar * wi + ai * wr;
				ur := re[i + k];
				ui := im[i + k];
				re[i + k] = ur + tr;
				im[i + k] = ui + ti;
				re[i + k + m] = ur - tr;
				im[i + k + m] = ui - ti;
			}
			i += ln;
		}
		ln <<= 1;
	}
}

# In-place radix-2 Cooley-Tukey FFT, Q15 fixed-point.  Each stage scales its
# outputs by 1/2 (arithmetic >>1) to keep values inside int32 (overall the
# transform is scaled by 1/n, which is harmless -- the spectrogram normalizes
# to the per-run peak).
fftfix(re, im: array of int, n: int, cwt, swt: array of int)
{
	j := 0;
	for(i := 1; i < n; i++){
		bit := n >> 1;
		while((j & bit) != 0){
			j ^= bit;
			bit >>= 1;
		}
		j ^= bit;
		if(i < j){
			tr := re[i]; re[i] = re[j]; re[j] = tr;
			ti := im[i]; im[i] = im[j]; im[j] = ti;
		}
	}
	ln := 2;
	while(ln <= n){
		m := ln >> 1;
		tstep := n / ln;
		i := 0;
		while(i < n){
			for(k := 0; k < m; k++){
				tw := k * tstep;
				wr := cwt[tw];
				wi := swt[tw];
				ar := re[i + k + m];
				ai := im[i + k + m];
				tr := (ar * wr - ai * wi) >> QBITS;
				ti := (ar * wi + ai * wr) >> QBITS;
				ur := re[i + k];
				ui := im[i + k];
				re[i + k]     = (ur + tr) >> 1;
				im[i + k]     = (ui + ti) >> 1;
				re[i + k + m] = (ur - tr) >> 1;
				im[i + k + m] = (ui - ti) >> 1;
			}
			i += ln;
		}
		ln <<= 1;
	}
}

# ---- rendering (outside the timed region) ----

# Map the magnitude matrix to an RGBA image (Inferno colormap, dB-relative to
# the global peak) and return (rgba, checksum).  Low frequency at the bottom.
colorize(mag: array of array of real, w, h: int): (array of byte, int)
{
	maxm := 0.0;
	for(x := 0; x < w; x++){
		row := mag[x];
		for(y := 0; y < h; y++)
			if(row[y] > maxm)
				maxm = row[y];
	}
	if(maxm <= 0.0)
		maxm = 1.0;

	rgba := array[w * h * 4] of byte;
	csum := int 16r811c9dc5;		# FNV-1a seed, 32-bit int wrap
	for(y := 0; y < h; y++){
		bin := h - 1 - y;		# flip: DC at the bottom row
		for(x = 0; x < w; x++){
			m := mag[x][bin];
			t := 0.0;
			if(m > 0.0){
				db := 20.0 * math->log10(m / maxm);
				t = (db - FLOORDB) / (0.0 - FLOORDB);
				if(t < 0.0)
					t = 0.0;
				if(t > 1.0)
					t = 1.0;
			}
			(r, g, b) := inferno(t);
			p := (y * w + x) * 4;
			rgba[p]   = byte r;
			rgba[p+1] = byte g;
			rgba[p+2] = byte b;
			rgba[p+3] = byte 255;
			csum = (csum ^ r) * 16r01000193;
			csum = (csum ^ g) * 16r01000193;
			csum = (csum ^ b) * 16r01000193;
		}
	}
	if(csum < 0)
		csum = -csum;			# print as a positive id
	return (rgba, csum);
}

# Inferno colormap (piecewise-linear, matching rspektrum's CmapInferno).
inferno(t: real): (int, int, int)
{
	r, g, b: real;
	if(t < 0.25){
		u := t / 0.25;
		r = u * 0.5; g = 0.0; b = u * 0.3;
	}else if(t < 0.5){
		u := (t - 0.25) / 0.25;
		r = 0.5 + u * 0.5; g = u * 0.3; b = 0.3 + u * 0.4;
	}else if(t < 0.75){
		u := (t - 0.5) / 0.25;
		r = 1.0; g = 0.3 + u * 0.5; b = 0.7 + u * 0.2;
	}else{
		u := (t - 0.75) / 0.25;
		r = 1.0; g = 0.8 + u * 0.2; b = 0.9 + u * 0.1;
	}
	return (clampc(r), clampc(g), clampc(b));
}

clampc(v: real): int
{
	x := int (v * 255.0);
	if(x < 0)
		x = 0;
	if(x > 255)
		x = 255;
	return x;
}

# ---- WAV synthesis + decode ----

# Write a mono 16-bit PCM linear-chirp WAV (frequency sweeps 0 -> 0.9*Nyquist).
genchirp(path: string, srate, dur: int): string
{
	nsamp := srate * dur;
	datalen := nsamp * 2;
	buf := array[44 + datalen] of byte;
	putstr(buf, 0, "RIFF");
	put4(buf, 4, 36 + datalen);
	putstr(buf, 8, "WAVE");
	putstr(buf, 12, "fmt ");
	put4(buf, 16, 16);
	put2(buf, 20, 1);			# PCM
	put2(buf, 22, 1);			# mono
	put4(buf, 24, srate);
	put4(buf, 28, srate * 2);		# byte rate
	put2(buf, 32, 2);			# block align
	put2(buf, 34, 16);			# bits/sample
	putstr(buf, 36, "data");
	put4(buf, 40, datalen);

	f1 := 0.45 * real srate;		# 0.9 * Nyquist (= srate/2)
	k := f1 / real dur;			# Hz per second
	for(i := 0; i < nsamp; i++){
		tsec := real i / real srate;
		phase := 2.0 * Math->Pi * 0.5 * k * tsec * tsec;
		v := int (0.8 * 32767.0 * math->sin(phase));
		put2(buf, 44 + i * 2, v & 16rffff);
	}
	return writefile(path, buf);
}

# Read a mono/stereo 16-bit PCM WAV; returns (samples, samplerate, err) with
# samples averaged to mono (signed int16 range).
readwav(path: string): (array of int, int, string)
{
	data := readfile(path);
	if(data == nil)
		return (nil, 0, "cannot read " + path);
	if(len data < 44 || string data[0:4] != "RIFF" || string data[8:12] != "WAVE")
		return (nil, 0, path + ": not a RIFF/WAVE file");

	fmt := 0; chans := 1; srate := 0; bits := 0;
	dataoff := 0; datalen := 0;
	o := 12;
	while(o + 8 <= len data){
		id := string data[o:o+4];
		sz := get4(data, o + 4);
		body := o + 8;
		if(id == "fmt " && body + 16 <= len data){
			fmt = get2(data, body);
			chans = get2(data, body + 2);
			srate = get4(data, body + 4);
			bits = get2(data, body + 14);
		}else if(id == "data"){
			dataoff = body;
			datalen = sz;
		}
		o = body + sz + (sz & 1);	# chunks are padded to even length
	}
	if(fmt != 1 || bits != 16)
		return (nil, 0, path + ": only 16-bit PCM supported");
	if(dataoff == 0)
		return (nil, 0, path + ": no data chunk");
	if(chans < 1)
		chans = 1;
	if(dataoff + datalen > len data)
		datalen = len data - dataoff;

	nframe := datalen / (2 * chans);
	out := array[nframe] of int;
	for(i := 0; i < nframe; i++){
		acc := 0;
		for(c := 0; c < chans; c++)
			acc += gets2(data, dataoff + (i * chans + c) * 2);
		out[i] = acc / chans;
	}
	return (out, srate, nil);
}

# ---- little-endian byte helpers ----

get2(b: array of byte, o: int): int
{
	return int b[o] | (int b[o+1] << 8);
}

gets2(b: array of byte, o: int): int
{
	v := get2(b, o);
	if(v >= 16r8000)
		v -= 16r10000;
	return v;
}

get4(b: array of byte, o: int): int
{
	return int b[o] | (int b[o+1] << 8) | (int b[o+2] << 16) | (int b[o+3] << 24);
}

put2(b: array of byte, o, v: int)
{
	b[o]   = byte (v & 16rff);
	b[o+1] = byte ((v >> 8) & 16rff);
}

put4(b: array of byte, o, v: int)
{
	b[o]   = byte (v & 16rff);
	b[o+1] = byte ((v >> 8) & 16rff);
	b[o+2] = byte ((v >> 16) & 16rff);
	b[o+3] = byte ((v >> 24) & 16rff);
}

putstr(b: array of byte, o: int, s: string)
{
	for(i := 0; i < len s; i++)
		b[o + i] = byte s[i];
}

# ---- misc helpers ----

nextarg(argv: list of string): (string, list of string)
{
	if(argv == nil)
		return ("", nil);
	return (hd argv, tl argv);
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

ispow2(n: int): int
{
	return n > 0 && (n & (n - 1)) == 0;
}

isort(a: array of int)			# insertion sort (arrays are tiny)
{
	for(i := 1; i < len a; i++){
		v := a[i];
		j := i - 1;
		while(j >= 0 && a[j] > v){
			a[j+1] = a[j];
			j--;
		}
		a[j+1] = v;
	}
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, dir) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	n := int dir.length;
	if(n <= 0)
		return nil;
	buf := array[n] of byte;
	off := 0;
	while(off < n){
		m := sys->read(fd, buf[off:], n - off);
		if(m <= 0)
			break;
		off += m;
	}
	if(off != n)
		return buf[0:off];
	return buf;
}

writefile(path: string, buf: array of byte): string
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("create %s: %r", path);
	if(sys->write(fd, buf, len buf) != len buf)
		return sys->sprint("write %s: %r", path);
	return nil;
}

fatal(msg: string)
{
	sys->fprint(stderr, "stft: %s\n", msg);
	raise "fail:error";
}
