implement Terminal;

#
# Reusable VT100/ANSI terminal emulator widget.
#
# The escape/CSI parser and screen model are descended from the old wm/vt
# (itself ported from decade-old C), reworked here into an embeddable widget:
# the screen is a cell grid rendered into an offscreen image shown in a Tk
# panel, decoupled from whatever is on the other end of the byte stream.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;
	FileIO, Rread: import sys;
include "draw.m";
	draw: Draw;
	Display, Font, Image, Rect, Point, Black: import draw;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;
include "term.m";

VT_MAXPARAM: con 8;
ESC: con "";

# private-use key runes (include/keyboard.h)
Spec:	con 16rE000;
View:	con Spec|16r10;
KF:	con Spec|16r40;
Khome:	con View|0;
Kend:	con View|1;
Kup:	con View|2;
Kdown:	con View|3;
Kleft:	con View|4;
Kright:	con View|5;
Kpgup:	con View|6;
Kpgdn:	con View|7;
Kins:	con Spec|16r63;
Kdel:	con Spec|16r64;

evseq := 0;	# unique-name counter for per-widget key channels
seqno := 0;	# unique-name counter for per-attach console file2chans

init()
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
}

Term.new(top: ref Toplevel, disp: ref Display, path: string, cols, rows: int, fontpath: string): ref Term
{
	t := ref Term;
	t.top = top;
	t.disp = disp;
	t.path = path;
	t.ppath = path + ".p";
	t.cols = cols;
	t.rows = rows;

	if(fontpath == nil)
		fontpath = FONT;
	t.font = Font.open(disp, fontpath);
	if(t.font == nil)
		t.font = Font.open(disp, "*default*");
	t.cw = t.font.width("m");
	if(t.cw <= 0)
		t.cw = 8;
	t.chh = t.font.height;

	# The palette and offscreen image are display images: they must be
	# allocated from the window image, which is not valid until onscreen().
	# show() does that.

	t.scr = array[rows] of string;
	t.cc = array[rows] of string;
	t.dirty = array[rows] of int;
	t.param = array[VT_MAXPARAM] of int;
	t.pad = "";
	for(i := 0; i < cols; i++)
		t.pad[i] = ' ';

	vtinit(t);

	# Tk widgets: a frame holding the display panel.  The frame takes key
	# focus (panels do not), so bindings live on it.
	t.ev = chan of string;
	evname := "termk" + string evseq++;
	tk->cmd(top, "frame " + path);
	tk->cmd(top, "panel " + t.ppath + " -width " + string (cols*t.cw) +
		" -height " + string (rows*t.chh));
	tk->cmd(top, "pack " + t.ppath + " -fill both -expand 1");
	tk->namechan(top, t.ev, evname);
	tk->cmd(top, "bind " + path + " <Key> {send " + evname + " {%A}}");
	tk->cmd(top, "focus " + path);

	return t;
}

Term.show(t: self ref Term)
{
	# Allocate display images from the display the window actually lives on
	# (valid only now, after onscreen) -- an image from another display will
	# not show through the panel.
	t.disp = t.top.image.display;
	t.pal = array[16] of ref Image;
	for(i := 0; i < 16; i++){
		v := 192;
		if(i & 8)
			v = 255;
		r := g := b := 0;
		if(i & 1) r = v;
		if(i & 2) g = v;
		if(i & 4) b = v;
		t.pal[i] = t.disp.rgb(r, g, b);
	}
	t.img = t.disp.newimage(((0,0),(t.cols*t.cw, t.rows*t.chh)), t.top.image.chans, 0, Black);

	tk->putimage(t.top, t.ppath, t.img, nil);
	t.redraw();
}

Term.redraw(t: self ref Term)
{
	for(y := 0; y < t.rows; y++)
		t.dirty[y] = 1;
	flush(t);
}

Term.sizereq(t: self ref Term): (int, int)
{
	return (t.cols*t.cw, t.rows*t.chh);
}

