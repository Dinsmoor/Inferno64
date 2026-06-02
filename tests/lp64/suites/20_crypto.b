implement CryptoTest;

#
# Avenue 2: crypto + big-number.
# Keyring message digests against published test vectors (one-shot and
# incremental), AES/DES CBC encrypt->decrypt round-trips, and IPint
# infinite-precision arithmetic (the libmp port, which on aarch64/amd64 uses
# the C port/ fallback — its LP64 correctness is otherwise unverified).
#
include "sys.m";
include "draw.m";
include "keyring.m";
include "ipints.m";
include "testing.m";

sys: Sys;
kr: Keyring;
ip: IPints;
IPint: import ip;
t: Testing;

CryptoTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

hex(d: array of byte): string
{
	s := "";
	for(i := 0; i < len d; i++)
		s += sys->sprint("%2.2ux", int d[i]);
	return s;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	ip = load IPints IPints->PATH;
	t = load Testing Testing->PATH;
	t->init();

	abc := array of byte "abc";

	# --- digests, one-shot, published vectors ---
	md5d := array[Keyring->MD5dlen] of byte;
	kr->md5(abc, len abc, md5d, nil);
	t->eqs(hex(md5d), "900150983cd24fb0d6963f7d28e17f72", "md5(\"abc\")");

	sha1d := array[Keyring->SHA1dlen] of byte;
	kr->sha1(abc, len abc, sha1d, nil);
	t->eqs(hex(sha1d), "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1(\"abc\")");

	sha256d := array[Keyring->SHA256dlen] of byte;
	kr->sha256(abc, len abc, sha256d, nil);
	t->eqs(hex(sha256d),
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		"sha256(\"abc\")");

	# empty-string vectors
	md5e := array[Keyring->MD5dlen] of byte;
	kr->md5(array[0] of byte, 0, md5e, nil);
	t->eqs(hex(md5e), "d41d8cd98f00b204e9800998ecf8427e", "md5(\"\")");

	# --- digest incremental == one-shot ---
	st := kr->sha1(array of byte "a", 1, nil, nil);
	st = kr->sha1(array of byte "b", 1, nil, st);
	inc := array[Keyring->SHA1dlen] of byte;
	kr->sha1(array of byte "c", 1, inc, st);
	t->eqs(hex(inc), hex(sha1d), "sha1 incremental == one-shot");

	# --- AES-CBC encrypt then decrypt round-trips ---
	key := array[16] of byte;
	for(i := 0; i < 16; i++)
		key[i] = byte (i + 1);
	plain := array of byte "sixteen.bytes!!!";	# exactly one AES block
	t->eqi(big len plain, big 16, "AES plaintext is one block");

	buf := array[len plain] of byte;
	buf[0:] = plain;
	es := kr->aessetup(key, ivec());
	kr->aescbc(es, buf, len buf, Keyring->Encrypt);
	enc := array[len buf] of byte;
	enc[0:] = buf;
	t->ok(!samebytes(enc, plain), "AES ciphertext differs from plaintext");

	ds := kr->aessetup(key, ivec());
	kr->aescbc(ds, buf, len buf, Keyring->Decrypt);
	t->ok(samebytes(buf, plain), "AES decrypt recovers plaintext");

	# --- DES-CBC round-trip ---
	dk := array[8] of byte;
	for(i = 0; i < 8; i++)
		dk[i] = byte (16r10 + i);
	dplain := array of byte "8bytes!!";		# one DES block
	dbuf := array[len dplain] of byte;
	dbuf[0:] = dplain;
	des1 := kr->dessetup(dk, ivec8());
	kr->descbc(des1, dbuf, len dbuf, Keyring->Encrypt);
	des2 := kr->dessetup(dk, ivec8());
	kr->descbc(des2, dbuf, len dbuf, Keyring->Decrypt);
	t->ok(samebytes(dbuf, dplain), "DES decrypt recovers plaintext");

	# --- IPint: infinite-precision integer arithmetic (libmp) ---
	t->eqi(big IPint.inttoip(42).iptoint(), big 42, "IPint inttoip/iptoint");

	a := IPint.inttoip(1000000);
	prod := a.mul(a);				# 10^12, overflows a 32-bit int
	t->eqs(prod.iptostr(10), "1000000000000", "IPint multiply 10^6 * 10^6");

	big1 := "123456789012345678901234567890";
	t->eqs(IPint.strtoip(big1, 10).iptostr(10), big1, "IPint base-10 string round-trip");

	# addition with carry across word boundaries
	s1 := IPint.strtoip("18446744073709551615", 10);	# 2^64 - 1
	s2 := IPint.inttoip(1);
	t->eqs(s1.add(s2).iptostr(10), "18446744073709551616", "IPint add across 2^64");

	# modular exponentiation (the core of RSA/DH; heavy libmp path)
	t->eqi(big IPint.inttoip(2).expmod(IPint.inttoip(10), IPint.inttoip(1000)).iptoint(),
		big 24, "IPint 2^10 mod 1000");
	t->eqi(big IPint.inttoip(3).expmod(IPint.inttoip(7), IPint.inttoip(100)).iptoint(),
		big 87, "IPint 3^7 mod 100");

	# a genuinely large modexp: 7^160 mod (10^20-1)
	mbase := IPint.inttoip(7);
	mexp := IPint.inttoip(160);
	mmod := IPint.strtoip("99999999999999999999", 10);
	r := mbase.expmod(mexp, mmod);
	# verify by the modular identity (7^160 mod m): recompute as (7^80)^2 mod m
	half := mbase.expmod(IPint.inttoip(80), mmod);
	r2 := half.mul(half).mod(mmod);
	t->eqs(r.iptostr(10), r2.iptostr(10), "IPint large modexp self-consistency");

	# comparison and hex round-trip
	t->ok(IPint.inttoip(5).cmp(IPint.inttoip(7)) < 0, "IPint cmp lt");
	t->eqs(IPint.strtoip("deadbeefcafe", 16).iptostr(16), "DEADBEEFCAFE", "IPint base-16 round-trip");

	t->summary();
}

ivec(): array of byte
{
	v := array[16] of byte;
	for(i := 0; i < 16; i++)
		v[i] = byte 0;
	return v;
}

ivec8(): array of byte
{
	v := array[8] of byte;
	for(i := 0; i < 8; i++)
		v[i] = byte 0;
	return v;
}

samebytes(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}
