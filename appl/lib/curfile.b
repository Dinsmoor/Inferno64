implement Curfile;

#
# Curfile - decode Windows .cur / .ani cursor files into raw A,R,G,B frames.
# See module/curfile.m for the interface and pixel layout.
#
# Formats:
#   .cur  = ICONDIR (6) + ICONDIRENTRY[count] (16 each) + image data.  For a
#           cursor the entry carries the hotspot; the image is a PNG or a DIB
#           (BITMAPINFOHEADER + optional palette + XOR pixels + 1bpp AND mask,
#           rows bottom-up, height field doubled to cover the mask).
#   .ani  = RIFF/ACON: an 'anih' header (frame/step counts, 1/60s display rate,
#           flags), optional 'rate'/'seq ' chunks, and a LIST 'fram' of 'icon'
#           chunks, each a standalone .cur.
#

include "sys.m";
	sys: Sys;
include "imageio.m";
	imageio: Imageio;
include "curfile.m";

init()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	# $Imageio is only needed for PNG-embedded entries; load lazily.
}

g16(d: array of byte, o: int): int
{
	return int d[o] | (int d[o+1] << 8);
}

g32(d: array of byte, o: int): int
{
	return int d[o] | (int d[o+1] << 8) | (int d[o+2] << 16) | (int d[o+3] << 24);
}

readfile(path: string): (ref Cursor, string)
{
	if(sys == nil)
		init();
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%s: %r", path));
	data := array[0] of byte;
	tmp := array[8192] of byte;
	for(;;){
		n := sys->read(fd, tmp, len tmp);
		if(n <= 0)
			break;
		nb := array[len data + n] of byte;
		nb[0:] = data;
		nb[len data:] = tmp[0:n];
		data = nb;
	}
	if(len data == 0)
		return (nil, sys->sprint("%s: empty", path));
	(c, err) := decode(data);
	if(err != nil)
		return (nil, sys->sprint("%s: %s", path, err));
	return (c, nil);
}

decode(data: array of byte): (ref Cursor, string)
{
	if(sys == nil)
		init();
	if(len data < 6)
		return (nil, "short cursor file");
	if(len data >= 12 && string data[0:4] == "RIFF" && string data[8:12] == "ACON")
		return decodeani(data);
	# ICONDIR: reserved 0, type 1 (icon) or 2 (cursor)
	if(g16(data, 0) == 0 && (g16(data, 2) == 1 || g16(data, 2) == 2))
		return decodecur(data);
	return (nil, "not a .cur or .ani file");
}

# Decode one .cur/.ico image (the best-fitting entry) into a single-frame Cursor.
decodecur(d: array of byte): (ref Cursor, string)
{
	if(len d < 6)
		return (nil, "short cursor");
	iscursor := g16(d, 2) == 2;
	count := g16(d, 4);
	if(count <= 0)
		return (nil, "cursor has no images");

	best := -1;
	bestw := 0;
	bestbits := -1;
	for(i := 0; i < count; i++){
		eo := 6 + i*16;
		if(eo + 16 > len d)
			break;
		w := int d[eo];
		if(w == 0)
			w = 256;
		h := int d[eo+1];
		if(h == 0)
			h = 256;
		off := g32(d, eo+12);
		if(off < 0 || off + 16 > len d)
			continue;
		bits := 32;			# PNG entries: assume RGBA
		if(g16(d, off) != 16r5089)	# not the PNG \x89P magic -> DIB
			bits = g16(d, off+14);
		# prefer the largest frame that still fits, then deepest colour
		if(w > MAXDIM || h > MAXDIM)
			continue;
		if(w > bestw || (w == bestw && bits > bestbits)){
			best = i;
			bestw = w;
			bestbits = bits;
		}
	}
	if(best < 0)
		return (nil, sys->sprint("no usable frame (max %dx%d)", MAXDIM, MAXDIM));

	eo := 6 + best*16;
	hotx := 0;
	hoty := 0;
	if(iscursor){
		hotx = g16(d, eo+4);
		hoty = g16(d, eo+6);
	}
	off := g32(d, eo+12);
	size := g32(d, eo+8);
	if(off < 0 || off >= len d)
		return (nil, "bad image offset");
	if(size <= 0 || off + size > len d)
		size = len d - off;

	(w, h, argb, err) := decodeimage(d, off, size);
	if(err != nil)
		return (nil, err);
	c := ref Cursor;
	c.w = w;
	c.h = h;
	c.hotx = hotx;
	c.hoty = hoty;
	c.frames = array[1] of {argb};
	c.delays = array[1] of {0};
	return (c, nil);
}

