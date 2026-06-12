/* libmath: ipow10, BLAS-ish helpers (dot/norm2/iamax), fdim/fmax/fmin. */
#include "lib9.h"
#include "mathi.h"
#include "cunit.h"
#include <math.h>

#define CKNEAR(got, want) do { \
	double _g = (got), _w = (want), _d = _g - _w; \
	if(_d < 0) _d = -_d; \
	if(_d <= 1e-9){ cunit_pass++; } \
	else { cunit_fail++; fprintf(stderr, "  FAIL %s:%d: %s ~= %g (got %g)\n", \
		__FILE__, __LINE__, #got, _w, _g); } \
} while(0)

static void
test_ipow10(void)
{
	CKNEAR(ipow10(0), 1.0);
	CKNEAR(ipow10(3), 1000.0);
	CKNEAR(ipow10(-2), 0.01);
	CKNEAR(ipow10(10), 1e10);
}

static void
test_fdimmaxmin(void)
{
	CKNEAR(fdim(5.0, 3.0), 2.0);
	CKNEAR(fdim(3.0, 5.0), 0.0);
	CKNEAR(fmax(2.0, 3.0), 3.0);
	CKNEAR(fmax(-2.0, -3.0), -2.0);
	CKNEAR(fmin(2.0, 3.0), 2.0);
	CKNEAR(fmin(-2.0, -3.0), -3.0);
}

static void
test_dot_norm(void)
{
	double x[] = { 1.0, 2.0, 3.0 };
	double y[] = { 4.0, 5.0, 6.0 };
	CKNEAR(dot(3, x, y), 32.0);        /* 4 + 10 + 18 */
	CKNEAR(norm2(3, y), sqrt(16.0+25.0+36.0));
}

static void
test_iamax(void)
{
	double v[] = { 1.0, -7.0, 3.0, 2.0 };
	CKEQ(iamax(4, v), 1);              /* index of largest |v| */
}

/* David Gay's dtoa/strtod/g_fmt (the Limbo real<->string path).  These
 * inspect the two 32-bit halves of an IEEE double directly (dtoa.c
 * word0/word1), making them the most byte-order-sensitive code in the
 * portable libs -- run them under the big-endian canary.  g_fmt's
 * contract is the shortest decimal string that round-trips, so
 * strtod(g_fmt(x)) == x must hold bit-exactly. */
extern char	*dtoa(double, int, int, int *, int *, char **);
extern void	freedtoa(char *);
extern char	*g_fmt(char *, double, int);

#define CKROUNDTRIP(x) do { \
	double _x = (x), _y; \
	char _b[64], *_e; \
	g_fmt(_b, _x, 'e'); \
	_y = strtod(_b, &_e); \
	if(_y == _x && *_e == '\0'){ cunit_pass++; } \
	else { cunit_fail++; fprintf(stderr, \
		"  FAIL %s:%d: strtod(g_fmt(%s)) round-trip: \"%s\" -> %.17g\n", \
		__FILE__, __LINE__, #x, _b, _y); } \
} while(0)

static void
test_dtoa_roundtrip(void)
{
	int exp, sign;
	char *end, *digits;

	CKROUNDTRIP(1.0);
	CKROUNDTRIP(0.1);
	CKROUNDTRIP(-2.5);
	CKROUNDTRIP(3.141592653589793);
	CKROUNDTRIP(1e300);
	CKROUNDTRIP(1e-300);
	CKROUNDTRIP(4503599627370497.0);   /* 2^52+1: needs every mantissa bit */

	digits = dtoa(255.5, 2, 5, &exp, &sign, &end);   /* 5 sig digits */
	CKSTR(digits, "2555");
	CKEQ(exp, 3);                      /* 0.2555e3 */
	CKEQ(sign, 0);
	freedtoa(digits);

	digits = dtoa(-0.5, 2, 5, &exp, &sign, &end);
	CKSTR(digits, "5");
	CKEQ(exp, 0);
	CKEQ(sign, 1);
	freedtoa(digits);
}

CUNIT_MAIN("libmath/math", test_ipow10, test_fdimmaxmin, test_dot_norm, test_iamax, test_dtoa_roundtrip)
