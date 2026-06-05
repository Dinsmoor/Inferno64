implement Readline;

#
# Raw-mode interactive line editor for the Inferno shell.  See module/readline.m.
#
# The editor puts the console into raw mode (via /dev/consctl) only while a line
# is being typed, restoring cooked mode before returning, so commands the shell
# subsequently runs see a normal cooked console.  It echoes and redraws the line
# itself using a small subset of ANSI/VT control sequences, which the host
# terminal (or any xterm-like) understands.
#

include "sys.m";
	sys: Sys;
include "readline.m";

# control characters
CTLA:	con 16r01;	# home
CTLB:	con 16r02;	# left
CTLC:	con 16r03;	# cancel line
CTLD:	con 16r04;	# eof / delete-forward
CTLE:	con 16r05;	# end
CTLF:	con 16r06;	# right
BELL:	con 16r07;
CTLH:	con 16r08;	# backspace
TAB:	con 16r09;
NL:	con 16r0a;
CTLK:	con 16r0b;	# kill to end of line
CTLL:	con 16r0c;	# clear screen
CR:	con 16r0d;
CTLN:	con 16r0e;	# next history
CTLP:	con 16r10;	# previous history
CTLU:	con 16r15;	# kill to start of line
CTLW:	con 16r17;	# kill previous word
ESCC:	con 16r1b;
DEL:	con 16r7f;	# backspace (terminal)

init()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
}

open(consin: ref Sys->FD, histmax: int): ref Reader
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	ctl := sys->open("/dev/consctl", Sys->OWRITE);
	if(ctl == nil)
		return nil;
	fdout := sys->open("/dev/cons", Sys->OWRITE);
	if(fdout == nil)
		fdout = sys->fildes(1);
	if(histmax <= 0)
		histmax = 200;
	return ref Reader(consin, fdout, ctl, array[histmax] of string, 0, histmax, nil);
}

out(r: ref Reader, s: string)
{
	if(s == nil)
		return;
	a := array of byte s;
	sys->write(r.fdout, a, len a);
}

ctlwrite(r: ref Reader, s: string)
{
	a := array of byte s;
	sys->write(r.ctl, a, len a);
}

rawon(r: ref Reader)	{ ctlwrite(r, "rawon"); }
rawoff(r: ref Reader)	{ ctlwrite(r, "rawoff"); }

# read one full rune from the raw console; -1 on EOF.
getrune(r: ref Reader): int
{
	buf := array[Sys->UTFmax] of byte;
	one := array[1] of byte;
	nb := 0;
	for(;;){
		n := sys->read(r.fdin, one, 1);
		if(n <= 0)
			return -1;
		buf[nb++] = one[0];
		(ch, nil, ok) := sys->byte2char(buf, 0);
		if(ok)
			return ch;
		if(nb >= Sys->UTFmax)
			return 16rFFFD;
	}
}

isspace(c: int): int
{
	return c == ' ' || c == '\t';
}

strip(s: string): string
{
	i := 0;
	while(i < len s && isspace(s[i]))
		i++;
	j := len s;
	while(j > i && isspace(s[j-1]))
		j--;
	return s[i:j];
}

# redraw the current line in place, leaving the cursor at column `cur`.
redraw(r: ref Reader, prompt, buf: string, cur: int)
{
	s := "\r" + prompt + buf + "\u001b[K";
	tail := len buf - cur;
	if(tail > 0)
		s += sys->sprint("\u001b[%dD", tail);
	out(r, s);
}

