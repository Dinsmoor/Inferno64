implement Dechunk;

#
# HTTP/1.1 chunked Transfer-Encoding decoder.  See dechunk.m for the grammar.
#
# Incremental and synchronous: feed() consumes whatever bytes are available and
# emits the dechunked body, keeping just enough state (current state + bytes
# remaining in the chunk + a partial line buffer) to resume on the next call.
#

include "dechunk.m";

# parser states
Ssize, Sdata, Sdataend, Strailer, Sdone: con iota;

init()
{
}

new(): ref Dechunker
{
	return ref Dechunker(Ssize, 0, "", 0, nil);
}

Dechunker.feed(d: self ref Dechunker, in: array of byte): (array of byte, string)
{
	if (d.err != nil)
		return (nil, d.err);

	# dechunked output is never larger than the raw input
	out := array[len in] of byte;
	no := 0;
	i := 0;
	while (i < len in) {
		case d.st {
		Ssize =>
			# accumulate the chunk-size line up to LF (CR ignored)
			c := int in[i++];
			if (c == '\n') {
				(sz, ok) := parsehex(d.line);
				d.line = "";
				if (!ok) {
					d.err = "dechunk: bad chunk size";
					return (out[0:no], d.err);
				}
				d.remain = sz;
				if (sz == 0)
					d.st = Strailer;
				else
					d.st = Sdata;
			} else if (c != '\r')
				d.line[len d.line] = c;
		Sdata =>
			navail := len in - i;
			take := d.remain;
			if (take > navail)
				take = navail;
			out[no:] = in[i:i+take];
			no += take;
			i += take;
			d.remain -= take;
			if (d.remain == 0)
				d.st = Sdataend;
		Sdataend =>
			# CRLF that terminates the chunk data (tolerate lone LF)
			c := int in[i++];
			if (c == '\n')
				d.st = Ssize;
		Strailer =>
			# trailer header lines until a blank line ends the body
			c := int in[i++];
			if (c == '\n') {
				if (d.line == "") {
					d.finished = 1;
					d.st = Sdone;
				} else
					d.line = "";
			} else if (c != '\r')
				d.line[len d.line] = c;
		Sdone =>
			# anything past the terminator is not ours (e.g. a
			# pipelined response); stop consuming.
			i = len in;
		}
	}
	return (out[0:no], nil);
}

Dechunker.done(d: self ref Dechunker): int
{
	return d.finished;
}

# Parse a leading run of hex digits (ignoring surrounding spaces and any
# ";chunk-ext" suffix).  Returns (value, ok).
parsehex(s: string): (int, int)
{
	i := 0;
	while (i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	v := 0;
	n := 0;
	for (; i < len s; i++) {
		c := s[i];
		dig := -1;
		if (c >= '0' && c <= '9')
			dig = c - '0';
		else if (c >= 'a' && c <= 'f')
			dig = c - 'a' + 10;
		else if (c >= 'A' && c <= 'F')
			dig = c - 'A' + 10;
		else
			break;
		v = v * 16 + dig;
		n++;
	}
	return (v, n > 0);
}