Term.clear(t: self ref Term)
{
	t.output("[2J[H");
}

Term.output(t: self ref Term, s: string): string
{
	reply = "";
	vtwrite(t, s);
	flush(t);
	r := reply;
	reply = "";
	return r;
}

Term.onkey(t: self ref Term, key: string): string
{
	# Tk's `send <chan> {%A}` delivers the char at index 1 (index 0 is the
	# brace/wrapper), with a backslash escape for specials -- as wm/sh does.
	if(len key < 2)
		return "";
	r := key[1];
	if(r == '\\' && len key > 2)
		r = key[2];
	case r {
	Kup =>		return "[A";
	Kdown =>	return "[B";
	Kright =>	return "[C";
	Kleft =>	return "[D";
	Khome =>	return "[H";
	Kend =>		return "[F";
	Kpgup =>	return "[5~";
	Kpgdn =>	return "[6~";
	Kins =>		return "[2~";
	Kdel =>		return "[3~";
	}
	if((r & ~16r3f) == KF){		# function keys F1..F12
		n := r & 16r3f;
		case n {
		1 => return "OP";
		2 => return "OQ";
		3 => return "OR";
		4 => return "OS";
		5 => return "[15~";
		6 => return "[17~";
		7 => return "[18~";
		8 => return "[19~";
		9 => return "[20~";
		10 => return "[21~";
		11 => return "[23~";
		12 => return "[24~";
		}
		return "";
	}
	if(r >= Spec && r < 16rF900)	# other unmapped specials: drop
		return "";
	return sys->sprint("%c", r);
}

#############################################################################
# rendering
#############################################################################

markdirty(t: ref Term, y: int)
{
	if(y >= 0 && y < t.rows)
		t.dirty[y] = 1;
}

flush(t: ref Term)
{
	# the cursor cell moves: repaint both the row it left and the row it is on
	markdirty(t, t.oy);
	markdirty(t, t.y);
	any := 0;
	for(y := 0; y < t.rows; y++){
		if(t.dirty[y]){
			renderrow(t, y);
			t.dirty[y] = 0;
			any = 1;
		}
	}
	t.ox = t.x;
	t.oy = t.y;
	if(any){
		tk->cmd(t.top, t.ppath + " dirty 0 0 " + string (t.cols*t.cw) +
			" " + string (t.rows*t.chh));
		tk->cmd(t.top, "update");
	}
}

renderrow(t: ref Term, y: int)
{
	yp := y * t.chh;
	for(x := 0; x < t.cols; x++){
		ch := vtscr(t, y, x);
		ccc := vtcc(t, y, x);
		fgc := ccc & 15;
		bgc := (ccc >> 4) & 15;
		if(x == t.x && y == t.y){	# block cursor: invert
			tmp := fgc; fgc = bgc; bgc = tmp;
		}
		xp := x * t.cw;
		s := "";
		s[0] = ch;
		t.img.draw(((xp,yp),(xp+t.cw,yp+t.chh)), t.pal[bgc], nil, (0,0));
		t.img.text((xp,yp), t.pal[fgc], (0,0), t.font, s);
	}
}

vtscr(t: ref Term, y, x: int): int
{
	if(y < 0 || y >= t.rows || t.scr[y] == nil || x >= len t.scr[y])
		return ' ';
	return t.scr[y][x];
}

vtcc(t: ref Term, y, x: int): int
{
	if(y < 0 || y >= t.rows || t.cc[y] == nil || x >= len t.cc[y])
		return 7;
	return t.cc[y][x];
}

#############################################################################
# emulator core (screen model + escape/CSI parser)
#############################################################################

reply := "";	# device replies accumulated during output()

