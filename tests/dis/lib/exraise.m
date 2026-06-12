Exraise: module
{
	PATH:	con "/tests/dis/_build/lib/exraise.dis";

	# raise a string exception (no handler here) so it unwinds across the
	# module-call boundary back into the caller — the path that broke on LP64
	# when `kill` raised "fail:..." back into the shell.
	boom:		fn(pat: string);
	# call boom through a local handler that does NOT match, forcing the
	# NOPC "no handler" terminator and a further unwind to our caller.
	boomthrough:	fn(pat: string);
};
