/*
 * cunit.h -- a tiny, dependency-free unit-test harness for Inferno's C
 * libraries.  Each test file includes "lib9.h" (or the library header under
 * test) FIRST, then this header, defines test functions, and ends with a
 * CUNIT_MAIN(...) listing them.
 *
 * The point of these tests is to exercise the host C code that the LP64 port
 * touched -- formatting, UTF, byte packing, big-number and crypto routines --
 * where a 32/64-bit width mistake silently corrupts a value rather than
 * failing to compile.  So checks compare against known-good results computed
 * independently of the function under test.
 *
 * DUAL-ABI RULE: this tree builds for both the 64-bit (LP64) and 32-bit (ILP32)
 * Dis ABIs, and these tests must pass under either.  Therefore an assertion
 * must NOT assume a width that varies between ABIs:
 *   - `vlong`/`uvlong` are 64-bit on BOTH ABIs -- assert their full 64-bit
 *     behaviour unconditionally (this is where the interesting bugs live).
 *   - `long`/`ulong`/`uintptr`/pointers are 64-bit on LP64 but 32-bit on ILP32
 *     -- gate width-specific expectations on `sizeof(ulong) >= 8` (etc.), or
 *     compare against the value itself (e.g. round-trip a %p through the
 *     formatter and back) rather than a hardcoded width-dependent string.
 * Build flags and widths come from the active arch (see run.sh); never hardcode
 * a compiler, -m32/-m64, or a platform define in a test.
 *
 * Output protocol (parsed by run.sh): each file prints, as its LAST line,
 *   ALLPASS <name>            on success, exit 0
 *   FAILED  <name> <n>        with n failed checks, exit 1
 */
#ifndef CUNIT_H
#define CUNIT_H

#include <stdio.h>

static int cunit_pass;
static int cunit_fail;

#define CK(cond) do { \
	if(cond){ cunit_pass++; } \
	else { cunit_fail++; \
		fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
} while(0)

/* integer equality with a useful message (values widened to vlong) */
#define CKEQ(got, want) do { \
	vlong _g = (vlong)(got), _w = (vlong)(want); \
	if(_g == _w){ cunit_pass++; } \
	else { cunit_fail++; \
		fprintf(stderr, "  FAIL %s:%d: %s == %s  (got %lld, want %lld)\n", \
			__FILE__, __LINE__, #got, #want, _g, _w); } \
} while(0)

/* unsigned/hex equality (values widened to uvlong, reported in hex) */
#define CKEQX(got, want) do { \
	uvlong _g = (uvlong)(got), _w = (uvlong)(want); \
	if(_g == _w){ cunit_pass++; } \
	else { cunit_fail++; \
		fprintf(stderr, "  FAIL %s:%d: %s == %s  (got %#llx, want %#llx)\n", \
			__FILE__, __LINE__, #got, #want, _g, _w); } \
} while(0)

#define CKSTR(got, want) do { \
	const char *_g = (got), *_w = (want); \
	if(_g != nil && _w != nil && strcmp(_g, _w) == 0){ cunit_pass++; } \
	else { cunit_fail++; \
		fprintf(stderr, "  FAIL %s:%d: %s == %s  (got \"%s\", want \"%s\")\n", \
			__FILE__, __LINE__, #got, #want, _g ? _g : "(nil)", _w ? _w : "(nil)"); } \
} while(0)

#define CKMEM(got, want, n) do { \
	if(memcmp((got), (want), (n)) == 0){ cunit_pass++; } \
	else { cunit_fail++; \
		fprintf(stderr, "  FAIL %s:%d: memcmp(%s, %s, %s) != 0\n", \
			__FILE__, __LINE__, #got, #want, #n); } \
} while(0)

typedef void (*cunit_fn)(void);

#define CUNIT_MAIN(name, ...) \
	int main(void){ \
		cunit_fn _tests[] = { __VA_ARGS__ }; \
		int _i, _n = (int)(sizeof(_tests)/sizeof(_tests[0])); \
		for(_i = 0; _i < _n; _i++) _tests[_i](); \
		if(cunit_fail == 0){ printf("ALLPASS %s (%d checks)\n", name, cunit_pass); return 0; } \
		printf("FAILED %s %d\n", name, cunit_fail); return 1; \
	}

#endif
