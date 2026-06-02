implement ExceptTest;

#
# Avenue 7: exception unwinding across non-matching handlers (LP64 regression).
#
# Regression for the LP64 exception-unwind bug: handler() (emu/port/exception.c)
# used a 32-bit NOPC sentinel (0xffffffff), but the "no handler" terminator
# stored in Except.pc is operand()'s -1, which sign-extends to the full 64-bit
# 0xffffffffffffffff on LP64.  The mismatch made a falling-through exception
# look like a real handler at pc -1, so the VM jumped to prog-1 and raised
# "illegal dis instruction" instead of propagating.  Symptom in the field:
# `kill 99999` (which does `raise "fail:..."`) broke the shell, taking out
# wm/wm's wmsetup/plumber.  These tests force the fall-through path that the
# fix repairs: a frame WITH an exception block whose patterns do NOT match the
# raised exception, so handler() must consult the NOPC terminator and keep
# unwinding to an outer (or cross-module) catcher.
#
include "sys.m";
include "draw.m";
include "exraise.m";
include "testing.m";

sys: Sys;
t: Testing;
exraise: Exraise;

ExceptTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

# raise an exception with no local handler at all
leaf(pat: string)
{
	raise pat;
}

# local handler whose single arm does NOT match -> NOPC fall-through
oneNonMatch(pat: string): string
{
	{
		leaf(pat);
	} exception e {
	"never:*" =>
		return "WRONG-never";
	}
	return "NOTREACHED";
}

# two stacked non-matching handlers -> two NOPC fall-throughs
twoNonMatch(pat: string): string
{
	{
		x := oneNonMatch(pat);
		return "WRONG-inner-returned:" + x;
	} exception e {
	"alsonever:*" =>
		return "WRONG-alsonever";
	}
	return "NOTREACHED";
}

# a handler with a catch-all "*" arm (terminator carries a real pc, not NOPC)
catchAll(pat: string): string
{
	{
		leaf(pat);
	} exception e {
	"specific:*" =>
		return "specific:" + e;
	* =>
		return "star-taken";	# `e` is typed `exception` (not string) in a `*` arm
	}
	return "NOTREACHED";
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	exraise = load Exraise Exraise->PATH;
	t->init();

	t->ok(exraise != nil, "load Exraise helper module");

	# ---- single-frame fall-through, caught one level out ----
	caught := "NONE";
	{
		x := oneNonMatch("boom:one");
		caught = "WRONG-returned:" + x;
	} exception e {
	"boom:*" =>
		caught = e;
	}
	t->eqs(caught, "boom:one", "fall-through one non-matching handler, caught outside");

	# ---- two stacked non-matching frames, caught two levels out ----
	caught = "NONE";
	{
		twoNonMatch("boom:two");
	} exception e {
	"boom:*" =>
		caught = e;
	}
	t->eqs(caught, "boom:two", "fall-through two stacked non-matching handlers");

	# ---- a matching catch-all still works (terminator pc is real, not NOPC) ----
	t->eqs(catchAll("anything:here"), "star-taken", "catch-all star arm taken");
	t->eqs(catchAll("specific:x"), "specific:specific:x", "specific arm beats star");

	# ---- the "fail:" convention, exactly what kill/commands raise ----
	caught = "NONE";
	{
		oneNonMatch("fail:nothing killed");
	} exception e {
	"fail:*" =>
		caught = e;
	}
	t->eqs(caught, "fail:nothing killed", "fail: convention propagates (the kill 99999 case)");

	# ---- CROSS-MODULE unwind: raise inside Exraise, catch here ----
	# This is structurally the kill->shell path: an exception leaves a loaded
	# module across the mcall boundary into its caller's handler.
	caught = "NONE";
	{
		exraise->boom("xmod:direct");
	} exception e {
	"xmod:*" =>
		caught = e;
	}
	t->eqs(caught, "xmod:direct", "cross-module raise caught in caller");

	# cross-module raise that ALSO falls through a non-matching handler in the
	# helper module before unwinding back to us (double NOPC + module switch).
	caught = "NONE";
	{
		exraise->boomthrough("xmod:through");
	} exception e {
	"xmod:*" =>
		caught = e;
	}
	t->eqs(caught, "xmod:through", "cross-module fall-through unwinds to caller");

	# ---- after all that unwinding, the proc is healthy and keeps running ----
	t->ok(1, "interpreter still executing after exception storm");

	t->summary();
}
