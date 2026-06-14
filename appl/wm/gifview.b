implement GifView;

#
# gifview -- play an animated image (GIF / WebP, or any still) in a wm window.
#
#	wm/gifview file
#
# A thin demo of the Imageanim library: it opens a Player on the file's bytes,
# puts the player's surface into a Tk panel, and on each `updated` pulse marks
# the panel dirty so wm repaints just that region.  The player paces itself on
# its own proc; this proc only owns the window.
#
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "imageio.m";
include "imageanim.m";
	imageanim: Imageanim;
	Player: import imageanim;

GifView: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	imageanim = load Imageanim Imageanim->PATH;
	stderr = sys->fildes(2);
	if(tk == nil || tkclient == nil || imageanim == nil){
		sys->fprint(stderr, "gifview: missing module: %r\n");
		return;
	}
	tkclient->init();
	imageanim->init();

	if(tl argv == nil){
		sys->fprint(stderr, "usage: wm/gifview file\n");
		return;
	}
	file := hd tl argv;
	(data, rerr) := readfile(file);
	if(data == nil){
		sys->fprint(stderr, "gifview: %s: %s\n", file, rerr);
		return;
	}

	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	(win, wmcmd) := tkclient->toplevel(ctxt, "", file, Tkclient->Resize | Tkclient->Hide);
	sys->pctl(Sys->NEWPGRP, nil);

	# use ctxt.display (the framebuffer, valid now) -- win.image is not
	# allocated until onscreen(), which happens further down.
	updated := chan of int;
	(player, err) := imageanim->open(ctxt.display, data, updated);
	if(player == nil){
		sys->fprint(stderr, "gifview: %s: %s\n", file, err);
		return;
	}

	cfg := array[] of {
		"frame .f -bd 2",
		"panel .f.p -width " + string player.w + " -height " + string player.h,
		"pack .f.p -fill both -expand 1",
		"pack .f -side top -fill both -expand 1",
		"update",
	};
	for(i := 0; i < len cfg; i++)
		tk->cmd(win, cfg[i]);
	tkclient->onscreen(win, nil);
	tkclient->startinput(win, "kbd"::"ptr"::nil);
	tk->putimage(win, ".f.p", player.img, nil);

	dirty := ".f.p dirty 0 0 " + string player.w + " " + string player.h;
	player.start();

	for(;;) alt {
	<-updated =>
		tk->cmd(win, dirty);
		tk->cmd(win, "update");
	k := <-win.ctxt.kbd =>
		tk->keyboard(win, k);
	p := <-win.ctxt.ptr =>
		tk->pointer(win, *p);
	c := <-win.ctxt.ctl or
	c = <-win.wreq =>
		tkclient->wmctl(win, c);
	c := <-wmcmd =>
		case c {
		"exit" =>
			player.stop();
			return;
		* =>
			tkclient->wmctl(win, c);
		}
	}
}

readfile(file: string): (array of byte, string)
{
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%r"));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return (nil, sys->sprint("%r"));
	n := int d.length;
	if(n <= 0)
		return (nil, "empty file");
	buf := array[n] of byte;
	off := 0;
	while(off < n){
		m := sys->read(fd, buf[off:], n - off);
		if(m <= 0)
			break;
		off += m;
	}
	return (buf[0:off], nil);
}
