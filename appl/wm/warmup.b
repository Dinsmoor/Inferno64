implement Warmup;

#
# wm/warmup -- the "Inferno is warming up" boot splash.
#
# Pops a small window with a burning-skeleton animation and pre-warms (loads +,
# under `emu -c1`, JIT-compiles) a configurable list of programs so they launch
# instantly later instead of stalling on first use.  The animation speeds up as
# each program is compiled.  The list comes from $home/lib/warmup, then
# /lib/warmup, else a built-in default.  With -t (or no draw context) it runs as
# a text-only progress line, for the console-only JIT.
#
# The loaded module handles are retained for the session (this proc parks after
# warming) so the compiled code stays resident -- that is what makes the warm-up
# actually save time at launch.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Context, Display, Image, Rect, Point: import draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "imagefile.m";
	rdimg: RImagefile;
	remap: Imageremap;
	Rawimage: import RImagefile;
include "tk.m";
	tk: Tk;
	Toplevel: import tk;
include "tkclient.m";
	tkclient: Tkclient;
include "loader.m";
	loader: Loader;

Warmup: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

GIF:	con "/lib/images/hell.gif";

# animation pacing, milliseconds per frame: slow at the start, fast at the end.
SLOW:	con 320;
FAST:	con 55;

# Let the desktop finish booting (its own -c1 load-compiles) before we start the
# background grind, so warming does not fight the wm coming up.
SETTLE:	con 1500;
# Small yield between modules so a user-triggered launch can grab the compile
# lock without the VM stalling, and so the CPU isn't pegged in one burst.
PACE:	con 30;

display: ref Display;
top: ref Toplevel;
warmed: list of Nilmod;		# retained so compiled modules stay resident

