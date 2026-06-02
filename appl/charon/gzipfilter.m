# Gzipfilter — HTTP Content-Encoding decoder for Charon.
#
# Thin codec wrapper around the existing inflate Filter (/dis/lib/inflate.dis,
# module/filter.m) that knows how to map HTTP Content-Encoding tokens onto the
# Filter's gzip ("h"), zlib ("z") and raw-deflate (nil) framing modes.
#
# Two ways to use it:
#   - inflate(enc, in): one-shot decode of a complete compressed buffer.
#     Handy for resources fetched whole (images, stylesheets, scripts).
#   - start(enc) -> ref Decoder: streaming decode.  Feed compressed bytes with
#     Decoder.write(); signal end-of-input with Decoder.eof(); drain decoded
#     bytes (and completion/error) from Decoder.out.  Suitable for splicing into
#     a Charon ByteSource pump so HTML can still render incrementally.
Gzipfilter: module
{
	PATH:	con "/dis/charon/gzipfilter.dis";

	# Decoder.out message kinds.
	Ddata,			# buf carries a chunk of decoded output
	Ddone,			# decode finished cleanly; buf and err are nil
	Derr:	con iota;	# decode failed; err carries the reason

	Decoder: adt {
		inq:	chan of array of byte;		# internal: compressed in (nil = EOF)
		out:	chan of (int, array of byte, string);	# (kind, buf, err)

		write:	fn(d: self ref Decoder, buf: array of byte);
		eof:	fn(d: self ref Decoder);
	};

	init:	fn();

	# Is this HTTP Content-Encoding token one we can decode?
	supported:	fn(enc: string): int;

	# Start a streaming decoder for the given Content-Encoding token.
	# Returns nil if the encoding is unsupported or the Filter cannot load.
	start:	fn(enc: string): ref Decoder;

	# Decode a complete compressed buffer in one call.
	# Returns (decoded, nil) on success or (nil, errmsg) on failure.
	inflate:	fn(enc: string, in: array of byte): (array of byte, string);
};
