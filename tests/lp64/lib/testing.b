implement Testing;

#
# Minimal TAP-style assertion helper for the LP64 headless test suites.
# Each test program loads its own instance, so the pass/fail counters are
# per-program.  Output is consumed by tests/lp64/run.sh.
#
include "sys.m";
include "testing.m";

sys: Sys;

count := 0;
nfail := 0;

init()
{
	sys = load Sys Sys->PATH;
	count = 0;
	nfail = 0;
}

result(cond: int, name: string)
{
	count++;
	if(cond)
		sys->print("ok %d - %s\n", count, name);
	else {
		nfail++;
		sys->print("not ok %d - %s\n", count, name);
	}
}

ok(cond: int, name: string)
{
	result(cond, name);
}

# TAP "ok N # SKIP reason": the assertion does not apply to this
# configuration (e.g. a feature that is mutually exclusive with the JIT).
# Counts toward the plan as a pass, but is reported as skipped, not run.
skip(name: string, reason: string)
{
	count++;
	sys->print("ok %d - %s # SKIP %s\n", count, name, reason);
}

eqi(got, want: big, name: string)
{
	if(got != want)
		sys->print("# %s: got %bd want %bd\n", name, got, want);
	result(got == want, name);
}

eqr(got, want, eps: real, name: string)
{
	d := got - want;
	if(d < 0.0)
		d = -d;
	if(d > eps)
		sys->print("# %s: got %g want %g\n", name, got, want);
	result(d <= eps, name);
}

eqs(got, want, name: string)
{
	if(got != want)
		sys->print("# %s: got %q want %q\n", name, got, want);
	result(got == want, name);
}

summary(): int
{
	sys->print("1..%d\n", count);
	if(nfail)
		sys->print("# FAILED %d of %d\n", nfail, count);
	else
		sys->print("# passed %d\n", count);
	if(nfail)
		return 1;
	return 0;
}