Reader.readline(r: self ref Reader, prompt: string): string
{
	rawon(r);
	buf := "";
	cur := 0;
	hpos := r.nhist;	# index into history; == nhist means "the live line"
	saved := "";		# live line stashed while browsing history
	redraw(r, prompt, buf, cur);

	line: string;
	for(;;){
		c := getrune(r);
		if(c == -1){
			# EOF: end input only on an empty line, otherwise ignore.
			if(len buf == 0){
				rawoff(r);
				out(r, "\n");
				return nil;
			}
			continue;
		}
		case c {
		NL or CR =>
			rawoff(r);
			out(r, "\n");
			line = buf;
			r.addhist(line);
			return line + "\n";
		CTLC =>
			rawoff(r);
			out(r, "^C\n");
			return "\n";
		CTLD =>
			if(len buf == 0){
				rawoff(r);
				out(r, "\n");
				return nil;
			}
			if(cur < len buf){
				buf = buf[0:cur] + buf[cur+1:];
				redraw(r, prompt, buf, cur);
			}
		CTLH or DEL =>
			if(cur > 0){
				buf = buf[0:cur-1] + buf[cur:];
				cur--;
				redraw(r, prompt, buf, cur);
			}
		CTLA =>
			cur = 0;
			redraw(r, prompt, buf, cur);
		CTLE =>
			cur = len buf;
			redraw(r, prompt, buf, cur);
		CTLB =>
			if(cur > 0){
				cur--;
				redraw(r, prompt, buf, cur);
			}
		CTLF =>
			if(cur < len buf){
				cur++;
				redraw(r, prompt, buf, cur);
			}
		CTLK =>
			buf = buf[0:cur];
			redraw(r, prompt, buf, cur);
		CTLU =>
			buf = buf[cur:];
			cur = 0;
			redraw(r, prompt, buf, cur);
		CTLW =>
			(buf, cur) = killword(buf, cur);
			redraw(r, prompt, buf, cur);
		CTLL =>
			out(r, "\u001b[H\u001b[2J");
			redraw(r, prompt, buf, cur);
		CTLP =>
			(hpos, buf, cur, saved) = histprev(r, hpos, buf, saved);
			redraw(r, prompt, buf, cur);
		CTLN =>
			(hpos, buf, cur, saved) = histnext(r, hpos, buf, saved);
			redraw(r, prompt, buf, cur);
		TAB =>
			(buf, cur) = complete(r, prompt, buf, cur);
			redraw(r, prompt, buf, cur);
		ESCC =>
			(hpos, buf, cur, saved) = escseq(r, hpos, buf, cur, saved);
			redraw(r, prompt, buf, cur);
		* =>
			if(c >= ' '){
				buf = buf[0:cur] + sys->sprint("%c", c) + buf[cur:];
				cur++;
				redraw(r, prompt, buf, cur);
			}
		}
	}
}

killword(buf: string, cur: int): (string, int)
{
	i := cur;
	while(i > 0 && isspace(buf[i-1]))
		i--;
	while(i > 0 && !isspace(buf[i-1]))
		i--;
	return (buf[0:i] + buf[cur:], i);
}

histprev(r: ref Reader, hpos: int, buf, saved: string): (int, string, int, string)
{
	if(hpos <= 0)
		return (hpos, buf, len buf, saved);
	if(hpos == r.nhist)
		saved = buf;
	hpos--;
	nb := r.hist[hpos];
	return (hpos, nb, len nb, saved);
}

histnext(r: ref Reader, hpos: int, buf, saved: string): (int, string, int, string)
{
	if(hpos >= r.nhist)
		return (hpos, buf, len buf, saved);
	hpos++;
	nb: string;
	if(hpos == r.nhist)
		nb = saved;
	else
		nb = r.hist[hpos];
	return (hpos, nb, len nb, saved);
}

# parse an ESC-introduced sequence (arrow keys, Home/End/Del).
escseq(r: ref Reader, hpos: int, buf: string, cur: int, saved: string): (int, string, int, string)
{
	c := getrune(r);
	if(c != '[' && c != 'O')
		return (hpos, buf, cur, saved);
	c = getrune(r);
	case c {
	'A' =>
		return histprev(r, hpos, buf, saved);
	'B' =>
		return histnext(r, hpos, buf, saved);
	'C' =>
		if(cur < len buf)
			cur++;
	'D' =>
		if(cur > 0)
			cur--;
	'H' =>
		cur = 0;
	'F' =>
		cur = len buf;
	'1' or '3' or '4' or '7' or '8' =>
		# extended keys: ESC [ n ~
		if(getrune(r) == '~'){
			case c {
			'1' or '7' =>
				cur = 0;
			'4' or '8' =>
				cur = len buf;
			'3' =>
				if(cur < len buf)
					buf = buf[0:cur] + buf[cur+1:];
			}
		}
	}
	return (hpos, buf, cur, saved);
}