# Fallback when neither $home/lib/warmup nor /lib/warmup exists: the full wm
# launch menu (and submenus) -- the programs a user is most likely to reach for.
defaultprogs := array[] of {
	"wm/sh", "acme", "wm/edit", "charon", "wm/man", "wm/ftree",
	"wm/deb", "wm/rt", "wm/task", "wm/memory", "wm/about",
	"wm/coffee", "wm/colors", "wm/date",
	"wm/tetris", "wm/bounce", "wm/rayteapot",
};

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;

	sys->pctl(Sys->NEWPGRP, nil);

	textmode := 0;
	for(a := argv; a != nil; a = tl a)
		if(hd a == "-t")
			textmode = 1;

	progs := readlist();

	loader = load Loader Loader->PATH;

	# The warm-up only makes sense under the JIT (-c1): in pure-interpreter mode
	# there is nothing to compile, so skip the whole thing -- no splash, no work.
	if(loader == nil || loader->compiling() == 0)
		return;

	# The set we warm is the transitive module *closure* of the seed programs,
	# discovered below by closure() -- heavy apps pull in many modules at run time
	# (Charon alone: layout, jscript, csseng, dom, http, img, ...) and those, not
	# the entry .dis, are what make a first launch slow.  We discover it AFTER the
	# splash is up so the window appears immediately instead of after a blank gap.

	bufio = load Bufio Bufio->PATH;

	if(textmode){
		warmtext(closure(progs));
		return;
	}

	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	rdimg = load RImagefile RImagefile->READGIFPATH;
	remap = load Imageremap Imageremap->PATH;

	if(tk == nil || tkclient == nil){
		warmtext(closure(progs));
		return;
	}

	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	if(ctxt == nil){
		warmtext(closure(progs));
		return;
	}
	display = ctxt.display;

	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "Inferno", 0);

	frames := loadframes(GIF);

	# Content lives in a center frame (.f.c) packed with -expand so it floats in
	# the middle of the full-screen black backdrop (old-school "welcome" splash).
	cfg := array[] of {
		". configure -bd 0 -bg black",
		"frame .f -bg black",
		"frame .f.c -bg black",
		"label .f.c.t -text {Welcome to Hell} -bg black -fg #ff3300",
		"label .f.c.sub -text {Inferno is warming up...} -bg black -fg #ff9966",
		"panel .f.c.pic -bd 0 -bg black",
		"label .f.c.s -text {starting...} -bg black -fg #cfcfcf -anchor center",
		"pack .f.c.t -side top -fill x -pady 4",
		"pack .f.c.sub -side top -fill x",
		"pack .f.c.pic -side top -pady 4",
		"pack .f.c.s -side top -fill x -pady 2",
		"pack .f.c -expand 1",
		"pack .f -fill both -expand 1",
	};
	for(i := 0; i < len cfg; i++)
		tkcmd(cfg[i]);

	# Size the panel to the GIF *before* mapping so the window maps at the right
	# size, then map the window, then bind the image.  Order matters (mirrors
	# wm/coffee.b): a panel image bound with putimage only tracks later edits if
	# the window is already onscreen -- doing putimage before onscreen snapshots
	# just the first frame, which is why the skeleton showed but never animated.
	if(frames != nil && len frames > 0){
		fr0 := frames[0].r;
		tkcmd(sys->sprint(".f.c.pic configure -width %d -height %d", fr0.dx(), fr0.dy()));
	}
	# Cover the whole screen: size the toplevel to the display rect and reshape it
	# to fill, so the splash maps maximized (the centered .f.c floats in the middle).
	scr := Rect((0,0),(640,480));
	if(display.image != nil)
		scr = display.image.r;
	tkcmd(sys->sprint(". configure -width %d -height %d", scr.dx(), scr.dy()));
	tkcmd("update");
	tkclient->startinput(top, "ptr" :: "kbd" :: nil);
	tkclient->wmctl(top, sys->sprint("!reshape . -1 %d %d %d %d place",
		scr.min.x, scr.min.y, scr.max.x, scr.max.y));

	buffer: ref Image;
	if(frames != nil && len frames > 0){
		chans := draw->RGB24;
		if(top.image != nil)
			chans = top.image.chans;
		else if(display.image != nil)
			chans = display.image.chans;
		fr := frames[0].r;
		buffer = display.newimage(Rect((0,0),(fr.dx(),fr.dy())), chans, 0, draw->Black);
		if(buffer != nil){
			buffer.draw(buffer.r, frames[0], nil, frames[0].r.min);
			tk->putimage(top, ".f.c.pic", buffer, nil);
			tkcmd(".f.c.pic dirty; update");
		}
	}

	# Do the compiling in a SEPARATE proc and animate from THIS (the toplevel-
	# owning) proc.  Tk must be driven from the proc that owns the window -- like
	# wm/coffee.b -- otherwise `update` runs but never repaints (which is why the
	# skeleton showed but stayed frozen when a spawned proc drove the animation).
	prog := chan of (int, int, string);
	spawn warmer(progs, prog);
	animate(buffer, frames, prog);		# returns when the warmer signals done

	# warming finished: drop the splash window (the warmer proc holds `warmed`
	# resident for the rest of the session).
	top = nil;
}

# Background worker: discover the module closure and JIT-compile it, reporting
# (done, total, name) progress to the animator.  Does NO Tk -- that stays on the
# toplevel-owning proc.  Parks at the end holding `warmed` so the compiled
# modules stay resident for the session.
warmer(progs: array of string, prog: chan of (int, int, string))
{
	prog <-= (0, 0, "discovering modules...");
	allmods := closure(progs);

	# let the desktop finish its own boot compiles before the big grind
	sys->sleep(SETTLE);

	n := len allmods;
	for(i := 0; i < n; i++){
		prog <-= (i, n, "compiling " + shortname(allmods[i]));
		c := warm(allmods[i]);
		if(c != nil)
			warmed = c :: warmed;
		# compilebg releases the VM so the animator keeps running during each
		# compile; this small yield keeps the desktop responsive to launches too.
		sys->sleep(PACE);
	}
	prog <-= (n, n, "ready");
	sys->sleep(700);
	prog <-= (-1, 0, "");			# tell the animator to stop

	park := chan of int;
	<-park;
}

