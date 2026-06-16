implement Theme;

#
# theme - desktop theming for wm.  Today it manages the mouse cursor; it is
# meant to grow other theme controls (colours, fonts) over time.
#
#	theme --cursor                  install the showcase animated gauntlet
#	theme --cursor off              revert to the system default arrow
#	theme --cursor [-d ms] file...  install file(s) as the cursor (one-shot)
#	theme --cursor-default [file]   set the desktop/login default cursor
#
# --cursor is a one-shot: it writes the cursor now.  --cursor-default sets the
# cursor the wm shows on the desktop and restores when the pointer leaves a
# window (it talks to the running wm via /chan/wmcursor, falling back to a
# direct device write when no wm is present); with no file it picks the
# conservative TempleOS arrow.
#
# A single .cur or .ani -- or several, concatenated into one animation -- is
# decoded natively (Curfile) with no display needed.  Plain image files
# (PNG/JPEG/GIF/...) are decoded through the display instead.  Once written the
# cursor is owned by the host/kernel and keeps animating after this command
# exits, so an application can set it on window enter and clear it on leave.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Point: import draw;
include "imageload.m";
	imageload: Imageload;
include "curfile.m";
	curfile: Curfile;
include "acursor.m";
	acursor: Acursor;

DEFCUR:		con "/icons/cursors/uo/gauntlet-anim.ani";		# --cursor showcase
DEFARROW:	con "/icons/cursors/templeos/arrow_dark-outline.cur";	# conservative default
WMCURSOR:	con "/chan/wmcursor";					# wm default-cursor control
WMTHEME:	con "/chan/wmtheme";					# wm theme control
THEMEDIR:	con "/lib/themes";					# preset theme files

# Recognised theme keys (mirror the libtk "theme set" command, thm.c).
themekeys := array[] of {
	"fg", "foreground", "bg", "background", "activebg", "activefg",
	"select", "selectbg", "selectfg", "disablefg",
	"font", "borderwidth", "relief",
};

Theme: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

usage()
{
	sys->fprint(sys->fildes(2),
		"usage: theme --cursor [off] [-d ms] [file...]\n"+
		"       theme --cursor-default [file]\n"+
		"       theme --apply [name]        apply+persist a preset (default: default)\n"+
		"       theme --theme key=val ...   live ad-hoc colour/font overrides\n"+
		"       theme --font path           live default-font override\n"+
		"       theme --list                list available presets\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	acursor = load Acursor Acursor->PATH;
	if(acursor == nil)
		fail(sys->sprint("cannot load %s: %r", Acursor->PATH));
	acursor->init();

	argv = tl argv;			# drop argv0
	if(argv == nil)
		usage();
	case hd argv {
	"--cursor" or "-cursor" or "cursor" =>
		cursor(tl argv);
	"--cursor-default" or "-cursor-default" or "cursor-default" =>
		cursordefault(tl argv);
	"--apply" or "-apply" or "apply" =>
		applytheme(tl argv);
	"--theme" or "-theme" or "theme" =>
		adhoctheme(tl argv);
	"--font" or "-font" or "font" =>
		fonttheme(tl argv);
	"--list" or "-list" or "list" =>
		listthemes();
	* =>
		usage();
	}
}

# Apply a preset theme file (/lib/themes/<name>, or an absolute path): push it
# live to the running wm and persist the choice to $home/lib/theme so the wm
# re-applies it at the next login.
applytheme(argv: list of string)
{
	name := "default";
	if(argv != nil)
		name = hd argv;
	args := resolvetheme(name);
	if(args == nil)
		fail(sys->sprint("cannot read theme %q", name));
	pushtheme(args);
	savetheme(args);
}

# Live ad-hoc overrides: theme --theme bg=#303030 fg=#d0d0d0 ...  (not persisted)
adhoctheme(argv: list of string)
{
	if(argv == nil)
		usage();
	args := "set";
	for(; argv != nil; argv = tl argv){
		kv := hd argv;
		eq := -1;
		for(i := 0; i < len kv; i++)
			if(kv[i] == '='){
				eq = i;
				break;
			}
		if(eq <= 0)
			usage();
		key := kv[0:eq];
		if(!knownkey(key))
			fail("unknown theme key " + key);
		args += " " + key + " " + kv[eq+1:];
	}
	pushtheme(args);
}

# Live default-font override (not persisted).
fonttheme(argv: list of string)
{
	if(argv == nil)
		usage();
	pushtheme("set font " + hd argv);
}

listthemes()
{
	fd := sys->open(THEMEDIR, Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("cannot open %s: %r", THEMEDIR));
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			sys->print("%s\n", d[i].name);
	}
}