PUTCHAR(t: ref Term, x, y, ch: int)
{
	if(y < 0 || y >= t.rows)
		return;
	if(len t.scr[y] < x){
		t.scr[y] += t.pad[0:x-len t.scr[y]];
		t.cc[y] += t.pad[0:x-len t.cc[y]];
	}
	t.scr[y][x] = ch;
	t.cc[y][x] = t.ccc;
	markdirty(t, y);
}

CLEAR(t: ref Term, x1, y1, x2, y2: int)
{
	# Rectangular clear of columns x1..x2 on rows y1..y2.  Every multi-row
	# call site passes the full width, so a column-aware clear is correct for
	# all of them -- and a column-honest ESC[K (erase to end of line) is
	# essential: readline redraws each line with a trailing ESC[K, so a
	# whole-line clear there would wipe the prompt it just drew.
	if(x1 < 0)
		x1 = 0;
	if(x2 > t.cols-1)
		x2 = t.cols-1;
	for(y := y1; y <= y2; y++){
		if(y < 0 || y >= t.rows)
			continue;
		if(x1 <= 0 && x2 >= t.cols-1){
			# whole line: drop it (vtscr renders missing cells blank)
			t.scr[y] = "";
			t.cc[y] = "";
		} else if(x2 >= t.cols-1){
			# clear to end of line: truncate at x1
			if(len t.scr[y] > x1){
				t.scr[y] = t.scr[y][0:x1];
				t.cc[y] = t.cc[y][0:x1];
			}
		} else {
			# clear an interior span x1..x2: blank those cells in place
			padrow(t, y, x2+1);
			for(x := x1; x <= x2; x++){
				t.scr[y][x] = ' ';
				t.cc[y][x] = t.ccc;
			}
		}
		markdirty(t, y);
	}
}

# extend a row to at least n cells, padding with blanks in the current colour
padrow(t: ref Term, y, n: int)
{
	while(len t.scr[y] < n)
		t.scr[y][len t.scr[y]] = ' ';
	while(len t.cc[y] < n)
		t.cc[y][len t.cc[y]] = t.ccc;
}

SCROLL_UP(t: ref Term, nil, y1, nil, y2, n: int)
{
	for(i := y1; i <= y2-n; i++){
		t.scr[i] = t.scr[i+n];
		t.cc[i] = t.cc[i+n];
		markdirty(t, i);
	}
	CLEAR(t, 0, y2-n+1, t.cols-1, y2);
}

SCROLL_DOWN(t: ref Term, nil, y1, nil, y2, n: int)
{
	for(i := y2; i >= y1+n; i--){
		t.scr[i] = t.scr[i-n];
		t.cc[i] = t.cc[i-n];
		markdirty(t, i);
	}
	CLEAR(t, 0, y1, t.cols-1, y1+n-1);
}

SCROLL_LEFT(t: ref Term, nil, y1, nil, y2, n: int)
{
	for(y := y1; y <= y2; y++){
		if(len t.scr[y] > n){
			t.scr[y] = t.scr[y][n:];
			t.cc[y] = t.cc[y][n:];
		} else {
			t.scr[y] = "";
			t.cc[y] = "";
		}
		markdirty(t, y);
	}
}

SCROLL_RIGHT(t: ref Term, nil, y1, nil, y2, n: int)
{
	for(y := y1; y <= y2; y++){
		t.scr[y] = t.pad[0:n] + t.scr[y];
		t.cc[y] = t.pad[0:n] + t.cc[y];
		markdirty(t, y);
	}
}

SET_COLOR(t: ref Term)
{
	if(t.attr & (1<<7))
		t.ccc = ((t.fg<<4) | t.bg);
	else
		t.ccc = ((t.bg<<4) | t.fg);
	if(t.attr & (1<<1))
		t.ccc ^= (1<<3);
}

BEEP(nil: ref Term)
{
}

TYPE(nil: ref Term, b: string)
{
	reply += b;
}

