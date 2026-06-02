implement ModGlobalTest;

#
# Avenue 8: cross-module IMPORTED GLOBAL VARIABLES (LP64 regression).
#
# Regression for the LP64 imported-global codegen bug.  Accessing a variable
# imported from another module (`x: import othermod`) compiles to
#     Oind( Oadd( Oind(module), field_offset ) )
# i.e. load the foreign module's data-segment pointer (Modlink.MP), add the
# global's offset, then load the field.  The compiler typed the inner
# Oind(module) load as `tint` (IBY2WD=4), so on LP64 it emitted a 4-byte movw
# that truncated/sign-extended the 8-byte data pointer; the next deref then
# faulted at e.g. 0xffffffff2c138d00.  In the field this crashed acme and
# charon on launch (`display: import gui`).  Fix: the module-pointer load uses
# the pointer-width, untraced type `tptr` (tbig on LP64, tint on ILP32) ->
# movl/movp, never truncating.  The rest of the suite never caught it because
# it imports funcs and types but never imported global VARIABLES.
#
include "sys.m";
include "draw.m";
include "modglobals.m";
include "testing.m";

sys: Sys;
t: Testing;
mg: ModGlobals;

# Import the global VARIABLES from the loaded ModGlobals instance.  Each use
# below is a foreign-module-data access that forces the Modlink.MP load.
gthing, gname, glist, garr: import mg;

ModGlobalTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	t->init();

	mg = load ModGlobals ModGlobals->PATH;
	if(mg == nil){
		t->ok(0, "load ModGlobals");
		t->summary();
		return;
	}
	mg->setup();

	# Every line here dereferences a value reached through mg's Modlink.MP.
	# Pre-fix, the first such deref segfaulted; now they must all read back
	# the values setup() stored.
	t->ok(gthing != nil, "imported ref global: non-nil");
	t->eqi(big gthing.tag, big 42, "imported ref global: int field");
	t->eqs(gthing.name, "hello", "imported ref global: string field");
	t->eqi(gthing.count, big 100, "imported ref global: big field");
	t->ok(gthing.nextp != nil, "imported ref global: ref field non-nil");
	t->eqs(gthing.nextp.name, "world", "imported ref global: nested deref");
	t->eqi(big gthing.nextp.tag, big 7, "imported ref global: nested int");

	t->eqs(gname, "the-global-name", "imported string global");

	n := 0;
	for(l := glist; l != nil; l = tl l)
		n += hd l;
	t->eqi(big n, big 6, "imported list global: sum 1+2+3");

	t->ok(garr != nil, "imported array global: non-nil");
	t->eqi(big len garr, big 3, "imported array global: len");
	t->eqi(big garr[2], big 30, "imported array global: element");

	t->summary();
}
