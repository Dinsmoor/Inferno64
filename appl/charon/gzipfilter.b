implement Gzipfilter;

#
# HTTP Content-Encoding decoder for Charon.
#
# Maps the HTTP Content-Encoding tokens "gzip"/"x-gzip"/"deflate" onto the
# framing modes understood by the inflate Filter (module/filter.m):
#	gzip, x-gzip	-> "h"	(gzip 10-byte header + CRC32/ISIZE trailer)
#	deflate		-> "z"	(zlib header), with a raw-deflate retry for the
#				 servers that send bare deflate streams.
#
# The Filter protocol is pull/push: it sends Fill requests asking us to supply
# input, and Result messages handing back decoded output.  We translate that
# into a simpler Decoder with a write/eof input side and a single out channel.
#
# NOTE: a streaming Decoder must be fed (write/eof) and drained (out) from
# DIFFERENT processes — both channels are unbuffered, so feeding and draining
# on one process can deadlock.  inflate() handles this internally for the
# one-shot case.
#

include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
include "filter.m";
	filt: Filter;		# the inflate Filter (module/filter.m)

include "gzipfilter.m";

init()
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	filt = load Filter Filter->INFLATEPATH;
	if(filt != nil)
		filt->init();
}

supported(enc: string): int
{
	case lower(enc) {
	"gzip" or "x-gzip" or "deflate" =>
		return 1;
	* =>
		return 0;
	}
}

# Filter framing parameter for an HTTP Content-Encoding token.
paramfor(enc: string): string
{
	case lower(enc) {
	"gzip" or "x-gzip" =>
		return "h";
	"deflate" =>
		return "z";
	* =>
		return nil;
	}
}

start(enc: string): ref Decoder
{
	if(!supported(enc))
		return nil;
	return startp(paramfor(enc));
}

# Start a decoder for a raw Filter framing parameter ("h", "z", or nil=raw).
startp(param: string): ref Decoder
{
	if(filt == nil)
		return nil;
	f := filt->start(param);
	if(f == nil)
		return nil;
	d := ref Decoder(
		chan of array of byte,
		chan of (int, array of byte, string)
	);
	spawn driver(d, f);
	return d;
}

Decoder.write(d: self ref Decoder, buf: array of byte)
{
	# copy: the caller may recycle its buffer before the driver consumes it
	cp := array[len buf] of byte;
	cp[0:] = buf;
	d.inq <-= cp;
}

Decoder.eof(d: self ref Decoder)
{
	d.inq <-= nil;
}

# Bridge the Filter's pull/push protocol to the Decoder channels.
driver(d: ref Decoder, f: chan of ref Filter->Rq)
{
	eofin := 0;
	pend: array of byte;		# compressed bytes not yet handed to a Fill

	for(;;) {
		pick m := <-f {
		Start =>
			;			# producer pid notification; ignore
		Fill =>
			if(pend == nil && !eofin) {
				pend = <-d.inq;		# blocks; nil signals EOF
				if(pend == nil)
					eofin = 1;
			}
			if(pend == nil) {
				m.reply <-= 0;		# tell inflate the input ended
			} else {
				n := len m.buf;
				if(n > len pend)
					n = len pend;
				m.buf[0:] = pend[0:n];
				m.reply <-= n;
				if(n >= len pend)
					pend = nil;
				else
					pend = pend[n:];
			}
		Result =>
			if(len m.buf > 0) {
				cp := array[len m.buf] of byte;
				cp[0:] = m.buf;
				d.out <-= (Ddata, cp, nil);
			}
			m.reply <-= 0;
		Info =>
			;			# gzip filename/mtime metadata; ignore
		Finished =>
			d.out <-= (Ddone, nil, nil);
			return;
		Error =>
			d.out <-= (Derr, nil, m.e);
			return;
		}
	}
}

inflate(enc: string, in: array of byte): (array of byte, string)
{
	if(!supported(enc))
		return (nil, "unsupported content-encoding: " + enc);
	(out, err) := oneshot(paramfor(enc), in);
	# some servers label raw deflate as "deflate"; retry without the zlib header
	if(err != nil && lower(enc) == "deflate")
		(out, err) = oneshot(nil, in);
	return (out, err);
}

oneshot(param: string, in: array of byte): (array of byte, string)
{
	d := startp(param);
	if(d == nil)
		return (nil, "cannot start inflate filter");

	spawn feedall(d, in);

	out := array[len in * 4 + 64] of byte;
	n := 0;
	for(;;) {
		(kind, buf, err) := <-d.out;
		case kind {
		Ddata =>
			if(n + len buf > len out) {
				grown := array[(n + len buf) * 2] of byte;
				grown[0:] = out[0:n];
				out = grown;
			}
			out[n:] = buf;
			n += len buf;
		Ddone =>
			return (out[0:n], nil);
		Derr =>
			return (nil, err);
		}
	}
}

feedall(d: ref Decoder, in: array of byte)
{
	d.write(in);
	d.eof();
}

lower(s: string): string
{
	if(str != nil)
		return str->tolower(s);
	# fallback if String module is unavailable
	t := s;
	for(i := 0; i < len t; i++)
		if(t[i] >= 'A' && t[i] <= 'Z')
			t[i] += 'a' - 'A';
	return t;
}