# Decode an animated GIF into a sequence of ready-to-draw images.
loadframes(path: string): array of ref Image
{
	stderr := sys->fildes(2);
	if(bufio == nil || rdimg == nil || remap == nil){
		sys->fprint(stderr, "warmup: image modules unavailable\n");
		return nil;
	}
	fd := bufio->open(path, Bufio->OREAD);
	if(fd == nil){
		sys->fprint(stderr, "warmup: cannot open %s: %r\n", path);
		return nil;
	}
	rdimg->init(bufio);
	(raws, err) := rdimg->readmulti(fd);
	if(raws == nil || err != nil){
		sys->fprint(stderr, "warmup: decode %s failed: %s\n", path, err);
		return nil;
	}
	remap->init(display);
	frames := array[len raws] of ref Image;
	nf := 0;
	for(i := 0; i < len raws; i++){
		(im, nil) := remap->remap(raws[i], display, 1);
		if(im != nil)
			frames[nf++] = im;
	}
	if(nf == 0)
		return nil;
	return frames[0:nf];
}

# Runs on the toplevel-owning proc: cycle GIF frames into the panel and show the
# warmer's progress, until it signals done (done < 0).
animate(buffer: ref Image, frames: array of ref Image, prog: chan of (int, int, string))
{
	done := 0;
	total := 0;
	fi := 0;
	for(;;){
		if(buffer != nil && frames != nil && len frames > 0){
			f := frames[fi];
			buffer.draw(buffer.r, f, nil, f.r.min);
			tkcmd(".f.c.pic dirty; update");
			fi = (fi + 1) % len frames;
		}
		# pull the latest progress without blocking the animation
		alt {
		(d, t, txt) := <-prog =>
			if(d < 0)
				return;
			done = d;
			total = t;
			tkcmd(".f.c.s configure -text {" + txt + "}");
			tkcmd("update");
		* =>
			;
		}
		# speed scales from SLOW (nothing done) to FAST (all done)
		interval := SLOW;
		if(total > 0){
			d := SLOW - FAST;
			interval = FAST + (d * (total - done)) / total;
			if(interval < FAST)
				interval = FAST;
		}
		sys->sleep(interval);
	}
}

# Text-only progress, for the console-only JIT (no draw context).
warmtext(mods: array of string)
{
	stderr := sys->fildes(2);
	sys->fprint(stderr, "Inferno is warming up...\n");
	n := len mods;
	for(i := 0; i < n; i++){
		sys->fprint(stderr, "\r[%3d/%3d] compiling %-32s", i+1, n, shortname(mods[i]));
		c := warm(mods[i]);
		if(c != nil)
			warmed = c :: warmed;
	}
	sys->fprint(stderr, "\rwarmed %d module(s)%34s\n", len warmed, "");
}

# Warm one program by path, returning a retained handle (held for the session so
# the compiled code stays resident).  We load it *interpreted* (deferring the
# JIT via loader->nocompile) so we can then compile it in the BACKGROUND with
# loader->compilebg, which releases the VM scheduler while the compiler runs --
# that is what lets the splash animation keep moving instead of freezing.
warm(p: string): Nilmod
{
	file := respath(p);

	# defer compilation so the load returns an interpreted module to JIT later
	if(loader != nil)
		loader->nocompile(1);
	mp := load Nilmod file;
	if(loader != nil)
		loader->nocompile(0);

	# compile off the VM scheduler thread; the animator keeps running meanwhile
	if(mp != nil && loader != nil)
		loader->compilebg(mp, 1);
	return mp;
}

# Resolve a config name ("charon", "wm/sh") to the canonical /dis path the
# launcher (sh `wmrun <app>`) uses, so the global module cache (keyed by path
# string) hits when the app is later launched.  Already-resolved /dis paths
# (from closure discovery) pass through unchanged.
respath(p: string): string
{
	file := p;
	if(len file < 4 || file[len file-4:] != ".dis")
		file += ".dis";
	if(len file > 0 && file[0] != '/')
		file = "/dis/" + file;
	return file;
}

# Trim the leading "/dis/" for a tidier progress label.
shortname(path: string): string
{
	if(len path > 5 && path[0:5] == "/dis/")
		return path[5:];
	return path;
}