savestate(t: ref Term)
{
	t.save_x = t.x;
	t.save_y = t.y;
	t.save_attr = t.attr;
	t.save_fg = t.fg;
	t.save_bg = t.bg;
	t.save_mode = t.mode;
	t.save_qmode = t.qmode;
}

restorestate(t: ref Term)
{
	t.x = t.save_x;
	t.y = t.save_y;
	t.attr = t.save_attr;
	t.fg = t.save_fg;
	t.bg = t.save_bg;
	t.mode = t.save_mode;
	t.qmode = t.save_qmode;
	SET_COLOR(t);
}

vtinit(t: ref Term)
{
	t.fg = 7;
	t.bg = 0;
	t.attr = 0;
	t.mode = 0;
	t.qmode = (1<<7);
	t.y1 = 0;
	t.y2 = t.rows-1;
	t.x = 0;
	t.y = 0;
	t.dx = 1;
	t.dy = 1;
	t.nlcr = 1;	# Inferno/Plan 9 convention: \n is newline (CR+LF), not bare LF
	t.esc = 0;
	t.pcount = 0;
	savestate(t);
	SET_COLOR(t);
}

checkscroll(t: ref Term, s: string)
{
	i := 0;
	n: int;
	if(t.y == t.y2+1 || t.y >= t.rows){
		n = 1;
		while(i < len s && n < (t.y2-t.y1)){
			c := s[i++];
			if(c == 27 || c > 126 || c < 0)
				break;
			if(c == '\n')
				n++;
		}
		t.y = t.y2-n+1;
		SCROLL_UP(t, 0, t.y1, t.cols-1, t.y2, n);
	} else if(t.y == t.y1-1){
		t.y = t.y1;
		SCROLL_DOWN(t, 0, t.y1, t.cols-1, t.y2, 1);
	} else if(t.y < 0)
		t.y = 0;
}

vtwrite(t: ref Term, s: string)
{
	ch: int;
	check_scroll: int;
	n: int;
	i := 0;

	while(i < len s){
		check_scroll = 0;
		ch = s[i++];
		case t.esc {
		1 =>
			if(ch == '['){
				t.etype = ch;
				t.esc++;
				t.value = 0;
				t.pcount = 0;
				t.ptype = 1;
				for(n=0; n<VT_MAXPARAM; n++)
					t.param[n] = 0;
			} else {
				check_scroll = call_ncsi(t, ch);
				t.esc = 0;
			}
		2 =>
			if(ch >= '0' && ch <= '9')
				t.value = (t.value)*10+(ch-'0');
			else if(ch == '?')
				t.ptype = -1;
			else {
				t.param[t.pcount++] = t.value*t.ptype;
				if(ch == ';'){
					if(t.pcount >= VT_MAXPARAM)
						t.pcount = VT_MAXPARAM-1;
					t.value = 0;
				} else {
					check_scroll = call_csi(t, ch);
					t.esc = 0;
				}
			}
		* =>
			case ch {
			'\n' =>
				t.y += t.dy;
				check_scroll = 1;
				if(t.nlcr)
					t.x = 0;
			'\r' =>
				t.x = 0;
			'\b' =>
				if(t.x > 0)
					t.x -= t.dx;
			'\t' =>
				n = (t.x & ~7)+8;
				if(t.mode & (1<<4))
					SCROLL_RIGHT(t, t.x, t.y, t.cols-1, t.y, n - t.x);
				t.x = n;
				if(t.x > t.cols){
					t.x = 0;
					t.y++;
					check_scroll = 1;
				}
			7 =>
				BEEP(t);
			11 =>
				t.x = 0;
				t.y = t.y1;
			12 =>
				CLEAR(t, 0, t.y1, t.cols-1, t.y2);
			27 =>
				t.esc++;
			133 =>
				t.x = 0;
				t.y++;
				check_scroll = 1;
			132 =>
				t.y++;
				check_scroll = 1;
			141 =>
				t.y--;
				check_scroll = 1;
			147 =>
				t.esc = 2;
				t.etype = '[';
				t.esc++;
				t.value = 0;
				t.pcount = 0;
				t.ptype = 1;
				for(n=0; n<VT_MAXPARAM; n++)
					t.param[n] = 0;
			* =>
				if(t.mode & (1<<4))
					SCROLL_RIGHT(t, t.x, t.y, t.cols-1, t.y, 1);
				if(ch >= 32 || ch <= 126){
					if(t.qmode & (1<<15)){
						if(t.x >= t.cols-1 && (t.qmode & (1<<7))){
							t.x = 0;
							t.y += t.dy;
							checkscroll(t, s[i:]);
						}
						t.qmode &= ~(1<<15);
					}
					PUTCHAR(t, t.x, t.y, ch);
					if((t.x += t.dx) >= t.cols){
						t.x = t.cols-1;
						t.qmode |= (1<<15);
					}
				}
			}
		}
		if(check_scroll)
			checkscroll(t, s[i:]);
		if(t.x < 0)
			t.x = 0;
		else if(t.x >= t.cols)
			t.x = t.cols-1;
		if(t.y < 0)
			t.y = 0;
		else if(t.y >= t.rows)
			t.y = t.rows-1;
	}
}

