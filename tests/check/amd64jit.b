implement Amd64jit;

#
# Bit-identity fixture for the x86-64 Dis JIT (libinterp/comp-amd64.c).
#
# Deterministic output that exercises every natively-compiled amd64 opcode:
# word/byte/big integer add/sub/and/or/xor/mul/div/mod, the word and long
# shifts, int<->real conversions with the interpreter's round-half-away, the
# SSE2 float arithmetic, the six float compare-branches (incl. a NaN), array
# indexing, conditional branches, and cross-function (frame) calls.
#
# The cell (tests/check/amd64jit.sh) runs this under emu -c0 (interpreter) and
# emu -c1 (JIT) and requires byte-identical output.  No self-checking here: the
# interpreter is the reference, the diff is the assertion.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Amd64jit: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};


init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	# ---- word/big/byte multiply, divide, modulo across sign combos ----
	xs := array[] of {-17, 17, -100, 100, 7, -7, 123456, -123456, 1, -1};
	ys := array[] of {5, -5, 3, -3, -2, 2, 1000, -7, -1, 1};
	for(i := 0; i < len xs; i++)
		sys->print("w %d/%d=%d mod=%d mul=%d\n",
			xs[i], ys[i], xs[i]/ys[i], xs[i]%ys[i], xs[i]*ys[i]);

	b := big 1;
	for(i = 0; i < 40; i++)
		b = b * big 3 + big 1;
	sys->print("big b=%bd b/7=%bd bmod7=%bd b*-5=%bd\n", b, b/big 7, b%big 7, b*big(-5));
	nb := big(-9223372036854775807);
	sys->print("bigneg %bd/3=%bd mod3=%bd\n", nb, nb/big 3, nb%big 3);

	p := byte 200; q := byte 7;
	sys->print("byte mul=%d div=%d mod=%d\n", int(p*q), int(p/q), int(p%q));

	# ---- shifts: word arith/logical, big arith/logical ----
	w := int 16r87654321;
	sys->print("w<<5=%x w>>3=%x\n", w<<5, w>>3);
	bw := big 16r0123456789ABCDEF;
	sys->print("bw<<9=%bx bw>>11=%bx\n", bw<<9, bw>>11);

	# ---- SSE2 float arithmetic ----
	f := 3.14159265358979;
	g := 2.71828182845905;
	sys->print("f+g=%.12g f-g=%.12g f*g=%.12g f/g=%.12g -f=%.12g\n",
		f+g, f-g, f*g, f/g, -f);

	# ---- real<->int conversions, round-half-away-from-zero ----
	rs := array[] of {2.5, -2.5, 2.4, -2.4, 2.6, -2.6, 0.5, -0.5,
		100.999, -100.999, 0.0, 4294967296.7, -4294967296.7};
	for(i = 0; i < len rs; i++)
		sys->print("rnd %.4f -> w=%d v=%bd\n", rs[i], int rs[i], big rs[i]);
	for(i = -4; i <= 4; i++)
		sys->print("cvt %d->%.1f big %bd->%.1f\n", i, real i, big i, real big i);

	# ---- float compare-branches, including a NaN row ----
	z := 0.0;
	cs := array[5] of real;
	cs[0] = 1.0; cs[1] = -1.0; cs[2] = 2.0; cs[3] = z/z; cs[4] = 0.0;
	for(i = 0; i < len cs; i++) {
		s := "";
		for(j := 0; j < len cs; j++) {
			if(cs[i] <  cs[j]) s[len s] = 'L';
			if(cs[i] <= cs[j]) s[len s] = 'l';
			if(cs[i] >  cs[j]) s[len s] = 'G';
			if(cs[i] >= cs[j]) s[len s] = 'g';
			if(cs[i] == cs[j]) s[len s] = 'E';
			if(cs[i] != cs[j]) s[len s] = 'n';
			s[len s] = ' ';
		}
		sys->print("cmp[%d] %s\n", i, s);
	}

	# ---- float accumulation loop + a frame call (mandelbrot escape count) ----
	tot := 0;
	for(yy := -12; yy <= 12; yy++) {
		row := "";
		for(xx := -20; xx <= 10; xx++) {
			n := escape(real xx / 10.0, real yy / 10.0);
			tot += n;
			if(n >= 50) row[len row] = '*';
			else if(n >= 10) row[len row] = '.';
			else row[len row] = ' ';
		}
		sys->print("%s\n", row);
	}
	sys->print("escape-total=%d\n", tot);
	sys->print("done\n");
}

# float-heavy leaf function: exercises arithf, cbraf and a real loop in a
# separate frame (so the IMCALL/IFRAME path is on the hot path too).
escape(cx: real, cy: real): int
{
	zx := 0.0;
	zy := 0.0;
	for(n := 0; n < 50; n++) {
		if(zx*zx + zy*zy > 4.0)
			return n;
		t := zx*zx - zy*zy + cx;
		zy = 2.0*zx*zy + cy;
		zx = t;
	}
	return 50;
}