# Read the warm-up list: $home/lib/warmup, then /lib/warmup, else the default.
readlist(): array of string
{
	user := trim(readfile("/dev/user"));
	if(user != nil){
		l := parselist(readfile("/usr/" + user + "/lib/warmup"));
		if(l != nil)
			return l;
	}
	l := parselist(readfile("/lib/warmup"));
	if(l != nil)
		return l;
	return defaultprogs;
}

parselist(s: string): array of string
{
	if(s == nil)
		return nil;
	progs: list of string;
	nprogs := 0;
	start := 0;
	for(i := 0; i <= len s; i++){
		if(i == len s || s[i] == '\n'){
			line := trim(s[start:i]);
			start = i + 1;
			if(line == nil || line[0] == '#')
				continue;
			progs = line :: progs;
			nprogs++;
		}
	}
	if(nprogs == 0)
		return nil;
	a := array[nprogs] of string;
	# parselist built the list in reverse; restore file order.
	for(p := progs; p != nil; p = tl p)
		a[--nprogs] = hd p;
	return a;
}

trim(s: string): string
{
	if(s == nil)
		return nil;
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r' || s[j-1] == '\n'))
		j--;
	return s[i:j];
}

readfile(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}

# Transitive module closure reachable from the seed programs, in discovery order
# (each seed roughly followed by the modules it pulls in), deduplicated.  Found
# by scanning each .dis image for the "/dis/.../X.dis" path constants of the
# modules it loads -- `load X X->PATH` bakes that path into the data section, so
# a depth-first walk over those strings recovers the whole runtime closure.
closure(seeds: array of string): array of string
{
	work: list of string;			# DFS stack of resolved paths still to scan
	for(i := len seeds - 1; i >= 0; i--)
		work = respath(seeds[i]) :: work;

	order: list of string;			# result, built in reverse
	norder := 0;
	while(work != nil){
		path := hd work;
		work = tl work;
		if(inlist(path, order))
			continue;
		order = path :: order;
		norder++;
		data := readbytes(path);
		if(data == nil)
			continue;
		for(d := scandeps(data); d != nil; d = tl d){
			dp := hd d;
			if(!inlist(dp, order) && !inlist(dp, work))
				work = dp :: work;
		}
	}
	a := array[norder] of string;
	for(p := order; p != nil; p = tl p)	# `order` is reversed -> restore
		a[--norder] = hd p;
	return a;
}

# Read a whole file as bytes (nil on failure).  .dis files are well under 8MB.
readbytes(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, dir) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	n := int dir.length;
	if(n <= 0 || n > 8*1024*1024)
		return nil;
	buf := array[n] of byte;
	off := 0;
	while(off < n){
		m := sys->read(fd, buf[off:], n - off);
		if(m <= 0)
			break;
		off += m;
	}
	if(off != n)
		return buf[0:off];
	return buf;
}

# Extract embedded "/dis/.../X.dis" module paths from a .dis image.
scandeps(data: array of byte): list of string
{
	deps: list of string;
	n := len data;
	i := 0;
	while(i + 5 <= n){
		if(data[i]==byte '/' && data[i+1]==byte 'd' && data[i+2]==byte 'i'
		&& data[i+3]==byte 's' && data[i+4]==byte '/'){
			j := i + 5;
			while(j < n && ispathc(int data[j]))
				j++;
			e := finddis(data, i + 5, j);
			if(e > 0){
				deps = (string data[i:e]) :: deps;
				i = e;
				continue;
			}
		}
		i++;
	}
	return deps;
}

# Index just past the first ".dis" within data[a:b], or 0 if none.
finddis(data: array of byte, a, b: int): int
{
	for(k := a; k + 4 <= b; k++)
		if(data[k]==byte '.' && data[k+1]==byte 'd' && data[k+2]==byte 'i' && data[k+3]==byte 's')
			return k + 4;
	return 0;
}

ispathc(c: int): int
{
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
		|| c == '/' || c == '.' || c == '_' || c == '-';
}

inlist(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

tkcmd(s: string): string
{
	r := tk->cmd(top, s);
	if(len r > 0 && r[0] == '!')
		sys->fprint(sys->fildes(2), "warmup: tk error: %s: %s\n", s, r[1:]);
	return r;
}