call_csi(t: ref Term, ch: int): int
{
	i, n: int;
	case ch {
	'A' =>
		t.y -= param(t, 1,1,1,t.rows);
	'B' =>
		t.y += param(t, 1,1,1,t.rows);
	'C' =>
		t.x += param(t, 1,1,1,t.cols);
	'D' =>
		t.x -= param(t, 1,1,1,t.cols);
	'f' or 'H' =>
		t.y = param(t, 0,1,1,t.rows)-1;
		t.x = param(t, 1,1,1,t.cols)-1;
	'J' =>
		case t.param[0] {
		0 =>
			CLEAR(t, t.x, t.y, t.cols-1, t.y);
			CLEAR(t, 0, t.y+1, t.cols-1, t.y2);
		1 =>
			CLEAR(t, 0, 0, t.cols-1, t.y-1);
			CLEAR(t, 0, t.y, t.x, t.y);
		2 =>
			CLEAR(t, 0, t.y1, t.cols-1, t.y2);
		}
	'K' =>
		case t.param[0] {
		0 => CLEAR(t, t.x, t.y, t.cols-1, t.y);
		1 => CLEAR(t, 0, t.y, t.x, t.y);
		2 => CLEAR(t, 0, t.y, t.cols-1, t.y);
		}
	'L' =>
		n = param(t, 0,1,1,t.rows);
		SCROLL_DOWN(t, 0, t.y, t.cols-1, t.y2, n);
	'M' =>
		n = param(t, 0,1,1,t.rows);
		SCROLL_UP(t, 0, t.y, t.cols-1, t.y2, n);
	'@' =>
		n = param(t, 0,1,1,t.cols-1-t.x);
		SCROLL_RIGHT(t, t.x, t.y, t.cols-1, t.y, n);
	'P' =>
		n = param(t, 0,1,1,t.cols-1-t.x);
		SCROLL_LEFT(t, t.x, t.y, t.cols-1, t.y, n);
	'X' =>
		n = param(t, 0,1,1,t.cols-1-t.x);
		CLEAR(t, t.x, t.y, t.x+n-1, t.y);
	'm' =>
		if(t.pcount == 0)
			t.pcount++;
		for(i=0; i<t.pcount; i++){
			n = t.param[i];
			if(!n){
				t.attr = 0;
				t.fg = 7;
				t.bg = 0;
			} else if(n < 16)
				t.attr |= (1<<n);
			else if(n < 28)
				t.attr &= ~(1<<(n-20));
			else if(n < 38)
				t.fg = n-30;
			else if(n < 48)
				t.bg = n-40;
			else if(n < 58)
				t.fg = n-50+8;
			else if(n < 68)
				t.bg = n-60+8;
		}
		SET_COLOR(t);
	'c' =>
		if(t.cols >= 132)
			TYPE(t, "[?61;1;6c");
		else
			TYPE(t, "[?61;6c");
	'n' =>
		n = param(t, 0,0,0,9);
		if(n == 5)
			TYPE(t, "[0n");
		if(n == 5 || n == 6)
			TYPE(t, sprint("[%d;%dR", t.y+1, t.x+1));
	'r' =>
		t.y1 = param(t, 0,1,1,t.rows)-1;
		t.y2 = param(t, 1,t.rows,1,t.rows)-1;
	's' =>
		savestate(t);
	'u' =>
		restorestate(t);
	'h' =>
		for(i=0; i<t.pcount; i++){
			n = t.param[i];
			if(n >= 0)
				t.mode |= (1<<n);
			else
				t.qmode |= (1<<(-n));
		}
	'l' =>
		for(i=0; i<t.pcount; i++){
			n = t.param[i];
			if(n >= 0)
				t.mode &= ~(1<<n);
			else
				t.qmode &= ~(1<<(-n));
		}
	}

	if(t.y < 0)
		t.y = 0;
	if(t.y >= t.rows)
		t.y = t.rows-1;
	if(t.x < 0)
		t.x = 0;
	if(t.x >= t.cols)
		t.x = t.cols-1;
	return 0;
}