# Resolve a theme file (key value lines, '#' starts a comment line) into the
# libtk "set <key> <val> ..." argument string.  Unknown keys are skipped.
resolvetheme(name: string): string
{
	path := name;
	if(len name == 0 || (name[0] != '/' && name[0] != '.'))
		path = THEMEDIR + "/" + name;
	data := readall(path);
	if(data == nil)
		return nil;
	args := "set";
	i := 0;
	n := len data;
	while(i < n){
		j := i;
		while(j < n && data[j] != '\n')
			j++;
		line := data[i:j];
		i = j + 1;
		p := 0;
		while(p < len line && (line[p]==' ' || line[p]=='\t'))
			p++;
		if(p >= len line || line[p] == '#')		# blank or comment line
			continue;
		w := words(line);
		if(w == nil || tl w == nil)
			continue;
		key := hd w;
		if(!knownkey(key)){
			sys->fprint(sys->fildes(2), "theme: %s: unknown key %q\n", path, key);
			continue;
		}
		args += " " + key + " " + hd tl w;
	}
	if(args == "set")
		return nil;
	return args;
}

knownkey(k: string): int
{
	for(i := 0; i < len themekeys; i++)
		if(themekeys[i] == k)
			return 1;
	return 0;
}

# Push resolved "set ..." args to the running wm (live re-theme of every
# window).  Warn if no wm is serving the control file.
pushtheme(args: string)
{
	fd := sys->open(WMTHEME, Sys->OWRITE);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "theme: no running wm at %s: %r\n", WMTHEME);
		return;
	}
	if(sys->fprint(fd, "%s", args) < 0)
		fail(sys->sprint("write %s: %r", WMTHEME));
}

# Persist the resolved theme so the wm re-applies it at next login.
savetheme(args: string)
{
	path := themefile();
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil){
		# the lib/ directory may not exist yet for a fresh user
		dir := path;
		for(i := len dir - 1; i >= 0; i--)
			if(dir[i] == '/'){
				dir = dir[0:i];
				break;
			}
		df := sys->create(dir, Sys->OREAD, Sys->DMDIR | 8r755);
		if(df != nil)
			fd = sys->create(path, Sys->OWRITE, 8r644);
	}
	if(fd == nil){
		sys->fprint(sys->fildes(2), "theme: cannot save %s: %r\n", path);
		return;
	}
	sys->fprint(fd, "%s\n", args);
}

# Must match wm.b's resolution (home = /usr/<user>, from /dev/user) so a saved
# theme lands exactly where the wm reads it at login.
themefile(): string
{
	u := readuser();
	if(u == nil)
		u = "inferno";
	return "/usr/" + u + "/lib/theme";
}

readuser(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[512] of byte;
	m := sys->read(fd, buf, len buf);
	if(m <= 0)
		return nil;
	s := string buf[0:m];
	while(len s > 0 && (s[len s-1]=='\n' || s[len s-1]=='\0' || s[len s-1]==' '))
		s = s[0:len s-1];
	return s;
}

readall(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[4096] of byte;
	for(;;){
		m := sys->read(fd, buf, len buf);
		if(m <= 0)
			break;
		s += string buf[0:m];
	}
	return s;
}

words(s: string): list of string
{
	rev: list of string;
	i := 0;
	n := len s;
	while(i < n){
		while(i < n && (s[i]==' ' || s[i]=='\t'))
			i++;
		if(i >= n)
			break;
		j := i;
		while(j < n && s[j]!=' ' && s[j]!='\t')
			j++;
		rev = s[i:j] :: rev;
		i = j;
	}
	res: list of string;
	for(; rev != nil; rev = tl rev)
		res = hd rev :: res;
	return res;
}

# Set the desktop/login default cursor.  Prefer the running wm's control file
# (so the change is live and the wm restores this cursor on window-leave); when
# no wm is serving it, write the device directly.  With no file, use the
# conservative TempleOS arrow.
cursordefault(argv: list of string)
{
	path := DEFARROW;
	if(argv != nil)
		path = hd argv;
	wfd := sys->open(WMCURSOR, Sys->OWRITE);
	if(wfd != nil && sys->fprint(wfd, "%s", path) >= 0)
		return;
	cfd := sys->open("/dev/cursor", Sys->OWRITE);
	if(cfd == nil)
		fail(sys->sprint("cannot open /dev/cursor: %r"));
	installnative(cfd, path :: nil, Acursor->DEFMS);
}