# Decode the image blob at d[off:off+size]: PNG via $Imageio, else a DIB.
decodeimage(d: array of byte, off, size: int): (int, int, array of byte, string)
{
	if(size >= 8 && d[off]==byte 16r89 && d[off+1]==byte 'P' &&
	   d[off+2]==byte 'N' && d[off+3]==byte 'G'){
		if(imageio == nil)
			imageio = load Imageio Imageio->PATH;
		if(imageio == nil)
			return (0, 0, nil, "PNG cursor needs $Imageio");
		(w, h, rgba, err) := imageio->decode(d[off:off+size]);
		if(rgba == nil)
			return (0, 0, nil, err);
		if(w <= 0 || h <= 0 || w > MAXDIM || h > MAXDIM)
			return (0, 0, nil, sys->sprint("bad PNG cursor size %dx%d", w, h));
		argb := array[w*h*4] of byte;
		for(j := 0; j < w*h; j++){		# R,G,B,A -> A,R,G,B
			argb[j*4+0] = rgba[j*4+3];
			argb[j*4+1] = rgba[j*4+0];
			argb[j*4+2] = rgba[j*4+1];
			argb[j*4+3] = rgba[j*4+2];
		}
		return (w, h, argb, nil);
	}
	return decodedib(d, off, size);
}

decodedib(d: array of byte, off, size: int): (int, int, array of byte, string)
{
	if(size < 40 || off + 40 > len d)
		return (0, 0, nil, "short DIB header");
	hsize := g32(d, off);
	w := g32(d, off+4);
	hraw := g32(d, off+8);		# signed: positive bottom-up, doubled for the mask
	bits := g16(d, off+14);
	comp := g32(d, off+16);
	clrused := g32(d, off+32);

	topdown := 0;
	h2 := hraw;
	if(h2 < 0){
		topdown = 1;
		h2 = -h2;
	}
	h := h2 / 2;			# ICO height covers XOR pixels + AND mask
	if(w <= 0 || h <= 0 || w > MAXDIM || h > MAXDIM)
		return (0, 0, nil, sys->sprint("bad DIB size %dx%d", w, h));
	if(comp != 0 && comp != 3)	# BI_RGB or BI_BITFIELDS(32bpp) only
		return (0, 0, nil, sys->sprint("compressed DIB (comp %d)", comp));

	ncol := 0;
	if(bits <= 8){
		ncol = clrused;
		if(ncol <= 0)
			ncol = 1 << bits;
	}
	paloff := off + hsize;
	xoroff := paloff + ncol*4;
	xstride := ((bits*w + 31) / 32) * 4;
	andstride := ((w + 31) / 32) * 4;
	andoff := xoroff + xstride*h;
	if(andoff + andstride*h > off + size + 4)	# tolerate a missing/short mask
		andoff = -1;

	# 32bpp images may carry their alpha in the pixels or rely on the mask.
	anyalpha := 0;
	if(bits == 32){
		for(y := 0; y < h && !anyalpha; y++){
			ro := xoroff + y*xstride;
			for(x := 0; x < w; x++)
				if(ro + x*4 + 3 < len d && int d[ro + x*4 + 3] != 0){
					anyalpha = 1;
					break;
				}
		}
	}

	argb := array[w*h*4] of byte;
	for(y := 0; y < h; y++){
		# destination row 0 is the top; DIB rows are bottom-up unless topdown
		srcy := y;
		if(!topdown)
			srcy = h - 1 - y;
		xro := xoroff + srcy*xstride;
		for(x := 0; x < w; x++){
			r, gg, b, a: int;
			a = 255;
			case bits {
			32 =>
				o := xro + x*4;
				if(o+3 >= len d){ b=gg=r=0; a=0; }
				else{
					b = int d[o]; gg = int d[o+1]; r = int d[o+2];
					if(anyalpha)
						a = int d[o+3];
				}
			24 =>
				o := xro + x*3;
				if(o+2 >= len d){ b=gg=r=0; }
				else{ b = int d[o]; gg = int d[o+1]; r = int d[o+2]; }
			8 =>
				o := xro + x;
				idx := 0;
				if(o < len d)
					idx = int d[o];
				(r, gg, b) = palentry(d, paloff, ncol, idx);
			4 =>
				o := xro + x/2;
				idx := 0;
				if(o < len d){
					if((x & 1) == 0)
						idx = (int d[o] >> 4) & 16rF;
					else
						idx = int d[o] & 16rF;
				}
				(r, gg, b) = palentry(d, paloff, ncol, idx);
			1 =>
				o := xro + x/8;
				bit := 0;
				if(o < len d)
					bit = (int d[o] >> (7 - (x & 7))) & 1;
				(r, gg, b) = palentry(d, paloff, ncol, bit);
			* =>
				return (0, 0, nil, sys->sprint("unsupported %d bpp cursor", bits));
			}
			# AND mask: a set bit means transparent
			if(andoff >= 0){
				mo := andoff + srcy*andstride + x/8;
				if(mo < len d && ((int d[mo] >> (7 - (x & 7))) & 1))
					a = 0;
			}
			o := (y*w + x)*4;
			argb[o+0] = byte a;
			argb[o+1] = byte r;
			argb[o+2] = byte gg;
			argb[o+3] = byte b;
		}
	}
	return (w, h, argb, nil);
}