call_ncsi(t: ref Term, ch: int): int
{
	case ch {
	'E' =>
		t.x = 0;
	'D' =>
		t.y++;
		return 1;
	'M' =>
		t.y--;
		return 1;
	'7' =>
		savestate(t);
	'8' =>
		restorestate(t);
	}
	return 0;
}

param(t: ref Term, n, def, min, max: int): int
{
	p := t.param[n];
	if(p == 0)
		p = def;
	if(p < min)
		p = min;
	if(p > max)
		p = max;
	return p;
}

#############################################################################
# Termio: wire a Term to a spawned command over a private /dev/cons
#############################################################################

Termio.send(tio: self ref Termio, s: string)
{
	if(s != nil)
		tio.inp <-= s;
}

attach(ctxt: ref Draw->Context, cmd: list of string): ref Termio
{
	tio := ref Termio;
	tio.out = chan of string;
	tio.inp = chan of string;
	tio.raw = 0;

	ioc := chan of (int, ref FileIO, ref FileIO);
	spawn newcmd(ctxt, cmd, ioc);
	(pid, file, filectl) := <-ioc;
	if(file == nil || filectl == nil)
		return nil;
	tio.pid = pid;
	spawn iomanager(tio, file, filectl);
	return tio;
}

iomanager(tio: ref Termio, file, filectl: ref FileIO)
{
	sq := "";
	reads: list of (int, Rread);

	for(;;) alt {
	k := <-tio.inp =>
		if(tio.raw)
			sq += k;
		else {
			# cooked: minimal line discipline + local echo
			for(i := 0; i < len k; i++){
				c := k[i];
				if(c == '\b' || c == 16r7f){
					if(len sq > 0 && sq[len sq-1] != '\n'){
						sq = sq[0:len sq-1];
						tio.out <-= "\b \b";
					}
				} else if(c == '\n' || c == '\t' || c >= ' '){
					sq[len sq] = c;
					tio.out <-= sys->sprint("%c", c);
				}
			}
		}
		(sq, reads) = service(tio, sq, reads);

	(nil, nbytes, nil, rc) := <-file.read =>
		reads = (nbytes, rc) :: reads;
		(sq, reads) = service(tio, sq, reads);

	(nil, data, nil, wc) := <-file.write =>
		if(wc == nil)
			return;
		tio.out <-= string data;
		wc <-= (len data, nil);

	(nil, data, nil, wc) := <-filectl.write =>
		cs := string data;
		if(cs == "rawon")
			tio.raw = 1;
		else if(cs == "rawoff")
			tio.raw = 0;
		if(wc != nil)
			wc <-= (len data, nil);
	}
}

