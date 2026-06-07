implement Jitfp;

#
# Floating-point JIT exercise + micro-benchmark.
#
# Prints deterministic FP results to stdout (the "value" channel) and a single
# timing line to stderr.  Run the SAME .dis under the interpreter (emu -c0) and
# the JIT (emu -c1): identical stdout proves the native FP path computes the
# same bits as the interpreter; the stderr ms line gives the speedup.
#
# Every value below is derived from a RUNTIME operand (array element / variable
# / loop counter) so the Limbo compiler cannot constant-fold the FP op away —
# otherwise the conversion/arith would happen in the compiler, not in Dis.
#
# usage: fp.dis [iters]            (default 4_000_000)
#

include "sys.m";
include "draw.m";

sys: Sys;

Jitfp: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;

	iters := 4000000;
	if(args != nil){
		args = tl args;
		if(args != nil)
			iters = int hd args;
	}

	# --- arithmetic: IADDF / ISUBF / IMULF / IDIVF / INEGF ---
	# operands from a runtime array so nothing folds at compile time
	o := array[] of {3.5, 1.25, -2.0, 7.0};
	pr("addf", o[0] + o[1]);
	pr("subf", o[0] - o[1]);
	pr("mulf", o[0] * o[1]);
	pr("divf", o[0] / o[1]);
	pr("negf", -o[2]);
	pr("chain", (o[0]*o[1] - o[2]) / (o[3] + o[1]));

	# --- int <-> real: ICVTWF (int->real), ICVTFW (real->int, round) ---
	iv := array[] of {7, -7, 3, 4};
	pr("cvtwf", real iv[0] / o[1]);			# 7 / 1.25
	# round-half-away-from-zero: the interpreter's (f<0?f-.5:f+.5) rule
	rv := array[] of {2.5, 2.4, 2.6, -2.5, -2.4, -2.6};
	for(k := 0; k < len rv; k++)
		pri(sys->sprint("cvtfw[%d]", k), int rv[k]);

	# --- big <-> real: ICVTLF (big->real), ICVTFL (real->big) ---
	bg := array[] of {big 1000000000000, big 5};
	pr("cvtlf", real bg[0] / 1.0e6);
	bv := array[] of {1.0e12 + 0.5, -1.0e12 - 0.5, 123456.5};
	for(k = 0; k < len bv; k++)
		prb(sys->sprint("cvtfl[%d]", k), big bv[k]);

	# --- comparisons: IBEQF/IBNEF/IBLTF/IBLEF/IBGTF/IBGEF ---
	pri("cmp(a,b)", cmpmask(o[0], o[1]));		# 3.5 vs 1.25
	pri("cmp(b,a)", cmpmask(o[1], o[0]));
	pri("cmp(a,a)", cmpmask(o[0], o[0]));

	# --- hot loop: pure-FP series + comparison-driven counter ---
	t0 := sys->millisec();
	(series, hits) := hot(iters);
	dt := sys->millisec() - t0;

	pr("series", series);
	pri("hits", hits);

	# timing on stderr: kept off stdout so the value diff stays clean
	sys->fprint(sys->fildes(2), "TIME iters=%d ms=%d\n", iters, dt);
}

# Bit-pack the six ordered relations (all IBxxF opcodes) into one int so a
# single value captures every comparison outcome.
cmpmask(x, y: real): int
{
	m := 0;
	if(x <  y) m |= 1<<0;
	if(x <= y) m |= 1<<1;
	if(x >  y) m |= 1<<2;
	if(x >= y) m |= 1<<3;
	if(x == y) m |= 1<<4;
	if(x != y) m |= 1<<5;
	return m;
}

# Leibniz series for pi (pure +,-,*,/, and ICVTWF on the counter) plus a
# golden-ratio low-discrepancy walk gated by FP compares (IBGEF / IBLTF) so the
# hot path stresses arithmetic and branches together.
hot(iters: int): (real, int)
{
	sum := 0.0;
	sign := 1.0;
	x := 0.0;
	hits := 0;
	for(k := 0; k < iters; k++){
		denom := real (2*k + 1);		# ICVTWF
		sum += sign / denom;			# IDIVF, IADDF
		sign = -sign;				# INEGF

		x += 0.61803398874989;			# IADDF
		if(x >= 1.0)				# IBGEF
			x -= 1.0;			# ISUBF
		if(x * x < 0.25)			# IMULF, IBLTF
			hits++;
	}
	return (4.0 * sum, hits);
}

pr(name: string, v: real)
{
	sys->print("%s = %.17g\n", name, v);
}

pri(name: string, v: int)
{
	sys->print("%s = %d\n", name, v);
}

prb(name: string, v: big)
{
	sys->print("%s = %bd\n", name, v);
}
