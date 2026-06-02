implement LoaderTest;

#
# Avenue 5: debug/reflect via $Loader (runtime module introspection + rebuild).
# This is the Limbo-level exercise of the libinterp/loader.c LP64 fixes:
#   - ifetch must recover branch/call targets from the full 8-byte Inst* (the
#     brunpatch fix); a truncated target makes newmod's brpatch reject it.
#   - newmod must zero the Module so teardown (freemod/destroylinks) doesn't
#     walk garbage 8-byte pointers; destroylinks must tolerate ext==nil.
# We load a real module as a generic Nilmod, read out its instructions, type
# descriptors and external link table, fabricate a fresh module from them with
# newmod/tnew/dnew/ext, re-fetch the rebuilt module's instructions and require a
# byte-for-byte match, then drop it and force GC to prove clean teardown.
#
include "sys.m";
include "draw.m";
include "loader.m";
include "testing.m";

sys: Sys;
loader: Loader;
t: Testing;

Inst: import Loader;

LoaderTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

TARGET: con "/dis/echo.dis";

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	loader = load Loader Loader->PATH;
	t = load Testing Testing->PATH;
	if(loader == nil){
		sys->print("not ok 1 - load $Loader (%r)\n1..1\n");
		return;
	}
	t->init();

	# --- introspect a real, branch-containing module ---
	mp := load Nilmod TARGET;
	t->ok(mp != nil, "load module as Nilmod");
	if(mp == nil){
		t->summary();
		return;
	}

	insts := loader->ifetch(mp);
	tds := loader->tdesc(mp);
	lks := loader->link(mp);
	t->ok(len insts > 0, "ifetch returned instructions");
	t->ok(len tds > 0, "tdesc returned type descriptors");
	t->ok(len lks > 0, "link returned external entry points");

	# (Branch-target validity is checked indirectly below: newmod's brpatch
	# rejects any out-of-range target, and the byte-for-byte round-trip
	# confirms every target survives ifetch -> newmod -> ifetch unchanged.
	# We can't range-check dst per-instruction here because only branch/call/
	# spawn ops carry an index in dst; other ops carry a raw data immediate.)

	# --- rebuild the module from its parts ---
	data := loader->dnew(tds[0].size, tds[0].map);
	t->ok(data != nil, "dnew module data segment");

	nm := loader->newmod("rebuilt", tds[0].size, len lks, insts, data);
	# This is the headline assertion: newmod runs brpatch on every branch, so
	# success means ifetch handed back correct full-width targets.
	t->ok(nm != nil, "newmod rebuilt module (branch targets valid)");
	if(nm == nil){
		sys->print("# newmod failed: %r\n");
		t->summary();
		return;
	}

	# register the remaining type descriptors (tds[0] became type[0] already)
	idxok := 1;
	for(i := 1; i < len tds; i++){
		idx := loader->tnew(nm, tds[i].size, tds[i].map);
		if(idx != i)
			idxok = 0;
	}
	t->ok(idxok, "tnew registered frame types with sequential indices");

	# wire each external entry point to its pc + frame type
	extok := 1;
	for(i = 0; i < len lks; i++)
		if(loader->ext(nm, i, lks[i].pc, lks[i].tdesc) < 0)
			extok = 0;
	t->ok(extok, "ext wired all entry points");

	# --- faithful round-trip: rebuilt instructions must match the original ---
	insts2 := loader->ifetch(nm);
	t->eqi(big len insts2, big len insts, "rebuilt instruction count matches");
	same := (len insts2 == len insts);
	if(same)
		for(i = 0; i < len insts; i++){
			a := insts[i];
			b := insts2[i];
			if(a.op != b.op || a.addr != b.addr || a.src != b.src
					|| a.dst != b.dst || a.mid != b.mid){
				same = 0;
				sys->print("# mismatch at inst %d\n", i);
			}
		}
	t->ok(same, "rebuilt instructions byte-for-byte identical");

	# --- error path: newmod with nil parameters is a catchable failure ---
	badok := 0;
	{
		bad := loader->newmod("bad", 0, 0, nil, nil);
		badok = (bad == nil);
	}exception{
	"*" =>
		badok = 1;
	}
	t->ok(badok, "newmod rejects nil parameters without crashing");

	# --- teardown: drop the rebuilt module and force GC (clean-free fixes) ---
	nm = nil;
	data = nil;
	insts = nil;
	insts2 = nil;
	churn();
	t->ok(1, "GC after dropping rebuilt module did not crash");

	t->summary();
}

# allocate and discard to provoke GC sweeps of the freed module's heap
churn()
{
	for(i := 0; i < 2000; i++){
		junk := array[512] of byte;
		junk[0] = byte i;
		junk = nil;
	}
}
