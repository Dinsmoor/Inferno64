Testing: module
{
	PATH:	con "/tests/lp64/_build/lib/testing.dis";

	init:		fn();
	ok:		fn(cond: int, name: string);
	# TAP "ok N # SKIP reason": pass-but-skipped for inapplicable configs.
	skip:		fn(name: string, reason: string);
	eqi:		fn(got, want: big, name: string);
	eqr:		fn(got, want, eps: real, name: string);
	eqs:		fn(got, want: string, name: string);
	# print "1..N" plan and a summary line; returns 0 if all passed, 1 otherwise.
	summary:	fn(): int;
};