cursor(argv: list of string)
{
	delayms := Acursor->DEFMS;
	rev: list of string;
	while(argv != nil){
		case hd argv {
		"-d" =>
			argv = tl argv;
			if(argv == nil)
				usage();
			delayms = int hd argv;
		* =>
			rev = hd argv :: rev;
		}
		argv = tl argv;
	}
	files: list of string;
	for(; rev != nil; rev = tl rev)		# undo the reverse from the scan
		files = hd rev :: files;

	cfd := sys->open("/dev/cursor", Sys->OWRITE);
	if(cfd == nil)
		fail(sys->sprint("cannot open /dev/cursor: %r"));

	# theme --cursor off  ->  back to the default arrow
	if(files != nil && tl files == nil && (hd files == "off" || hd files == "none")){
		if((err := acursor->clear(cfd)) != nil)
			fail(err);
		return;
	}
	# theme --cursor  (no file)  ->  the default animated gauntlet
	if(files == nil){
		if((err := installdefault(cfd)) != nil)
			fail(err);
		return;
	}
	if(allnative(files))
		installnative(cfd, files, delayms);
	else
		installimages(cfd, files, delayms);
}

# Default cursor: the vendored animated gauntlet, falling back to a generated
# one if the asset is missing (e.g. a minimal namespace without /icons).
installdefault(cfd: ref Sys->FD): string
{
	(c, err) := loadcur(DEFCUR);
	if(err == nil)
		return acursor->setraw(cfd, (c.hotx, c.hoty), c.w, c.h, c.frames, c.delays);
	(w, h, frames, hot) := gauntlet();
	delays := array[len frames] of {* => 120};
	return acursor->setraw(cfd, hot, w, h, frames, delays);
}

loadcur(path: string): (ref Curfile->Cursor, string)
{
	if(curfile == nil){
		curfile = load Curfile Curfile->PATH;
		if(curfile == nil)
			return (nil, sys->sprint("cannot load %s: %r", Curfile->PATH));
		curfile->init();
	}
	return curfile->readfile(path);
}

# Install one or more .cur/.ani files as a single animation (frames in order).
installnative(cfd: ref Sys->FD, files: list of string, delayms: int)
{
	revf: list of array of byte;
	revd: list of int;
	w := 0;
	h := 0;
	hotx := 0;
	hoty := 0;
	first := 1;
	for(l := files; l != nil; l = tl l){
		(c, err) := loadcur(hd l);
		if(err != nil)
			fail(err);
		if(first){
			w = c.w;
			h = c.h;
			hotx = c.hotx;
			hoty = c.hoty;
			first = 0;
		}else if(c.w != w || c.h != h)
			fail(sys->sprint("%s: %dx%d, expected %dx%d", hd l, c.w, c.h, w, h));
		for(i := 0; i < len c.frames; i++){
			revf = c.frames[i] :: revf;
			d := c.delays[i];
			if(d <= 0)
				d = delayms;
			revd = d :: revd;
		}
	}
	nf := len revf;
	frames := array[nf] of array of byte;
	delays := array[nf] of int;
	i := nf;
	for(; revf != nil; revf = tl revf)
		frames[--i] = hd revf;
	i = nf;
	for(; revd != nil; revd = tl revd)
		delays[--i] = hd revd;
	if((err := acursor->setraw(cfd, (hotx, hoty), w, h, frames, delays)) != nil)
		fail(err);
}

# Install plain image files (PNG/JPEG/...) as cursor frames; needs a display.
installimages(cfd: ref Sys->FD, files: list of string, delayms: int)
{
	draw = load Draw Draw->PATH;
	display := Display.allocate(nil);
	if(display == nil)
		fail(sys->sprint("cannot open display: %r"));
	imageload = load Imageload Imageload->PATH;
	if(imageload == nil)
		fail(sys->sprint("cannot load %s: %r", Imageload->PATH));
	imageload->init();
	n := len files;
	frames := array[n] of ref Image;
	for(i := 0; i < n; i++){
		(img, err) := imageload->readfile(display, hd files);
		if(img == nil)
			fail(sys->sprint("%s: %s", hd files, err));
		frames[i] = img;
		files = tl files;
	}
	delays := array[n] of {* => delayms};
	if((err := acursor->set(cfd, (0,0), frames, delays)) != nil)
		fail(err);
}

allnative(files: list of string): int
{
	for(l := files; l != nil; l = tl l)
		if(!hassuffix(hd l, ".cur") && !hassuffix(hd l, ".ani"))
			return 0;
	return 1;
}

