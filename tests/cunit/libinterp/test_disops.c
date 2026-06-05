/*
 * libinterp .dis decoders (disops.c): operand(), disw(), canontod().
 * These parse every .dis module, and were LP64-touched -- disw must return a
 * clean 32-bit value (no sign-extension into bits 32..63 of a 64-bit ulong),
 * and canontod must reassemble a double from two *32-bit* halves.
 */
#include "lib9.h"
#include "cunit.h"

extern int    operand(uchar**);
extern ulong  disw(uchar**);
extern double canontod(ulong[2]);

static void
test_operand_1byte(void)
{
	uchar a[] = { 0x05 }, *p = a;
	CKEQ(operand(&p), 5);   CKEQ(p - a, 1);
	{ uchar b[] = { 0x3f }; p = b; CKEQ(operand(&p), 63); }
	{ uchar b[] = { 0x40 }; p = b; CKEQ(operand(&p), -64); }  /* sign-extended */
	{ uchar b[] = { 0x7f }; p = b; CKEQ(operand(&p), -1); }
}

static void
test_operand_2byte(void)
{
	uchar a[] = { 0x80, 0x01 }, *p = a;
	CKEQ(operand(&p), 1);    CKEQ(p - a, 2);
	{ uchar b[] = { 0x81, 0x02 }; p = b; CKEQ(operand(&p), 0x102); }
}

static void
test_operand_4byte(void)
{
	uchar a[] = { 0xc1, 0x02, 0x03, 0x04 }, *p = a;
	CKEQ(operand(&p), 0x01020304);   CKEQ(p - a, 4);
	{ uchar b[] = { 0xc0, 0x00, 0x01, 0x02 }; p = b; CKEQ(operand(&p), 0x0102); }
}

static void
test_disw(void)
{
	uchar a[] = { 0xde, 0xad, 0xbe, 0xef }, *p = a;
	CKEQX(disw(&p), 0xdeadbeefUL);   CKEQ(p - a, 4);
	/* the LP64 trap: a high top byte must NOT sign-extend into bits 32..63 */
	{ uchar b[] = { 0xff, 0xff, 0xff, 0xff }; p = b; CKEQX(disw(&p), 0xffffffffUL); }
	{ uchar b[] = { 0x00, 0x00, 0x00, 0x01 }; p = b; CKEQX(disw(&p), 1); }
}

static void
test_canontod(void)
{
	/* split a known double into hi/lo 32-bit words (the .dis word order is
	 * v[0]=high, v[1]=low) and check canontod rebuilds it exactly */
	double want[] = { 3.141592653589793, -2.5, 1e300, 0.0 };
	int i;
	for(i = 0; i < nelem(want); i++){
		uvlong bits;
		ulong v[2];
		double got;
		memmove(&bits, &want[i], sizeof bits);
		v[0] = (ulong)(bits >> 32);
		v[1] = (ulong)(bits & 0xffffffffUL);
		got = canontod(v);
		CK(got == want[i]);
	}
}

CUNIT_MAIN("libinterp/disops",
	test_operand_1byte, test_operand_2byte, test_operand_4byte,
	test_disw, test_canontod)
