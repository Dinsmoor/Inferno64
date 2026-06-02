ModGlobals: module
{
	PATH:	con "/tests/lp64/_build/lib/modglobals.dis";

	Thing: adt {
		tag:   int;
		name:  string;
		count: big;
		nextp: cyclic ref Thing;
	};

	# Module-level GLOBAL VARIABLES (not consts) of pointer-bearing types.
	# Another module that does `gthing, gname, ...: import mg` reaches these
	# by loading THIS module's data-segment pointer (Modlink.MP) and then the
	# field.  On LP64 that data pointer must be loaded pointer-width
	# (movp/movl); a truncating 4-byte movw made the imported value a
	# sign-extended bad pointer and faulted on first deref.  This is the path
	# the rest of the LP64 suite never exercised (it uses imported funcs and
	# types, but not imported global variables) -- the acme/charon crash.
	gthing:  ref Thing;        # ref global       (8-byte ptr on LP64)
	gname:   string;           # string global    (8-byte ptr on LP64)
	glist:   list of int;      # list global      (8-byte ptr on LP64)
	garr:    array of int;     # array global     (8-byte ptr on LP64)

	setup: fn();
};
