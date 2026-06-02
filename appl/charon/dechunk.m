# Dechunk — HTTP/1.1 "Transfer-Encoding: chunked" decoder for Charon.
#
# A synchronous, incremental state machine (no goroutine): feed it raw network
# bytes and it returns the dechunked body bytes decoded so far, buffering any
# partial chunk-size/trailer line across calls.  done() reports when the
# terminating zero-length chunk has been seen — important on keep-alive
# connections, where the socket does NOT close after the body.
#
# Chunked grammar (RFC 7230 §4.1):
#   chunked-body = *chunk last-chunk trailer-part CRLF
#   chunk        = chunk-size [chunk-ext] CRLF chunk-data CRLF
#   last-chunk   = 1*"0" [chunk-ext] CRLF
Dechunk: module
{
	PATH:	con "/dis/charon/dechunk.dis";

	Dechunker: adt {
		st:		int;		# parser state (internal)
		remain:		int;		# bytes left in the current chunk
		line:		string;		# partial size / trailer line
		finished:	int;		# last-chunk + trailers seen
		err:		string;		# non-nil once a framing error is hit

		# Decode the next slice of raw bytes; returns (body, err).
		feed:	fn(d: self ref Dechunker, in: array of byte): (array of byte, string);
		# 1 once the chunked body is complete.
		done:	fn(d: self ref Dechunker): int;
	};

	init:	fn();
	new:	fn(): ref Dechunker;
};
