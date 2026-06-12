implement Exraise;

include "sys.m";
include "exraise.m";

boom(pat: string)
{
	raise pat;
}

boomthrough(pat: string)
{
	# a handler that deliberately does not match `pat`, so the exception
	# falls through this frame's NOPC terminator and unwinds to the caller.
	{
		boom(pat);
	} exception e {
	"nomatch:*" =>
		return;
	}
}
