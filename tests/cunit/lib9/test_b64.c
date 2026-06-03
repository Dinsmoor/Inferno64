/* lib9 base64: enc64 / dec64 (RFC 4648 test vectors + round-trip). */
#include "lib9.h"
#include "cunit.h"

static void
test_enc64(void)
{
	char o[32];
	enc64(o, sizeof o, (uchar*)"", 0);       CKSTR(o, "");
	enc64(o, sizeof o, (uchar*)"f", 1);      CKSTR(o, "Zg==");
	enc64(o, sizeof o, (uchar*)"fo", 2);     CKSTR(o, "Zm8=");
	enc64(o, sizeof o, (uchar*)"foo", 3);    CKSTR(o, "Zm9v");
	enc64(o, sizeof o, (uchar*)"foob", 4);   CKSTR(o, "Zm9vYg==");
	enc64(o, sizeof o, (uchar*)"fooba", 5);  CKSTR(o, "Zm9vYmE=");
	enc64(o, sizeof o, (uchar*)"foobar", 6); CKSTR(o, "Zm9vYmFy");
}

static void
test_dec64(void)
{
	uchar o[32];
	int n;
	n = dec64(o, sizeof o, "Zm9vYmFy", 8); o[n] = 0;
	CKEQ(n, 6); CKSTR((char*)o, "foobar");
	n = dec64(o, sizeof o, "Zg==", 4);     o[n] = 0;
	CKEQ(n, 1); CKSTR((char*)o, "f");
}

static void
test_roundtrip(void)
{
	uchar in[200], back[200];
	char enc[400];
	int i, n;
	for(i = 0; i < (int)sizeof in; i++)
		in[i] = (uchar)(i*7 + 1);
	n = enc64(enc, sizeof enc, in, sizeof in);
	CK(n > 0);
	n = dec64(back, sizeof back, enc, n);
	CKEQ(n, sizeof in);
	CKMEM(back, in, sizeof in);
}

CUNIT_MAIN("lib9/b64", test_enc64, test_dec64, test_roundtrip)
