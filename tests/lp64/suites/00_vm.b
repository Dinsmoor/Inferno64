implement VmTest;

#
# Avenue 0 (foundation): core Dis VM + Limbo language.
# Exercises the data paths most sensitive to the LP64 pointer-width port:
# big (64-bit) constants & arithmetic, real constants/math, strings, lists,
# tuples, arrays (incl. replicate fill), pick-ADTs, and exceptions.
#
include "sys.m";
include "draw.m";
include "math.m";
include "testing.m";

sys: Sys;
math: Math;
t: Testing;

VmTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

# pick-ADT to exercise tagged-union layout on LP64
Shape: adt {
	pick {
	Circle =>	r: real;
	Rect =>		w, h: int;
	Named =>	name: string;
	}
};

area(s: ref Shape): real
{
	pick p := s {
	Circle =>	return 3.14159265358979 * p.r * p.r;
	Rect =>		return real (p.w * p.h);
	Named =>	return real len p.name;
	}
	return -1.0;
}

# exception carrying mixed-alignment args (string,int,big) — the EXLP64 path
boom(n: int)
{
	if(n > 0)
		raise sys->sprint("fail:%d:%bd", n, big n * big 1000000000);
}

# returns the caught exception payload, or "" if nothing was raised
trycatch(): string
{
	{
		boom(7);
		return "";
	}exception e{
	"fail:*" =>
		return e;
	}
	return "unreachable";
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	t = load Testing Testing->PATH;
	if(t == nil) {
		sys->print("not ok 1 - load Testing (%r)\n1..1\n");
		raise "fail:load";
	}
	t->init();

	# --- big / 64-bit constants and arithmetic ---
	t->eqi(big 123456789012, big 123456789012, "big const round-trip");
	t->eqi(big 1 << 40, big 1099511627776, "big shift 1<<40");
	a := big 9000000000;
	b := big 3;
	t->eqi(a * b, big 27000000000, "big multiply");
	t->eqi((big 1 << 63) - big 1, big 9223372036854775807, "big max");
	t->eqi(16r7fffffffffffffff, big 9223372036854775807, "big hex const");
	# low word has bit 31 set: the DEFL sign-extend bug
	t->eqi(big 16rFFFFFFFF, big 4294967295, "big 0xFFFFFFFF zero-extend");

	# --- int arithmetic ---
	t->eqi(big (2 + 2 * 3), big 8, "int precedence");
	t->eqi(big (-7 % 3), big -1, "int modulo sign");
	t->eqi(big (1 << 30), big 1073741824, "int shift");

	# --- reals: constants (the dtocanon union bug) + math ---
	t->eqr(1.5e300 / 1.0e150, 1.5e150, 1.0e144, "real big constant");
	t->eqr(math->sqrt(2.0), 1.4142135623730951, 1e-12, "sqrt 2");
	t->eqr(math->sin(0.0), 0.0, 1e-12, "sin 0");
	t->eqr(math->pow(2.0, 10.0), 1024.0, 1e-9, "pow 2^10");
	t->eqr(real big 1000000000000, 1.0e12, 1.0, "big->real");

	# --- strings ---
	s := "héllo, 世界";			# multibyte UTF-8
	t->eqi(big len s, big 9, "utf8 rune length");
	t->eqs(s[0:5], "héllo", "utf8 slice");
	(n, toks) := sys->tokenize("a b c d", " ");
	t->eqi(big n, big 4, "tokenize count");
	t->eqs(hd toks, "a", "tokenize head");

	# --- lists ---
	l := 1 :: 2 :: 3 :: 4 :: 5 :: nil;
	sum := 0;
	for(ll := l; ll != nil; ll = tl ll)
		sum += hd ll;
	t->eqi(big sum, big 15, "list sum");
	t->eqi(big len l, big 5, "list length");

	# list of pointers (string) to stress GC tracing of list elems
	sl := "one" :: "two" :: "three" :: nil;
	t->eqs(hd tl sl, "two", "list of string");

	# --- tuples ---
	(x, y, z) := (10, "mid", 99.5);
	t->eqi(big x, big 10, "tuple unpack int");
	t->eqr(z, 99.5, 1e-9, "tuple unpack real");
	t->eqs(y, "mid", "tuple unpack string");

	# --- arrays incl. replicate fill (the arraydefault bug) ---
	ar := array[5] of int;
	for(i := 0; i < len ar; i++)
		ar[i] = i * i;
	t->eqi(big ar[4], big 16, "array index");
	# replicate fill of a real array (faulted pre-fix)
	fr := array[4] of {* => 2.5};
	t->eqr(fr[0] + fr[3], 5.0, 1e-12, "replicate real fill");
	# replicate fill of a pointer (string) array
	fs := array[3] of {* => "x"};
	t->eqs(fs[2], "x", "replicate ptr fill");
	# array of big
	ab := array[3] of {* => big 1 << 40};
	t->eqi(ab[1], big 1099511627776, "replicate big fill");

	# --- pick ADTs (tagged-union dispatch) ---
	shapes := array[] of {
		ref Shape.Circle(2.0),
		ref Shape.Rect(3, 4),
		ref Shape.Named("hello"),
	};
	t->eqr(area(shapes[0]), 12.566370614, 1e-6, "pick Circle area");
	t->eqr(area(shapes[1]), 12.0, 1e-9, "pick Rect area");
	t->eqr(area(shapes[2]), 5.0, 1e-9, "pick Named area");

	# --- exceptions (data-carrying, mixed alignment) ---
	got := trycatch();
	t->ok(got != "", "exception caught");
	t->eqs(got, "fail:7:7000000000", "exception payload string");

	# --- exponentiation (**) over int/big/real ---
	t->eqi(big (3 ** 4 * 2), big 162, "int ** precedence");
	t->eqi(big 2 ** 30, big 1073741824, "big ** 2^30");
	t->eqi(big 2 ** 62, big 4611686018427387904, "big ** 2^62");
	t->eqr(2.0 ** 10, 1024.0, 1e-9, "real ** 2^10");

	# --- fixed-point types (underlying int, stays IBY2WD on LP64) ---
	fp := fpconv();
	t->eqr(fp, 8.0, 1e-3, "fixed-point add->real");

	# --- function references (ref fn) ---
	f := cmp;				# bind a reference to cmp
	t->eqi(big f("abc", "abd"), big -1, "fnref cmp lt");
	t->eqi(big apply(f, "z", "a"), big 1, "fnref passed as arg");

	t->summary();
}

# fixed-point arithmetic, returning real for comparison
fpconv(): real
{
	x: fixed(2.0**-16);
	y: fixed(2.0**-16);
	x = fixed(2.0**-16)(3.25);
	y = fixed(2.0**-16)(4.75);
	z := x + y;
	return real z;
}

cmp(s1, s2: string): int
{
	if(s1 < s2)
		return -1;
	if(s1 > s2)
		return 1;
	return 0;
}

apply(f: ref fn(a, b: string): int, s1, s2: string): int
{
	return f(s1, s2);
}