#
# Tab completion: complete the whitespace-delimited token ending at the cursor.
# A token containing '/' completes as a path; a bare first word also draws
# command names from /dis.
#
complete(r: ref Reader, prompt, buf: string, cur: int): (string, int)
{
	i := cur;
	while(i > 0 && !isspace(buf[i-1]))
		i--;
	tok := buf[i:cur];

	cmdpos := 1;
	for(j := 0; j < i; j++)
		if(!isspace(buf[j])){
			cmdpos = 0;
			break;
		}

	(dir, base) := splitpath(tok);
	matches := listmatches(dir, base);
	if(cmdpos && nopath(tok))
		matches = mergematches(matches, listmatches("/dis/", base));

	n := len matches;
	if(n == 0){
		out(r, "\a");
		return (buf, cur);
	}

	repl: string;
	if(n == 1){
		repl = matches[0];
		if(len repl == 0 || repl[len repl-1] != '/')
			repl += " ";
	} else {
		common := lcp(matches);
		if(len common > len base)
			repl = common;
		else {
			out(r, "\n");
			showmatches(r, matches);
			redraw(r, prompt, buf, cur);
			return (buf, cur);
		}
	}

	pre := tok[0:len tok - len base];	# directory portion already typed
	newtok := pre + repl;
	nb := buf[0:i] + newtok + buf[cur:];
	return (nb, i + len newtok);
}

nopath(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '/')
			return 0;
	return 1;
}

splitpath(tok: string): (string, string)
{
	k := -1;
	for(j := 0; j < len tok; j++)
		if(tok[j] == '/')
			k = j;
	if(k < 0)
		return (".", tok);
	return (tok[0:k+1], tok[k+1:]);
}

listmatches(dir, base: string): array of string
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return nil;
	res: list of string;
	nres := 0;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(j := 0; j < n; j++){
			nm := d[j].name;
			if(len nm >= len base && nm[0:len base] == base){
				if(d[j].mode & Sys->DMDIR)
					nm += "/";
				res = nm :: res;
				nres++;
			}
		}
	}
	a := array[nres] of string;
	k := 0;
	for(; res != nil; res = tl res)
		a[k++] = hd res;
	return a;
}

mergematches(a, b: array of string): array of string
{
	c := array[len a + len b] of string;
	k := 0;
	for(i := 0; i < len a; i++)
		c[k++] = a[i];
	for(j := 0; j < len b; j++)
		c[k++] = b[j];
	return c;
}

lcp(a: array of string): string
{
	if(len a == 0)
		return "";
	p := a[0];
	for(i := 1; i < len a; i++){
		s := a[i];
		j := 0;
		while(j < len p && j < len s && p[j] == s[j])
			j++;
		p = p[0:j];
	}
	return p;
}

showmatches(r: ref Reader, a: array of string)
{
	s := "";
	for(i := 0; i < len a; i++){
		if(i > 0)
			s += "  ";
		s += a[i];
	}
	s += "\n";
	out(r, s);
}

Reader.addhist(r: self ref Reader, line: string)
{
	line = strip(line);
	if(len line == 0)
		return;
	if(r.nhist > 0 && r.hist[r.nhist-1] == line)
		return;
	if(r.nhist >= r.histmax){
		for(i := 1; i < r.nhist; i++)
			r.hist[i-1] = r.hist[i];
		r.nhist--;
	}
	r.hist[r.nhist++] = line;
	writehist(r);
}

Reader.loadhist(r: self ref Reader, file: string)
{
	r.histfile = nil;
	fd := sys->open(file, Sys->OREAD);
	if(fd != nil){
		data := readall(fd);
		start := 0;
		for(i := 0; i < len data; i++){
			if(data[i] == '\n'){
				if(i > start)
					r.addhist(data[start:i]);
				start = i+1;
			}
		}
		if(start < len data)
			r.addhist(data[start:]);
	}
	r.histfile = file;
}

Reader.savehist(r: self ref Reader)
{
	writehist(r);
}

Reader.close(r: self ref Reader)
{
	rawoff(r);
}

writehist(r: ref Reader)
{
	if(r.histfile == nil)
		return;
	fd := sys->create(r.histfile, Sys->OWRITE, 8r600);
	if(fd == nil)
		return;
	s := "";
	for(i := 0; i < r.nhist; i++)
		s += r.hist[i] + "\n";
	a := array of byte s;
	sys->write(fd, a, len a);
}

readall(fd: ref Sys->FD): string
{
	s := "";
	buf := array[4096] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}