# satisfy as many queued reads as the buffer allows.  cooked mode hands over a
# line at a time; raw mode hands over whatever is available.  Reads are held in
# arrival order (the list is reversed for servicing).
service(tio: ref Termio, sq: string, reads: list of (int, Rread)): (string, list of (int, Rread))
{
	# process in arrival order
	rl := rev(reads);
	left: list of (int, Rread);
	stop := 0;
	for(; rl != nil; rl = tl rl){
		(nb, rc) := hd rl;
		if(stop){
			left = (nb, rc) :: left;
			continue;
		}
		avail := available(tio, sq);
		if(avail == 0){
			left = (nb, rc) :: left;
			stop = 1;
			continue;
		}
		n := nb;
		if(n > avail)
			n = avail;
		alt {
		rc <-= (array of byte sq[0:n], "") =>
			sq = sq[n:];
		* =>
			;	# requester gone; drop
		}
	}
	return (sq, left);
}

available(tio: ref Termio, sq: string): int
{
	if(tio.raw)
		return len sq;
	for(i := 0; i < len sq; i++)
		if(sq[i] == '\n')
			return i+1;
	return 0;
}

rev(l: list of (int, Rread)): list of (int, Rread)
{
	r: list of (int, Rread);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

newcmd(ctxt: ref Draw->Context, cmd: list of string, ioc: chan of (int, ref FileIO, ref FileIO))
{
	pid := sys->pctl(Sys->NEWFD, nil);
	# private environment for the command, so the readline enable below (and
	# any $prompt etc. it sets) does not leak back to whoever launched us.
	sys->pctl(Sys->FORKENV, nil);

	mod := load Command "/dis/sh.dis";
	if(cmd != nil){
		m := load Command "/dis/" + hd cmd + ".dis";
		if(m != nil)
			mod = m;
	}
	if(mod == nil){
		ioc <-= (0, nil, nil);
		return;
	}

	# Create the console file2chan in this (the command's) proc lineage, so
	# stat/fstat qids agree and the shell's isconsole() check passes.
	tty := "cons." + string pid;
	sys->bind("#s", "/chan", Sys->MBEFORE);
	fio := sys->file2chan("/chan", tty);
	fioctl := sys->file2chan("/chan", tty + "ctl");
	ioc <-= (pid, fio, fioctl);
	if(fio == nil || fioctl == nil)
		return;

	# bind the file2chan onto /dev/cons; it becomes this command's stdin/out/err
	# (fds 0,1,2 after the empty NEWFD).  These FD refs MUST stay live until the
	# command exits -- if they are dropped, the GC closes the console out from
	# under the shell and it runs non-interactively.
	sys->bind("/chan/"+tty, "/dev/cons", Sys->MREPL);
	sys->bind("/chan/"+tty+"ctl", "/dev/consctl", Sys->MREPL);

	fd0 := sys->open("/dev/cons", Sys->OREAD|Sys->ORCLOSE);
	fd1 := sys->open("/dev/cons", Sys->OWRITE);
	fd2 := sys->open("/dev/cons", Sys->OWRITE);

	# The VT is a real ANSI terminal, so the shell's raw-mode line editor runs
	# here -- Tab completion, history, emacs editing, drawn with the CSI subset
	# this widget renders.  Clear any inherited $noreadline: a VT launched from
	# a wm/sh inherits that flag (wm/sh sets it for its dumb Tk console), which
	# would otherwise disable the editor.  We do NOT set it.
	sys->remove("/env/noreadline");

	args := cmd;
	if(args == nil)
		args = "sh" :: "-n" :: nil;
	mod->init(ctxt, args);

	# keep the console fds referenced across the (blocking) command run
	fd0 = fd1 = fd2 = nil;
}

Command: type WmTermCmd;
WmTermCmd: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};
