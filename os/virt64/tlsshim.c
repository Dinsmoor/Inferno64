/*
 * The libc the vendored mbedTLS expects, over kernel facilities.
 * Compiled with the host's libc *headers* (types and prototypes only,
 * same as the mbedTLS objects themselves) but NOT the kernel's — the
 * few kernel symbols used are declared by hand.
 *
 * string/memory primitives (memcpy, strlen, ...) come from libkern;
 * malloc/free from the kernel pool allocator.  This file adds the
 * stragglers: the snprintf family (mapped onto the Plan 9
 * fmt engine — C-only verbs like %u degrade in diagnostic strings,
 * nothing load-bearing uses them), wall-clock time (PL031-backed
 * seconds()), gmtime_r for x509 validity checks, and the entropy hook
 * (MBEDTLS_ENTROPY_HARDWARE_ALT) over virtio-rng with the genrandom
 * fallback.
 */
#include <stddef.h>
#include <stdarg.h>
#include <time.h>

/* kernel (calloc/free come from the pool allocator, os/port/alloc.c) */
void*	memset(void*, int, unsigned long);
long	seconds(void);
void	genrandom(unsigned char*, int);
int	vsnprint(char*, int, char*, va_list);

int
vsnprintf(char *s, size_t n, const char *fmt, va_list ap)
{
	return vsnprint(s, n, (char*)fmt, ap);
}

int
snprintf(char *s, size_t n, const char *fmt, ...)
{
	va_list ap;
	int r;

	va_start(ap, fmt);
	r = vsnprint(s, n, (char*)fmt, ap);
	va_end(ap);
	return r;
}

time_t
time(time_t *tp)
{
	time_t t;

	t = seconds();
	if(tp != NULL)
		*tp = t;
	return t;
}

/* days-from-civil split, Howard Hinnant style; enough tm for x509 */
struct tm*
gmtime_r(const time_t *tp, struct tm *tm)
{
	long long days, secs, era, doe, yoe, doy, mp, y, m, d;

	secs = *tp;
	days = secs / 86400;
	secs %= 86400;
	if(secs < 0){
		secs += 86400;
		days--;
	}
	memset(tm, 0, sizeof(*tm));
	tm->tm_hour = secs / 3600;
	tm->tm_min = (secs % 3600) / 60;
	tm->tm_sec = secs % 60;
	tm->tm_wday = (days + 4) % 7;		/* 1970-01-01 was a Thursday */
	if(tm->tm_wday < 0)
		tm->tm_wday += 7;

	days += 719468;				/* epoch -> 0000-03-01 */
	era = (days >= 0 ? days : days - 146096) / 146097;
	doe = days - era * 146097;
	yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365;
	y = yoe + era * 400;
	doy = doe - (365*yoe + yoe/4 - yoe/100);
	mp = (5*doy + 2) / 153;
	d = doy - (153*mp + 2)/5 + 1;
	m = mp < 10 ? mp + 3 : mp - 9;
	if(m <= 2)
		y++;

	tm->tm_year = y - 1900;
	tm->tm_mon = m - 1;
	tm->tm_mday = d;
	tm->tm_yday = 0;			/* x509 never looks */
	return tm;
}

/*
 * inet_pton: x509_crt.c uses it to decide whether the hostname being
 * verified is an IP literal (matched against iPAddress SANs).  Linux
 * AF numbers, since we compile against the host headers.
 */
enum {
	Afinet	= 2,
	Afinet6	= 10,
};

static int
pton4(const char *src, unsigned char *dst)
{
	unsigned long v;
	int i, c, seen;

	for(i = 0; i < 4; i++){
		if(i > 0){
			if(*src != '.')
				return 0;
			src++;
		}
		v = 0;
		seen = 0;
		while((c = *src) >= '0' && c <= '9'){
			v = v*10 + (c - '0');
			if(v > 255)
				return 0;
			src++;
			seen = 1;
		}
		if(!seen)
			return 0;
		dst[i] = v;
	}
	return *src == 0;
}

static int
hexval(int c)
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

void*	memcpy(void*, const void*, unsigned long);

/* hex groups and "::" only; the embedded-IPv4 form (::ffff:1.2.3.4)
 * is rejected — nobody puts that in a certificate hostname */
static int
pton6(const char *src, unsigned char *dst)
{
	unsigned char buf[16];
	int groups[8], ngroups, gap, i, v, c, digits;

	ngroups = 0;
	gap = -1;
	if(src[0] == ':'){
		if(src[1] != ':')
			return 0;
		src += 2;
		gap = 0;
		if(*src == 0)
			goto fill;
	}
	for(;;){
		if(ngroups >= 8)
			return 0;
		v = 0;
		digits = 0;
		while((c = hexval(*src)) >= 0){
			v = v<<4 | c;
			if(v > 0xffff)
				return 0;
			src++;
			digits++;
		}
		if(digits == 0 || *src == '.')
			return 0;
		groups[ngroups++] = v;
		if(*src == 0)
			break;
		if(*src != ':')
			return 0;
		src++;
		if(*src == ':'){	/* "::" */
			if(gap >= 0)
				return 0;
			gap = ngroups;
			src++;
			if(*src == 0)
				break;
		}
	}
fill:
	for(i = 0; i < ngroups; i++){
		buf[2*i] = groups[i]>>8;
		buf[2*i+1] = groups[i];
	}
	if(gap < 0){
		if(ngroups != 8)
			return 0;
		memcpy(dst, buf, 16);
		return 1;
	}
	if(ngroups >= 8)
		return 0;
	memset(dst, 0, 16);
	memcpy(dst, buf, 2*gap);
	memcpy((unsigned char*)dst + 16 - 2*(ngroups-gap), buf + 2*gap, 2*(ngroups-gap));
	return 1;
}

int
inet_pton(int af, const char *src, void *dst)
{
	switch(af){
	case Afinet:
		return pton4(src, dst);
	case Afinet6:
		return pton6(src, dst);
	}
	return -1;
}

/* aesce.c probes AT_HWCAP for the ARMv8 crypto extensions; claim none
 * and let mbedTLS use its C AES — qemu's emulated AES instructions
 * would not be faster, and 0 is unconditionally safe */
unsigned long
getauxval(unsigned long type)
{
	(void)type;
	return 0;
}

void
explicit_bzero(void *p, size_t n)
{
	memset(p, 0, n);
	__asm__ __volatile__("" :: "r"(p) : "memory");
}

/* mbedtls_ms_time (TLS 1.3 ticket ages) wants CLOCK_MONOTONIC-ish ms */
long long	mseconds(void);	/* devcons.c */

int
clock_gettime(clockid_t clk, struct timespec *ts)
{
	long long ms;

	(void)clk;
	ms = mseconds();
	ts->tv_sec = ms / 1000;
	ts->tv_nsec = (ms % 1000) * 1000000;
	return 0;
}

/* entropy for mbedtls_entropy_func (MBEDTLS_ENTROPY_HARDWARE_ALT) */
int
mbedtls_hardware_poll(void *data, unsigned char *output, size_t len, size_t *olen)
{
	(void)data;
	genrandom(output, len);		/* virtio-rng, xorshift fallback */
	*olen = len;
	return 0;
}
