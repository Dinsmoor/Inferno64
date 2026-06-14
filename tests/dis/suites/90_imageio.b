implement ImageioTest;

#
# Avenue 9: native image decode/encode ($Imageio over vendored stb + libwebp).
# A PNG round-trip (encode is the inverse of decode, and PNG is lossless) needs
# no fixture and exercises the whole path: the stb PNG encoder, the magic-routed
# decoder, and the RGBA buffer marshalling across the Dis/C boundary.  A
# decodefit downscale and a rejected non-image round out the cases.
#

include "sys.m";
include "draw.m";
include "imageio.m";
include "testing.m";

sys: Sys;
imageio: Imageio;
t: Testing;

ImageioTest: module
{
	init: fn(nil: ref Draw->Context, nil: list of string);
};

# a deterministic RGBA image (R,G,B,A per pixel, top-to-bottom): the layout
# decode() produces and encode() consumes.
mkimg(w, h: int): array of byte
{
	rgba := array[w*h*4] of byte;
	for(i := 0; i < w*h; i++){
		rgba[i*4+0] = byte (i & 16r7f);
		rgba[i*4+1] = byte ((i*3) & 16r7f);
		rgba[i*4+2] = byte ((i*7) & 16r7f);
		rgba[i*4+3] = byte 16rff;
	}
	return rgba;
}

eqbytes(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	t = load Testing Testing->PATH;
	t->init();
	imageio = load Imageio Imageio->PATH;
	if(imageio == nil){
		sys->print("1..0 # SKIP no $Imageio builtin\n");
		return;
	}

	# --- PNG round-trip: encode RGBA -> PNG -> decode back, byte-exact ---
	W := 8;
	H := 8;
	src := mkimg(W, H);
	(png, eerr) := imageio->encode(W, H, src);
	t->ok(eerr == nil, "encode ok");
	t->ok(png != nil && len png > 8, "encode produced PNG bytes");

	(dw, dh, dst, derr) := imageio->decode(png);
	t->eqs(derr, "", "decode ok");
	t->eqi(big dw, big W, "decode width");
	t->eqi(big dh, big H, "decode height");
	t->ok(eqbytes(src, dst), "PNG round-trip is lossless");

	# --- decodefit caps a larger image to the requested box ---
	(big16, berr) := imageio->encode(16, 16, mkimg(16, 16));
	t->ok(berr == nil, "encode 16x16 ok");
	(fw, fh, nil, ferr) := imageio->decodefit(big16, 8, 8);
	t->eqs(ferr, "", "decodefit ok");
	t->ok(fw <= 8 && fh <= 8, "decodefit caps dimensions");

	# --- a non-image is rejected, not crashed on ---
	junk := array[64] of { * => byte 16r5a };
	(nil, nil, nil, jerr) := imageio->decode(junk);
	t->ok(jerr != nil, "non-image rejected");

	t->summary();
}
