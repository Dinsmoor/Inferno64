implement ModGlobals;

include "sys.m";
include "modglobals.m";

setup()
{
	gthing = ref Thing(42, "hello", big 100, nil);
	gthing.nextp = ref Thing(7, "world", big 999, nil);
	gname = "the-global-name";
	glist = 1 :: 2 :: 3 :: nil;
	garr = array[3] of {10, 20, 30};
}
