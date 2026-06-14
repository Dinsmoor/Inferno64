implement Wm;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Screen, Display, Image, Rect, Point, Wmcontext, Pointer: import draw;
include "wmsrv.m";
	wmsrv: Wmsrv;
	Window, Client: import wmsrv;
include "tk.m";
include "wmclient.m";
	wmclient: Wmclient;
include "string.m";
	str: String;
include "sh.m";
include "winplace.m";
	winplace: Winplace;

Wm: module {
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Ptrstarted, Kbdstarted, Controlstarted, Controller, Fixedorigin: con 1<<iota;
Bdwidth: con 3;
Sminx, Sminy, Smaxx, Smaxy: con iota;
Minx, Miny, Maxx, Maxy: con 1<<iota;
Background: con int 16r777777FF;

Handle: con 5;		# px grab margin at a window edge for direct resize
Snapdist: con 16;	# px: snap a dragged window edge flush to the work-area edge
Edgezone: con 12;	# px: pointer this close to a work-area edge arms an aero snap
Minwinx: con 60;	# smallest window the wm will resize a window to
Minwiny: con 28;
ZR: con Rect((0, 0), (0, 0));

Nws: con 4;		# number of virtual workspaces
Allws: con -1;		# a client pinned to every workspace (the toolbar)

screen: ref Screen;
display: ref Display;
ptrfocus: ref Client;
kbdfocus: ref Client;
controller: ref Client;
curws := 0;		# currently shown workspace
allowcontrol := 1;
fakekbd: chan of string;
fakekbdin: chan of string;
buttons := 0;

badmodule(p: string)
{
	sys->fprint(sys->fildes(2), "wm: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys  = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	if(draw == nil)
		badmodule(Draw->PATH);

	str = load String String->PATH;
	if(str == nil)
		badmodule(String->PATH);

	wmsrv = load Wmsrv Wmsrv->PATH;
	if(wmsrv == nil)
		badmodule(Wmsrv->PATH);

	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil)
		badmodule(Wmclient->PATH);
	wmclient->init();

	winplace = load Winplace Winplace->PATH;
	if(winplace == nil)
		badmodule(Winplace->PATH);
	winplace->init();

	sys->pctl(Sys->NEWPGRP|Sys->FORKNS, nil);
	if (ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	display = ctxt.display;

	buts := Wmclient->Appl;
	if(ctxt.wm == nil)
		buts = Wmclient->Plain;
	win := wmclient->window(ctxt, "Wm", buts);
	wmclient->win.reshape(((0, 0), (100, 100)));
	wmclient->win.onscreen("place");
	if(win.image == nil){
		sys->fprint(sys->fildes(2), "wm: cannot get image to draw on\n");
		raise "fail:no image";
	}
	wmclient->win.startinput("kbd" :: "ptr" :: nil);

	wmctxt := win.ctxt;
	screen = makescreen(win.image);

	(clientwm, join, req) := wmsrv->init();
	clientctxt := ref Draw->Context(ctxt.display, nil, clientwm);

	wmrectIO := sys->file2chan("/chan", "wmrect");
	if(wmrectIO == nil)
		fatal(sys->sprint("cannot make /chan/wmrect: %r"));

	sync := chan of string;
	argv = tl argv;
	if(argv == nil)
		argv = "wm/toolbar" :: nil;
	spawn command(clientctxt, argv, sync);
	if((e := <-sync) != nil)
		fatal("cannot run command: " + e);

	fakekbd = chan of string;
	for(;;) alt {
	c := <-win.ctl or
	c = <-wmctxt.ctl =>
		# XXX could implement "pleaseexit" in order that
		# applications can raise a warning message before
		# they're unceremoniously dumped.
		if(c == "exit")
			for(z := wmsrv->top(); z != nil; z = z.znext)
				z.ctl <-= "exit";

		wmclient->win.wmctl(c);
		if(win.image != screen.image)
			reshaped(win);
	c := <-wmctxt.kbd or
	c = int <-fakekbd =>
		if(kbdfocus != nil)
			kbdfocus.kbd <-= c;
	p := <-wmctxt.ptr =>
		if(wmclient->win.pointer(*p))
			break;
		if(p.buttons && (ptrfocus == nil || buttons == 0)){
			c := wmsrv->find(p.xy);
			if(c == nil){
				# bare desktop: button 3 opens the context menu.
				if(p.buttons == 4)
					controlevent(sys->sprint("popup %d %d", p.xy.x, p.xy.y));
			}else{
				ptrfocus = c;
				c.ctl <-= "raise";
				setfocus(win, c);
				# grab a window border directly to resize, the
				# modern way -- left button only (right button is the
				# window menu), and never the toolbar (controller).
				if(c != controller && p.buttons == 1){
					w := c.window(".");
					if(w != nil && w.img != nil && p.xy.in(w.r)){
						move := edgeat(w.r, p.xy);
						if(move != 0){
							edgeresize(wmctxt.ptr, c, w, move, *p);
							buttons = 0;
							break;
						}
					}
				}
			}
		}
		if(ptrfocus != nil && (ptrfocus.flags & Ptrstarted) != 0){
			# inside currently selected client or it had button down last time (might have come up)
			buttons = p.buttons;
			ptrfocus.ptr <-= p;
			break;
		}
		buttons = 0;
	(c, rc) := <-join =>
		rc <-= nil;
		# new client; inform it of the available screen rectangle.
		# XXX do we need to do this now we've got wmrect?
		c.ctl <-= "rect " + r2s(screen.image.r);
		c.vis = 1;
		if(allowcontrol){
			controller = c;
			c.flags |= Controller;
			c.ws = Allws;			# toolbar shows on every workspace
			allowcontrol = 0;
		}else{
			c.ws = curws;
			controlevent("newclient " + string c.id);
			if(c.title != nil)
				controlevent(sys->sprint("wtitle %d %q", c.id, c.title));
			controlevent(sys->sprint("wworkspace %d %d", c.id, c.ws));
		}
		controlevent(sys->sprint("curworkspace %d %d", curws, Nws));
		c.cursor = "cursor";
	(c, data, rc) := <-req =>
		# if client leaving
		if(rc == nil){
			c.remove();
			if(c.stop == nil)
				break;
			if(c == ptrfocus)
				ptrfocus = nil;
			if(c == kbdfocus)
				kbdfocus = nil;
			if(c == controller)
				controller = nil;
			controlevent("delclient " + string c.id);
			for(z := wmsrv->top(); z != nil; z = z.znext)
				if(z.vis && (z.flags & Kbdstarted))
					break;
			setfocus(win, z);
			c.stop <-= 1;
			break;
		}
		err := handlerequest(win, wmctxt, c, string data);
		n := len data;
		if(err != nil)
			n = -1;
		alt{
		rc <-= (n, err) =>;
		* =>;
		}
	(nil, nil, nil, wc) := <-wmrectIO.write =>
		if(wc == nil)
			break;
		alt{
		wc <-= (0, "cannot write") =>;
		* =>;
		}
	(off, nil, nil, rc) := <-wmrectIO.read =>
		if(rc == nil)
			break;
		d := array of byte r2s(screen.image.r);
		if(off > len d)
			off = len d;
		alt{
		rc <-= (d[off:], nil) =>;
		* =>;
		}
	}
}

handlerequest(win: ref Wmclient->Window, wmctxt: ref Wmcontext, c: ref Client, req: string): string
{
#sys->print("%d: %s\n", c.id, req);
	args := str->unquoted(req);
	if(args == nil)
		return "no request";
	n := len args;
	if(req[0] == '!' && n < 3)
		return "bad arg count";
	case hd args {
	"key" =>
		# XXX should we restrict this capability to certain clients only?
		if(n != 2)
			return "bad arg count";
		if(fakekbdin == nil){
			fakekbdin = chan of string;
			spawn bufferproc(fakekbdin, fakekbd);
		}
		fakekbdin <-= hd tl args;
	"ptr" =>
		# ptr x y
		if(n != 3)
			return "bad arg count";
		if(ptrfocus != c)
			return "cannot move pointer";
		e := wmclient->win.wmctl(req);
		if(e == nil){
			c.ptr <-= nil;		# flush queue
			c.ptr <-= ref Pointer(buttons, (int hd tl args, int hd tl tl args), sys->millisec());
		}
	"cursor" =>
		# cursor hotx hoty dx dy data
		if(n != 6 && n != 1)
			return "bad arg count";
		c.cursor = req;
		if(ptrfocus == c || kbdfocus == c)
			return wmclient->win.wmctl(c.cursor);
	"start" =>
		if(n != 2)
			return "bad arg count";
		case hd tl args {
		"mouse" or
		"ptr" =>
			c.flags |= Ptrstarted;
		"kbd" =>
			c.flags |= Kbdstarted;
			# XXX this means that any new window grabs the focus from the current
			# application, but usually you want this to happen... how can we distinguish
			# the two cases?
			setfocus(win, c);
		"control" =>
			if((c.flags & Controller) == 0)
				return "control not available";
			c.flags |= Controlstarted;
			# bring the controller up to date on existing clients + workspace.
			for(z := wmsrv->top(); z != nil; z = z.znext){
				if(z == c)
					continue;
				controlevent("newclient " + string z.id);
				if(z.title != nil)
					controlevent(sys->sprint("wtitle %d %q", z.id, z.title));
				controlevent(sys->sprint("wworkspace %d %d", z.id, z.ws));
			}
			controlevent(sys->sprint("curworkspace %d %d", curws, Nws));
		* =>
			return "unknown input source";
		}
	"!reshape" =>
		# reshape tag reqid rect [how]
		# XXX allow "how" to specify that the origin of the window is never
		# changed - a new window will be created instead.
		if(n < 7)
			return "bad arg count";
		args = tl args;
		tag := hd args; args = tl args;
		args = tl args;		# skip reqid
		r: Rect;
		r.min.x = int hd args; args = tl args;
		r.min.y = int hd args; args = tl args;
		r.max.x = int hd args; args = tl args;
		r.max.y = int hd args; args = tl args;
		if(args != nil){
			case hd args{
			"onscreen" =>
				r = fitrect(r, screen.image.r);
			"place" =>
				r = fitrect(r, screen.image.r);
				r = newrect(r, screen.image.r);
			"exact" =>
				;
			"max" =>
				r = screen.image.r;			# XXX don't obscure toolbar?
			* =>
				return "unkown placement method";
			}
		}
		# an explicit reshape from the client overrides any maximize state.
		if((mw := c.window(tag)) != nil)
			mw.maxed = 0;
		return reshape(c, tag, r);
	"delete" =>
		# delete tag
		if(tl args == nil)
			return "tag required";
		c.setimage(hd tl args, nil);
		if(c.wins == nil && c == kbdfocus)
			setfocus(win, nil);
	"raise" =>
		c.top();
	"lower" =>
		c.bottom();
	"!move" or
	"!size" =>
		# !move tag reqid startx starty
		# !size tag reqid mindx mindy
		ismove := hd args == "!move";
		if(n < 3)
			return "bad arg count";
		args = tl args;
		tag := hd args; args = tl args;
		args = tl args;			# skip reqid
		w := c.window(tag);
		if(w == nil)
			return "no such tag";
		if(ismove){
			if(n != 5)
				return "bad arg count";
			return dragwin(wmctxt.ptr, c, w, Point(int hd args, int hd tl args));
		}else{
			if(n != 5)
				return "bad arg count";
			sizewin(wmctxt.ptr, c, w, Point(int hd args, int hd tl args));
		}
	"!maximize" =>
		# !maximize tag reqid -- toggle maximize/restore.
		if(n < 3)
			return "bad arg count";
		args = tl args;
		tag := hd args;
		w := c.window(tag);
		if(w == nil)
			return "no such tag";
		return togglemax(c, w);
	"!snap" =>
		# !snap tag reqid side -- tile the window to a work-area half.
		if(n < 4)
			return "bad arg count";
		args = tl args;
		tag := hd args; args = tl args;
		args = tl args;			# skip reqid
		w := c.window(tag);
		if(w == nil)
			return "no such tag";
		wa := workarea();
		hx := (wa.min.x + wa.max.x) / 2;
		r: Rect;
		case hd args {
		"left" =>	r = (wa.min, (hx, wa.max.y));
		"right" =>	r = ((hx, wa.min.y), wa.max);
		"max" =>	r = wa;
		* =>		return "bad snap side";
		}
		if(w.maxed == 0)
			w.normalr = w.r;
		w.maxed = 1;
		return reshape(c, w.tag, r);
	"fixedorigin" =>
		c.flags |= Fixedorigin;
	"rect" =>
		;
	"kbdfocus" =>
		if(n != 2)
			return "bad arg count";
		if(int hd tl args){
			if(c.vis == 0)			# raising a window from another workspace
				switchws(win, c.ws);	# follows it there
			setfocus(win, c);
		}else if(c == kbdfocus)
			setfocus(win, nil);
	"wtitle" =>
		# wtitle {title} -- client records its window title (quoted) for menus.
		if(n >= 2){
			c.title = hd tl args;
			controlevent(sys->sprint("wtitle %d %q", c.id, c.title));
		}
	# controller specific messages:
	"request" =>		# can be used to test for control.
		if((c.flags & Controller) == 0)
			return "you are not in control";
	"ctl" =>
		# ctl id msg
		if((c.flags & Controlstarted) == 0)
			return "invalid request";
		if(n < 3)
			return "bad arg count";
		id := int hd tl args;
		for(z := wmsrv->top(); z != nil; z = z.znext)
			if(z.id == id)
				break;
		if(z == nil)
			return "no such client";
		z.ctl <-= str->quoted(tl tl args);
	"workspace" =>
		# workspace n -- switch the shown workspace (controller only).
		if((c.flags & Controlstarted) == 0)
			return "invalid request";
		if(n != 2)
			return "bad arg count";
		switchws(win, int hd tl args);
	"sendto" =>
		# sendto id n -- move a client to workspace n (controller only).
		if((c.flags & Controlstarted) == 0)
			return "invalid request";
		if(n != 3)
			return "bad arg count";
		sendtows(win, int hd tl args, int hd tl tl args);
	"cascade" =>
		if((c.flags & Controlstarted) == 0)
			return "invalid request";
		cascade();
	"minall" =>
		if((c.flags & Controlstarted) == 0)
			return "invalid request";
		minall();
	"endcontrol" =>
		if(c != controller)
			return "invalid request";
		controller = nil;
		allowcontrol = 1;
		c.flags &= ~(Controlstarted | Controller);
	* =>
		if(c == controller || controller == nil || (controller.flags & Controlstarted) == 0)
			return "unknown control request";
		controller.ctl <-= "request " + string c.id + " " + req;
	}
	return nil;
}

Fix: con 1000;
# the window manager window has been reshaped;
# allocate a new screen, and move all the 
reshaped(win: ref Wmclient->Window)
{
	oldr := screen.image.r;
	newr := win.image.r;
	mx := Fix;
	if(oldr.dx() > 0)
		mx = newr.dx() * Fix / oldr.dx();
	my := Fix;
	if(oldr.dy() > 0)
		my = newr.dy() * Fix / oldr.dy();
	screen = makescreen(win.image);
	for(z := wmsrv->top(); z != nil; z = z.znext){
		for(wl := z.wins; wl != nil; wl = tl wl){
			w := hd wl;
			w.img = nil;
			nr := w.r.subpt(oldr.min);
			nr.min.x = nr.min.x * mx / Fix;
			nr.min.y = nr.min.y * my / Fix;
			nr.max.x = nr.max.x * mx / Fix;
			nr.max.y = nr.max.y * my / Fix;
			nr = nr.addpt(newr.min);
			w.img = screen.newwindow(nr, Draw->Refbackup, Draw->Nofill);
			# XXX check for creation failure
			w.r = nr;
			z.ctl <-= sys->sprint("!reshape %q -1 %s", w.tag, r2s(nr));
			z.ctl <-= "rect " + r2s(newr);
		}
	}
}

controlevent(e: string)
{
	if(controller != nil && (controller.flags & Controlstarted))
		controller.ctl <-= e;
}

dragwin(ptr: chan of ref Pointer, c: ref Client, w: ref Window, start: Point): string
{
	if(buttons == 0)
		return "too late";
	scr := screen.image.r;
	wa := workarea();
	Margin: con 10;

	# geometry to restore to if this drag ends in an aero snap.
	wasmax := w.maxed;
	restorer := w.r;
	if(wasmax)
		restorer = w.normalr;

	off := start.sub(w.r.min);
	sz := w.r.size();
	borders := array[4] of ref Image;
	pvis := 0;
	snap: Rect;
	snapping := 0;
	# a stationary click is not a drag: don't move, snap, or un-maximize until
	# the pointer actually travels.  this keeps the first Button-1 of a
	# double-click (which Tk delivers before Double-Button-1) a clean no-op, so
	# double-click-maximize toggles exactly once even when the title bar already
	# sits in the top aero zone.
	Dragthresh: con 5;
	moved := 0;
	p: ref Pointer;
	do{
		p = <-ptr;
		if(!moved && (abs(p.xy.x - start.x) > Dragthresh || abs(p.xy.y - start.y) > Dragthresh))
			moved = 1;
		if(moved){
			org := p.xy.sub(off);
			if(org.y < scr.min.y)
				org.y = scr.min.y;
			else if(org.y > scr.max.y - Margin)
				org.y = scr.max.y - Margin;
			if(org.x < scr.min.x && org.x + sz.x < scr.min.x + Margin)
				org.x = scr.min.x + Margin - sz.x;
			else if(org.x > scr.max.x - Margin)
				org.x = scr.max.x - Margin;
			# flush-snap window edges to the work area (not while a maximized
			# window is still at full size and following the cursor).
			if(!wasmax)
				org = edgealign(org, sz, wa);
			w.img.origin(w.img.r.min, org);
			# arm an aero snap (and preview it) when the pointer reaches an edge.
			(snap, snapping) = aerozone(p.xy, wa);
		}
		if(snapping){
			showborders(borders, snap, Minx|Miny|Maxx|Maxy);
			pvis = 1;
		}else if(pvis){
			hideborders(borders);
			pvis = 0;
		}
	} while (p.buttons != 0);
	if(pvis)
		hideborders(borders);
	c.ptr <-= p;
	buttons = 0;

	if(!moved)
		return "not moved";
	if(snapping){
		w.normalr = restorer;
		w.maxed = 1;
		return reshape(c, w.tag, snap);
	}
	if(wasmax){
		# dropped without snapping: restore to normal size under the cursor.
		relx := off.x;
		if(w.r.dx() > 1)
			relx = off.x * restorer.dx() / w.r.dx();
		rely := off.y;
		if(rely >= restorer.dy())
			rely = restorer.dy() / 2;
		neworg := p.xy.sub(Point(relx, rely));
		w.maxed = 0;
		return reshape(c, w.tag, fitrect((neworg, neworg.add(restorer.size())), scr));
	}
	r: Rect;
	r.min = p.xy.sub(off);
	r.max = r.min.add(sz);
	if(r.eq(w.r))
		return "not moved";
	return reshape(c, w.tag, r);
}

# toggle a window between its normal geometry and the maximized work area.
togglemax(c: ref Client, w: ref Window): string
{
	if(w.maxed){
		w.maxed = 0;
		return reshape(c, w.tag, fitrect(w.normalr, screen.image.r));
	}
	w.normalr = w.r;
	w.maxed = 1;
	return reshape(c, w.tag, workarea());
}

# show or hide all of a client's windows by re-pointing them on/off screen.
# this only moves the physical (scr) origin, leaving each window's logical
# rectangle in place, so geometry and maximize state survive a workspace round
# trip and the client never has to redraw.
showclient(c: ref Client, show: int)
{
	off := screen.image.r.max;
	for(wl := c.wins; wl != nil; wl = tl wl){
		w := hd wl;
		if(w.img == nil)
			continue;
		if(show)
			w.img.origin(w.img.r.min, w.img.r.min);
		else
			w.img.origin(w.img.r.min, off);
	}
	c.vis = show;
}

# pick the topmost focusable client on the current workspace (nil if none).
topvisible(): ref Client
{
	for(z := wmsrv->top(); z != nil; z = z.znext)
		if(z.vis && z != controller && (z.flags & Kbdstarted))
			return z;
	return nil;
}

switchws(win: ref Wmclient->Window, n: int)
{
	if(n < 0 || n >= Nws || n == curws)
		return;
	old := curws;
	curws = n;
	for(z := wmsrv->top(); z != nil; z = z.znext){
		if(z == controller || z.ws == Allws)
			continue;
		if(z.ws == n && z.vis == 0)
			showclient(z, 1);
		else if(z.ws == old && z.vis != 0)
			showclient(z, 0);
	}
	if(kbdfocus != nil && kbdfocus.vis == 0)
		setfocus(win, topvisible());
	screen.image.flush(Draw->Flushnow);
	controlevent(sys->sprint("curworkspace %d %d", curws, Nws));
}

sendtows(win: ref Wmclient->Window, id, n: int)
{
	if(n < 0 || n >= Nws)
		return;
	for(z := wmsrv->top(); z != nil; z = z.znext)
		if(z.id == id)
			break;
	if(z == nil || z == controller || z.ws == Allws)
		return;
	z.ws = n;
	controlevent(sys->sprint("wworkspace %d %d", z.id, z.ws));
	if(n == curws && z.vis == 0)
		showclient(z, 1);
	else if(n != curws && z.vis != 0){
		showclient(z, 0);
		if(z == kbdfocus)
			setfocus(win, topvisible());
	}
	screen.image.flush(Draw->Flushnow);
}

# stagger every visible window from the top-left of the work area.
cascade()
{
	wa := workarea();
	step := 24;
	i := 0;
	for(z := wmsrv->top(); z != nil; z = z.znext){
		if(z == controller || z.vis == 0)
			continue;
		w := z.window(".");
		if(w == nil)
			continue;
		sz := w.r.size();
		o := Point(wa.min.x + i*step, wa.min.y + i*step);
		if(o.x + sz.x > wa.max.x)
			o.x = wa.min.x;
		if(o.y + sz.y > wa.max.y)
			o.y = wa.min.y;
		z.ctl <-= sys->sprint("!reshape %q -1 %s", w.tag, r2s((o, o.add(sz))));
		i++;
	}
}

# minimize every visible window (each client iconifies itself to the toolbar).
minall()
{
	for(z := wmsrv->top(); z != nil; z = z.znext)
		if(z != controller && z.vis != 0)
			z.ctl <-= "task";
}

# the screen area not occupied by the toolbar (the wm's controller client,
# docked as a full-width strip top or bottom).  maximize and aero snap fill
# this so the toolbar stays reachable.
workarea(): Rect
{
	r := screen.image.r;
	if(controller != nil){
		for(wl := controller.wins; wl != nil; wl = tl wl){
			tb := (hd wl).r;
			if(tb.dx() < r.dx() - 2)
				continue;		# not a full-width strut
			if(tb.min.y <= r.min.y + 2 && tb.max.y < r.max.y){
				if(tb.max.y > r.min.y)
					r.min.y = tb.max.y;		# docked at top
			}else if(tb.max.y >= r.max.y - 2 && tb.min.y > r.min.y){
				if(tb.min.y < r.max.y)
					r.max.y = tb.min.y;		# docked at bottom
			}
		}
	}
	return r;
}

# which snap, if any, the pointer is requesting by hugging a work-area edge.
# corners tile to a quarter, the top edge maximizes, the sides take a half.
aerozone(xy: Point, wa: Rect): (Rect, int)
{
	hx := (wa.min.x + wa.max.x) / 2;
	hy := (wa.min.y + wa.max.y) / 2;
	atleft := xy.x <= wa.min.x + Edgezone;
	atright := xy.x >= wa.max.x - Edgezone;
	attop := xy.y <= wa.min.y + Edgezone;
	atbot := xy.y >= wa.max.y - Edgezone;
	if(attop && atleft)
		return (Rect(wa.min, (hx, hy)), 1);			# top-left quarter
	if(attop && atright)
		return (Rect((hx, wa.min.y), (wa.max.x, hy)), 1);	# top-right quarter
	if(atbot && atleft)
		return (Rect((wa.min.x, hy), (hx, wa.max.y)), 1);	# bottom-left quarter
	if(atbot && atright)
		return (Rect((hx, hy), wa.max), 1);			# bottom-right quarter
	if(attop)
		return (wa, 1);						# top: maximize
	if(atleft)
		return (Rect(wa.min, (hx, wa.max.y)), 1);		# left half
	if(atright)
		return (Rect((hx, wa.min.y), wa.max), 1);		# right half
	return (ZR, 0);
}

# pull a window's edges flush to the work area when they come close.
edgealign(org: Point, sz: Point, wa: Rect): Point
{
	if(abs(org.x - wa.min.x) <= Snapdist)
		org.x = wa.min.x;
	else if(abs(org.x + sz.x - wa.max.x) <= Snapdist)
		org.x = wa.max.x - sz.x;
	if(abs(org.y - wa.min.y) <= Snapdist)
		org.y = wa.min.y;
	else if(abs(org.y + sz.y - wa.max.y) <= Snapdist)
		org.y = wa.max.y - sz.y;
	return org;
}

# which window edges a press at p wants to drag, given the grab margin.
# the top edge coincides with the title bar, so it only grabs at the corners;
# the rest of the title bar's top stays free for move and double-click-maximize.
edgeat(r: Rect, p: Point): int
{
	e := 0;
	if(p.x <= r.min.x + Handle)
		e |= Minx;
	else if(p.x >= r.max.x - Handle)
		e |= Maxx;
	if(p.y >= r.max.y - Handle)
		e |= Maxy;
	else if(p.y <= r.min.y + Handle && (e & (Minx|Maxx)) != 0)
		e |= Miny;
	return e;
}

# interactive resize started by grabbing a window border directly.  this is
# wm-initiated, so the new geometry is pushed to the client over its ctl
# channel (it then drives the image handshake) rather than reshaped here.
edgeresize(ptrc: chan of ref Pointer, c: ref Client, w: ref Window, move: int, p0: Pointer): string
{
	borders := array[4] of ref Image;
	showborders(borders, w.r, Minx|Miny|Maxx|Maxy);
	screen.image.flush(Draw->Flushnow);
	r := w.r;
	offset := Point(0, 0);
	if(move & Minx)
		offset.x = p0.xy.x - r.min.x;
	else if(move & Maxx)
		offset.x = p0.xy.x - r.max.x;
	if(move & Miny)
		offset.y = p0.xy.y - r.min.y;
	else if(move & Maxy)
		offset.y = p0.xy.y - r.max.y;
	nr := sweep(ptrc, r, offset, borders, move, Minx|Miny|Maxx|Maxy, Point(Minwinx, Minwiny));
	hideborders(borders);
	w.maxed = 0;
	c.ctl <-= sys->sprint("!reshape %q -1 %s", w.tag, r2s(nr));
	return nil;
}

hideborders(b: array of ref Image)
{
	for(i := 0; i < len b; i++)
		b[i] = nil;
	screen.image.flush(Draw->Flushnow);
}

abs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

sizewin(ptrc: chan of ref Pointer, c: ref Client, w: ref Window, minsize: Point): string
{
	borders := array[4] of ref Image;
	showborders(borders, w.r, Minx|Maxx|Miny|Maxy);
	screen.image.flush(Draw->Flushnow);
	while((ptr := <-ptrc).buttons == 0)
		;
	xy := ptr.xy;
	move, show: int;
	offset := Point(0, 0);
	r := w.r;
	show = Minx|Miny|Maxx|Maxy;
	if(xy.in(w.r) == 0){
		r = (xy, xy);
		move = Maxx|Maxy;
	}else {
		if(xy.x < (r.min.x+r.max.x)/2){
			move=Minx;
			offset.x = xy.x - r.min.x;
		}else{
			move=Maxx;
			offset.x = xy.x - r.max.x;
		}
		if(xy.y < (r.min.y+r.max.y)/2){
			move |= Miny;
			offset.y = xy.y - r.min.y;
		}else{
			move |= Maxy;
			offset.y = xy.y - r.max.y;
		}
	}
	return reshape(c, w.tag, sweep(ptrc, r, offset, borders, move, show, minsize));
}

reshape(c: ref Client, tag: string, r: Rect): string
{
	w := c.window(tag);
	# if window hasn't changed size, then just change its origin and use the same image.
	if((c.flags & Fixedorigin) == 0 && w != nil && w.r.size().eq(r.size())){
		c.setorigin(tag, r.min);
	} else {
		img := screen.newwindow(r, Draw->Refbackup, Draw->Nofill);
		if(img == nil)
			return sys->sprint("window creation failed: %r");
		if(c.setimage(tag, img) == -1)
			return "can't do two at once";
	}
	c.top();
	# a client living on another workspace must stay off-screen even if it
	# reshapes itself in the background.
	if(c.vis == 0)
		showclient(c, 0);
	return nil;
}

sweep(ptr: chan of ref Pointer, r: Rect, offset: Point, borders: array of ref Image, move, show: int, min: Point): Rect
{
	while((p := <-ptr).buttons != 0){
		xy := p.xy.sub(offset);
		if(move&Minx)
			r.min.x = xy.x;
		if(move&Miny)
			r.min.y = xy.y;
		if(move&Maxx)
			r.max.x = xy.x;
		if(move&Maxy)
			r.max.y = xy.y;
		showborders(borders, r, show);
	}
	r = r.canon();
	if(r.min.y < screen.image.r.min.y){
		r.min.y = screen.image.r.min.y;
		r = r.canon();
	}
	if(r.dx() < min.x){
		if(move & Maxx)
			r.max.x = r.min.x + min.x;
		else
			r.min.x = r.max.x - min.x;
	}
	if(r.dy() < min.y){
		if(move & Maxy)
			r.max.y = r.min.y + min.y;
		else {
			r.min.y = r.max.y - min.y;
			if(r.min.y < screen.image.r.min.y){
				r.min.y = screen.image.r.min.y;
				r.max.y = r.min.y + min.y;
			}
		}
	}
	return r;
}

showborders(b: array of ref Image, r: Rect, show: int)
{
	r = r.canon();
	b[Sminx] = showborder(b[Sminx], show&Minx,
		(r.min, (r.min.x+Bdwidth, r.max.y)));
	b[Sminy] = showborder(b[Sminy], show&Miny,
		((r.min.x+Bdwidth, r.min.y), (r.max.x-Bdwidth, r.min.y+Bdwidth)));
	b[Smaxx] = showborder(b[Smaxx], show&Maxx,
		((r.max.x-Bdwidth, r.min.y), (r.max.x, r.max.y)));
	b[Smaxy] = showborder(b[Smaxy], show&Maxy,
		((r.min.x+Bdwidth, r.max.y-Bdwidth), (r.max.x-Bdwidth, r.max.y)));
}

showborder(b: ref Image, show: int, r: Rect): ref Image
{
	if(!show)
		return nil;
	if(b != nil && b.r.size().eq(r.size()))
		b.origin(r.min, r.min);
	else
		b = screen.newwindow(r, Draw->Refbackup, Draw->Red);
	return b;
}

r2s(r: Rect): string
{
	return string r.min.x + " " + string r.min.y + " " +
			string r.max.x + " " + string r.max.y;
}

# XXX for consideration:
# do not allow applications to grab the keyboard focus
# unless there is currently no keyboard focus...
# but what about launching a new app from the taskbar:
# surely we should allow that to grab the focus?
setfocus(win: ref Wmclient->Window, new: ref Client)
{
	old := kbdfocus;
	if(old == new)
		return;
	if(new == nil)
		wmclient->win.wmctl("cursor");
	else if(old == nil || old.cursor != new.cursor)
		wmclient->win.wmctl(new.cursor);
	if(new != nil && (new.flags & Kbdstarted) == 0)
		return;
	if(old != nil)
		old.ctl <-= "haskbdfocus 0";
	
	if(new != nil){
		new.ctl <-= "raise";
		new.ctl <-= "haskbdfocus 1";
		kbdfocus = new;
	} else
		kbdfocus = nil;
}

makescreen(img: ref Image): ref Screen
{
	screen = Screen.allocate(img, img.display.color(Background), 0);
	img.draw(img.r, screen.fill, nil, screen.fill.r.min);
	return screen;
}

kill(pid: int, note: string): int
{
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", note) < 0)
		return -1;
	return 0;
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "wm: %s\n", s);
	kill(sys->pctl(0, nil), "killgrp");
	raise "fail:error";
}

# fit a window rectangle to the available space.
# try to preserve requested location if possible.
# make sure that the window is no bigger than
# the screen, and that its top and left-hand edges
# will be visible at least.
fitrect(w, r: Rect): Rect
{
	if(w.dx() > r.dx())
		w.max.x = w.min.x + r.dx();
	if(w.dy() > r.dy())
		w.max.y = w.min.y + r.dy();
	size := w.size();
	if (w.max.x > r.max.x)
		(w.min.x, w.max.x) = (r.min.x - size.x, r.max.x - size.x);
	if (w.max.y > r.max.y)
		(w.min.y, w.max.y) = (r.min.y - size.y, r.max.y - size.y);
	if (w.min.x < r.min.x)
		(w.min.x, w.max.x) = (r.min.x, r.min.x + size.x);
	if (w.min.y < r.min.y)
		(w.min.y, w.max.y) = (r.min.y, r.min.y + size.y);
	return w;
}

lastrect: Rect;
# find an suitable area for a window
newrect(w, r: Rect): Rect
{
	rl: list of Rect;
	for(z := wmsrv->top(); z != nil; z = z.znext)
		for(wl := z.wins; wl != nil; wl = tl wl)
			rl = (hd wl).r :: rl;
	lastrect = winplace->place(rl, r, lastrect, w.size());
	return lastrect;
}

bufferproc(in, out: chan of string)
{
	h, t: list of string;
	dummyout := chan of string;
	for(;;){
		outc := dummyout;
		s: string;
		if(h != nil || t != nil){
			outc = out;
			if(h == nil)
				for(; t != nil; t = tl t)
					h = hd t :: h;
			s = hd h;
		}
		alt{
		x := <-in =>
			t = x :: t;
		outc <-= s =>
			h = tl h;
		}
	}
}

command(ctxt: ref Draw->Context, args: list of string, sync: chan of string)
{
	if((sh := load Sh Sh->PATH) != nil){
		sh->run(ctxt, "{$*&}" :: args);
		sync <-= nil;
		return;
	}
	fds := list of {0, 1, 2};
	sys->pctl(sys->NEWFD, fds);

	cmd := hd args;
	file := cmd;

	if(len file<4 || file[len file-4:]!=".dis")
		file += ".dis";

	c := load Wm file;
	if(c == nil) {
		err := sys->sprint("%r");
		if(err != "permission denied" && err != "access permission denied" && file[0]!='/' && file[0:2]!="./"){
			c = load Wm "/dis/"+file;
			if(c == nil)
				err = sys->sprint("%r");
		}
		if(c == nil){
			sync <-= sys->sprint("%s: %s\n", cmd, err);
			exit;
		}
	}
	sync <-= nil;
	c->init(ctxt, args);
}