hassuffix(s, suf: string): int
{
	if(len s < len suf)
		return 0;
	t := s[len s - len suf:];
	# case-insensitive
	for(i := 0; i < len suf; i++){
		c := t[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		if(c != suf[i])
			return 0;
	}
	return 1;
}

# A generated animated gauntlet (armoured fist), 20x22, hotspot near the top.
# Used only as a fallback when the vendored .ani asset is unavailable.  Returns
# (w, h, frames, hotspot); each frame is w*h*4 straight-alpha A,R,G,B.  The base
# sprite is drawn once from an ASCII silhouette (auto-outlined from the mask);
# the frames differ only by a metallic gleam swept diagonally across the armour.
gauntlet(): (int, int, array of array of byte, Point)
{
	# '#' steel, 'g' gold cuff, 'v' knuckle groove, '.' transparent
	rows := array[] of {
	"....................",
	".....#..#..#..#.....",
	".....##.##.##.##....",
	".....##v##v##v##....",
	"....###v##v##v###...",
	"...##############...",
	"...##############...",
	"..################..",
	"..################..",
	"..################..",
	"..################..",
	".#################..",
	"##################..",
	"##################..",
	".#################..",
	"..################..",
	"..gggggggggggggggg..",
	"..gggggggggggggggg..",
	"..gggggggggggggggg..",
	"..gggggggggggggggg..",
	"...gggggggggggggg...",
	"....gggggggggggg....",
	};
	W := 20;
	H := len rows;
	N := 5;
	BW := 7.0;			# gleam band half-width

	# material: 0 empty, 1 steel, 2 gold, 3 groove
	mat := array[W*H] of {* => 0};
	for(y := 0; y < H; y++){
		r := rows[y];
		for(x := 0; x < W && x < len r; x++){
			case r[x] {
			'#' =>	mat[y*W+x] = 1;
			'g' =>	mat[y*W+x] = 2;
			'v' =>	mat[y*W+x] = 3;
			}
		}
	}

	# base colour (gleam-free) and an outline flag for silhouette-edge pixels
	br := array[W*H] of {* => 0};
	bg := array[W*H] of {* => 0};
	bb := array[W*H] of {* => 0};
	outline := array[W*H] of {* => 0};
	for(y = 0; y < H; y++){
		t := real y / real (H-1);
		steel := 1.2 - 0.42*t;		# top brighter than bottom -> volume
		gold := 1.15 - 0.35*t;
		for(x := 0; x < W; x++){
			m := mat[y*W+x];
			if(m == 0)
				continue;
			edge := x==0 || y==0 || x==W-1 || y==H-1
				|| mat[y*W+x-1]==0 || mat[y*W+x+1]==0
				|| mat[(y-1)*W+x]==0 || mat[(y+1)*W+x]==0;
			if(edge){
				outline[y*W+x] = 1;
				br[y*W+x] = 28; bg[y*W+x] = 28; bb[y*W+x] = 38;
				continue;
			}
			cr, cg, cb: real;
			case m {
			2 =>	cr = 205.0*gold; cg = 165.0*gold; cb = 75.0*gold;
			3 =>	cr = 60.0*steel; cg = 64.0*steel; cb = 72.0*steel;
			* =>	cr = 120.0*steel; cg = 128.0*steel; cb = 145.0*steel;
			}
			br[y*W+x] = clamp(int cr);
			bg[y*W+x] = clamp(int cg);
			bb[y*W+x] = clamp(int cb);
		}
	}

	P := W + H;			# diagonal period; gleam wraps for a seamless loop
	frames := array[N] of array of byte;
	for(f := 0; f < N; f++){
		cf := f * P / N;
		fb := array[W*H*4] of {* => byte 0};
		for(y = 0; y < H; y++){
			for(x := 0; x < W; x++){
				m := mat[y*W+x];
				if(m == 0)
					continue;
				o := (y*W+x)*4;
				rr := br[y*W+x];
				gg := bg[y*W+x];
				bv := bb[y*W+x];
				if(!outline[y*W+x]){
					raw := ((x+y - cf) % P + P) % P;
					dist := raw;
					if(P - raw < dist)
						dist = P - raw;
					if(real dist < BW){
						peak := 0.9;
						if(m == 2)
							peak = 0.7;
						inten := (1.0 - real dist/BW) * peak;
						rr = clamp(rr + int (real (255-rr)*inten));
						gg = clamp(gg + int (real (255-gg)*inten));
						bv = clamp(bv + int (real (255-bv)*inten));
					}
				}
				fb[o+0] = byte 255;
				fb[o+1] = byte rr;
				fb[o+2] = byte gg;
				fb[o+3] = byte bv;
			}
		}
		frames[f] = fb;
	}
	return (W, H, frames, (9, 2));
}

clamp(v: int): int
{
	if(v < 0)
		return 0;
	if(v > 255)
		return 255;
	return v;
}

fail(s: string)
{
	sys->fprint(sys->fildes(2), "theme: %s\n", s);
	raise "fail:error";
}
