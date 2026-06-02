implement SelfhostTest;

#
# Avenue 3: self-hosted build.
# Drives the *in-emu* Limbo compiler (/dis/limbo.dis, the LP64 self-hosted
# compiler) to compile a freshly-generated module from source, then loads and
# runs the product through the same VM.  This is the strongest single headless
# stress: it exercises the compiler end-to-end (lexer, type checker, codegen,
# XMAGIC8 .dis emission) plus the loader and cross-module linking of a module
# the VM has never seen before.  A wrong-pointer-width .dis would be rejected
# by the loader (exDiswidth), so a successful load also confirms the magic.
#
include "sys.m";
include "draw.m";
include "sh.m";			# Command module type
include "gen.m";
include "testing.m";

sys: Sys;
t: Testing;

SelfhostTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

SRC: con
	"implement Gen;\n" +
	"include \"gen.m\";\n" +
	"compute(x: int): int\n" +
	"{\n" +
	"\treturn x*x + 1;\n" +
	"}\n" +
	"sumto(n: int): big\n" +
	"{\n" +
	"\ts := big 0;\n" +
	"\tfor(i := 1; i <= n; i++)\n" +
	"\t\ts += big i;\n" +
	"\treturn s;\n" +
	"}\n";

SRCPATH:	con "/tests/lp64/_build/selfhost_gen.b";
DISPATH:	con "/tests/lp64/_build/selfhost_gen.dis";

writefile(path, data: string): string
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("create %s: %r", path);
	b := array of byte data;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("write %s: %r", path);
	return nil;
}

# run /dis/limbo.dis as a Command; return nil on success or the error string
runlimbo(args: list of string): string
{
	limbo := load Command "/dis/limbo.dis";
	if(limbo == nil)
		return sys->sprint("load limbo: %r");
	{
		limbo->init(nil, args);
	}exception e{
	"*" =>
		return e;
	}
	return nil;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	t->init();

	# fresh start
	sys->remove(DISPATH);

	err := writefile(SRCPATH, SRC);
	t->ok(err == nil, "write generated source");
	if(err != nil){
		sys->print("# %s\n", err);
		t->summary();
		return;
	}

	args := "limbo" :: "-I" :: "/module" :: "-I" :: "/tests/lp64/lib"
		:: "-o" :: DISPATH :: SRCPATH :: nil;
	err = runlimbo(args);
	t->ok(err == nil, "in-emu limbo compiled the module");
	if(err != nil){
		sys->print("# limbo error: %s\n", err);
		t->summary();
		return;
	}

	# the compiler must have produced a non-empty .dis
	(ok, d) := sys->stat(DISPATH);
	t->ok(ok >= 0 && d.length > big 0, "produced a non-empty .dis");

	# load and run the freshly-compiled module (also proves XMAGIC8 magic)
	g := load Gen DISPATH;
	t->ok(g != nil, "load freshly-compiled module");
	if(g == nil){
		sys->print("# load failed: %r\n");
		t->summary();
		return;
	}

	t->eqi(big g->compute(6), big 37, "run compiled compute(6) == 37");
	t->eqi(big g->compute(0), big 1, "run compiled compute(0) == 1");
	t->eqi(g->sumto(100), big 5050, "run compiled sumto(100) == 5050");
	t->eqi(g->sumto(100000), big 5000050000, "run compiled sumto(100000) (big result)");

	# recompile a second time to confirm the path is repeatable
	err = runlimbo(args);
	t->ok(err == nil, "recompile is repeatable");

	t->summary();
}
