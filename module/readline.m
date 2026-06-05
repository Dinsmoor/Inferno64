# Readline: a raw-mode interactive line editor for the Inferno shell.
#
# It turns the console (/dev/cons) into a bash-like editing surface:
# cursor motion, kill/yank-free editing, persistent history recall and
# filename/command Tab completion.  It is deliberately self contained so
# that both the console shell (appl/cmd/sh) and, in spirit, any other
# interactive Limbo program can reuse it.
#
# The editor only takes over when the input fd is a real console; callers
# fall back to plain line-buffered reads otherwise (pipes, scripts).

Readline: module
{
	PATH:	con "/dis/sh/readline.dis";

	init:	fn();

	# Build an editor reading raw bytes from consin (normally fd 0, the
	# console).  Output/echo and raw-mode control are opened internally on
	# /dev/cons and /dev/consctl.  histmax bounds the retained history.
	# Returns nil if the console cannot be driven in raw mode, in which
	# case the caller should fall back to cooked line reads.
	open:	fn(consin: ref Sys->FD, histmax: int): ref Reader;

	Reader: adt {
		fdin:		ref Sys->FD;	# raw console input
		fdout:		ref Sys->FD;	# console echo/output
		ctl:		ref Sys->FD;	# /dev/consctl (raw on/off)
		hist:		array of string;	# oldest .. newest
		nhist:		int;
		histmax:	int;
		histfile:	string;

		# Read one logical line, displaying prompt.  The returned string
		# includes the terminating '\n'.  Returns nil only at end of
		# input (^D on an empty line); a cancelled line (^C) yields "\n".
		readline:	fn(r: self ref Reader, prompt: string): string;

		addhist:	fn(r: self ref Reader, line: string);
		loadhist:	fn(r: self ref Reader, file: string);
		savehist:	fn(r: self ref Reader);
		close:		fn(r: self ref Reader);
	};
};