# Palette entry idx -> (r,g,b); DIB palette is B,G,R,reserved.
palentry(d: array of byte, paloff, ncol, idx: int): (int, int, int)
{
	if(idx < 0 || idx >= ncol)
		return (0, 0, 0);
	o := paloff + idx*4;
	if(o+2 >= len d)
		return (0, 0, 0);
	return (int d[o+2], int d[o+1], int d[o]);
}

decodeani(d: array of byte): (ref Cursor, string)
{
	displayrate := 10;		# jiffies (1/60s); overridden by anih
	nsteps := 0;
	rates: array of int;
	seqs: array of int;
	icons: list of array of byte;

	o := 12;			# past "RIFF" size "ACON"
	while(o + 8 <= len d){
		id := string d[o:o+4];
		sz := g32(d, o+4);
		body := o + 8;
		if(sz < 0 || body + sz > len d)
			sz = len d - body;
		case id {
		"anih" =>
			if(sz >= 36){
				nsteps = g32(d, body+8);
				displayrate = g32(d, body+28);
			}
		"rate" =>
			n := sz/4;
			rates = array[n] of int;
			for(i := 0; i < n; i++)
				rates[i] = g32(d, body + i*4);
		"seq " =>
			n := sz/4;
			seqs = array[n] of int;
			for(i := 0; i < n; i++)
				seqs[i] = g32(d, body + i*4);
		"LIST" =>
			if(sz >= 4 && string d[body:body+4] == "fram"){
				p := body + 4;
				while(p + 8 <= body + sz){
					sid := string d[p:p+4];
					ssz := g32(d, p+4);
					if(ssz < 0 || p + 8 + ssz > len d)
						break;
					if(sid == "icon")
						icons = d[p+8:p+8+ssz] :: icons;
					p += 8 + ssz + (ssz & 1);
				}
			}
		}
		o = body + sz + (sz & 1);
	}

	nf := len icons;
	if(nf == 0)
		return (nil, "animated cursor has no frames");
	# icons were collected in reverse; restore file order
	iconv := array[nf] of array of byte;
	i := nf;
	for(l := icons; l != nil; l = tl l)
		iconv[--i] = hd l;

	decoded := array[nf] of ref Cursor;
	for(i = 0; i < nf; i++){
		(c, err) := decodecur(iconv[i]);
		if(err != nil)
			return (nil, sys->sprint("frame %d: %s", i, err));
		decoded[i] = c;
	}

	w := decoded[0].w;
	h := decoded[0].h;
	if(nsteps <= 0)
		nsteps = nf;
	if(seqs != nil && len seqs < nsteps)
		nsteps = len seqs;
	if(nsteps > MAXFRAME)
		nsteps = MAXFRAME;

	frames := array[nsteps] of array of byte;
	delays := array[nsteps] of int;
	for(s := 0; s < nsteps; s++){
		fi := s;
		if(seqs != nil && s < len seqs)
			fi = seqs[s];
		if(fi < 0 || fi >= nf)
			fi = 0;
		if(decoded[fi].w != w || decoded[fi].h != h)
			return (nil, "animation frames differ in size");
		frames[s] = decoded[fi].frames[0];
		jif := displayrate;
		if(rates != nil && s < len rates)
			jif = rates[s];
		ms := jif * 1000 / 60;
		if(ms <= 0)
			ms = 100;
		delays[s] = ms;
	}

	c := ref Cursor;
	c.w = w;
	c.h = h;
	c.hotx = decoded[0].hotx;
	c.hoty = decoded[0].hoty;
	c.frames = frames;
	c.delays = delays;
	return (c, nil);
}
