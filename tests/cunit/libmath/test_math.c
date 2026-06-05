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

CUNIT_MAIN("libmath/math", test_ipow10, test_fdimmaxmin, test_dot_norm, test_iamax)
