implement Usbd;

#
# usbd - USB bus enumerator and HID class driver for the native kernel's
# 9front-style #u (devusb) interface.
#
# The host-controller stack (devusb + usbxhci) presents endpoints as files:
#   #u/usb/ctl              global control + endpoint listing
#   #u/usb/epD.E/data       endpoint I/O (control transfers on ep0)
#   #u/usb/epD.E/ctl        per-endpoint control requests
#
# Each root hub appears as a control endpoint epD.0 whose ctl info reads
# "roothub ports N".  We treat it as a hub: scan ports with hub-class
# GET_STATUS, reset connected ports, then create+address a device with
# "newdev <speed> <port>", read its descriptors, and (for HID boot
# keyboards/mice) stream interrupt reports.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Usbd: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

# request type (bmRequestType)
Rh2d:	con 16r00;
Rd2h:	con 16r80;
Rstd:	con 16r00;
Rclass:	con 16r20;
Rdev:	con 0;
Rother:	con 3;

# standard requests
Getstatus:	con 0;
Clearfeature:	con 1;
Setfeature:	con 3;
Setaddress:	con 5;
Getdesc:	con 6;
Setconf:	con 9;
Setinterface:	con 11;

# HID class requests
Hidsetidle:	con 16r0A;
Hidsetproto:	con 16r0B;

# descriptor types
Ddevice:	con 1;
Dconfig:	con 2;
Dstring:	con 3;
Dinterface:	con 4;
Dendpoint:	con 5;

# device/interface classes
Clhid:		con 3;
Clhub:		con 9;

# root hub port features (devusb rhubwrite)
Fportenable:	con 1;
Fportreset:	con 4;
Fportpower:	con 8;

# root hub port status bits (HP* in os/drivers/usb.h)
HPpresent:	con 16r1;
HPenable:	con 16r2;
HPreset:	con 16r10;
HPpower:	con 16r100;
HPslow:		con 16r200;
HPhigh:		con 16r400;
HPstatuschg:	con 16r10000;
HPchange:	con 16r20000;

# endpoint transfer types (bmAttributes & 3)
Eintr:		con 3;

usbroot := "/dev/usb";
verbose := 0;

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	for(a := tl argv; a != nil; a = tl a)
		case hd a {
		"-v" =>	verbose = 1;
		"-d" =>	verbose = 2;
		}

	# make sure #u is reachable
	if(sys->bind("#u", "/dev", Sys->MAFTER) < 0 && sys->stat(usbroot+"/ctl").t0 < 0){
		fatal(sys->sprint("can't see usb: %r"));
	}

	roots := roothubs();
	if(roots == nil){
		fatal("no usb root hubs found");
	}
	for(; roots != nil; roots = tl roots){
		(name, nports) := hd roots;
		report(sys->sprint("root hub %s: %d ports", name, nports));
		scanhub(name, nports);
	}
}

fatal(s: string)
{
	sys->fprint(stderr, "usbd: %s\n", s);
	raise "fail:error";
}

report(s: string)
{
	sys->print("%s\n", s);
}

dbg(s: string)
{
	if(verbose)
		sys->fprint(stderr, "usbd: %s\n", s);
}

# little-endian helpers
get2(b: array of byte, o: int): int
{
	return int b[o] | (int b[o+1] << 8);
}

put2(b: array of byte, o: int, v: int)
{
	b[o] = byte v;
	b[o+1] = byte (v >> 8);
}

# Read /dev/usb/ctl and return the root hubs as (name, nports).
# Each endpoint prints a header line then, if it has an info string,
# a following "roothub ports N <type>" line.
roothubs(): list of (string, int)
{
	fd := sys->open(usbroot+"/ctl", Sys->OREAD);
	if(fd == nil)
		fatal(sys->sprint("open %s/ctl: %r", usbroot));
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	text := string buf[0:n];
	(nil, lines) := sys->tokenize(text, "\n");
	hubs: list of (string, int);
	name := "";
	for(; lines != nil; lines = tl lines){
		ln := hd lines;
		(nf, f) := sys->tokenize(ln, " ");
		if(nf == 0)
			continue;
		if(len hd f >= 2 && (hd f)[0:2] == "ep"){
			name = hd f;			# endpoint header line
		} else if(nf >= 3 && hd f == "roothub" && hd tl f == "ports"){
			nports := int hd tl tl f;
			if(name != "")
				hubs = (name, nports) :: hubs;
			name = "";
		}
	}
	return rev(hubs);
}

rev(l: list of (string, int)): list of (string, int)
{
	r: list of (string, int);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# Open a root hub's control endpoint and walk its ports.
scanhub(hubname: string, nports: int)
{
	datafd := sys->open(usbroot+"/"+hubname+"/data", Sys->ORDWR);
	if(datafd == nil){
		report(sys->sprint("  open %s/data: %r", hubname));
		return;
	}
	for(port := 1; port <= nports; port++){
		# power the port (root ports are usually already powered)
		setfeature(datafd, Fportpower, port);
		st := portstatus(datafd, port);
		dbg(sys->sprint("%s port %d status %#x", hubname, port, st));
		if((st & HPpresent) == 0)
			continue;
		report(sys->sprint("  port %d: device present (status %#x)", port, st));
		resetport(datafd, port);
		st = portstatus(datafd, port);
		if((st & HPenable) == 0){
			report(sys->sprint("  port %d: not enabled after reset (status %#x)", port, st));
			continue;
		}
		speed := "full";
		if(st & HPhigh)
			speed = "high";
		else if(st & HPslow)
			speed = "low";
		configdev(hubname, port, speed);
	}
}

setfeature(datafd: ref Sys->FD, feature, port: int)
{
	setupout(datafd, Rh2d|Rclass|Rother, Setfeature, feature, port, nil);
}

clearfeature(datafd: ref Sys->FD, feature, port: int)
{
	setupout(datafd, Rh2d|Rclass|Rother, Clearfeature, feature, port, nil);
}

portstatus(datafd: ref Sys->FD, port: int): int
{
	b := setupin(datafd, Rd2h|Rclass|Rother, Getstatus, 0, port, 4);
	if(b == nil || len b < 4)
		return 0;
	return get2(b, 0) | (get2(b, 2) << 16);
}

resetport(datafd: ref Sys->FD, port: int)
{
	setfeature(datafd, Fportreset, port);
	sys->sleep(80);
	# the next request to the root hub terminates the reset and enables
	# the port (see devusb rhubwrite); a status read does that.
	portstatus(datafd, port);
	sys->sleep(20);
}

# Bring up the device on (hub,port) at the given speed: create it,
# address it, read its descriptors, and drive any HID interface.
configdev(hubname: string, port: int, speed: string)
{
	hubctl := sys->open(usbroot+"/"+hubname+"/ctl", Sys->ORDWR);
	if(hubctl == nil){
		report(sys->sprint("  open %s/ctl: %r", hubname));
		return;
	}
	# create the new device's control endpoint
	wn := sys->fprint(hubctl, "newdev %s %d", speed, port);
	dbg(sys->sprint("newdev write returned %d", wn));
	if(wn < 0){
		report(sys->sprint("  newdev %s %d: %r", speed, port));
		return;
	}
	sys->seek(hubctl, big 0, Sys->SEEKSTART);
	nb := array[64] of byte;
	n := sys->read(hubctl, nb, len nb);
	if(n <= 0){
		report(sys->sprint("  newdev: no endpoint name (n=%d): %r", n));
		return;
	}
	epname := string nb[0:n];
	# strip trailing whitespace
	while(len epname > 0 && (epname[len epname-1] == '\n' || epname[len epname-1] == ' '))
		epname = epname[0:len epname-1];
	report(sys->sprint("  port %d: %s speed=%s", port, epname, speed));

	datafd := sys->open(usbroot+"/"+epname+"/data", Sys->ORDWR);
	if(datafd == nil){
		report(sys->sprint("  open %s/data: %r", epname));
		return;
	}

	# device descriptor (read full 18 bytes)
	dd := getdesc(datafd, Ddevice, 0, 18);
	if(dd == nil || len dd < 18){
		report("  can't read device descriptor");
		return;
	}
	vid := get2(dd, 8);
	pid := get2(dd, 10);
	dclass := int dd[4];
	report(sys->sprint("    device %4.4ux:%4.4ux class %d maxpkt0 %d nconf %d",
		vid, pid, dclass, int dd[7], int dd[17]));

	# tell devusb we've addressed the device
	epctl := sys->open(usbroot+"/"+epname+"/ctl", Sys->ORDWR);
	if(epctl != nil)
		sys->fprint(epctl, "address");

	# configuration descriptor: read 9 bytes, then the full thing
	cd := getdesc(datafd, Dconfig, 0, 9);
	if(cd == nil || len cd < 9){
		report("    can't read config descriptor");
		return;
	}
	total := get2(cd, 2);
	cfgval := int cd[5];
	cd = getdesc(datafd, Dconfig, 0, total);
	if(cd == nil || len cd < total){
		report("    can't read full config descriptor");
		return;
	}
	report(sys->sprint("    config #%d, %d bytes, %d interface(s)", cfgval, total, int cd[4]));

	parseconfig(epname, datafd, epctl, cfgval, cd);
}

# Walk the config descriptor blob, report interfaces/endpoints, and
# hand HID boot interfaces to the HID driver.
parseconfig(epname: string, datafd, epctl: ref Sys->FD, cfgval: int, cd: array of byte)
{
	i := 0;
	curclass := -1;
	cursub := -1;
	curproto := -1;
	curiface := -1;
	hidep := -1;
	hidmax := 0;
	hidival := 0;
	while(i + 2 <= len cd){
		blen := int cd[i];
		btype := int cd[i+1];
		if(blen == 0 || i + blen > len cd)
			break;
		case btype {
		Dinterface =>
			# finish previous HID interface before starting a new one
			if(curclass == Clhid && hidep >= 0)
				hidstart(epname, datafd, epctl, cfgval, curiface, cursub, curproto, hidep, hidmax, hidival);
			curiface = int cd[i+2];
			curclass = int cd[i+5];
			cursub = int cd[i+6];
			curproto = int cd[i+7];
			hidep = -1;
			report(sys->sprint("    iface %d: class %d sub %d proto %d, %d ep(s)",
				curiface, curclass, cursub, curproto, int cd[i+4]));
		Dendpoint =>
			addr := int cd[i+2];
			attr := int cd[i+3];
			mpkt := get2(cd, i+4);
			ival := int cd[i+6];
			dir := "out";
			if(addr & 16r80)
				dir = "in";
			report(sys->sprint("      ep %d %s attr %#x maxpkt %d ival %d",
				addr & 16rF, dir, attr, mpkt, ival));
			if(curclass == Clhid && (attr & 3) == Eintr && (addr & 16r80)){
				hidep = addr & 16rF;
				hidmax = mpkt;
				hidival = ival;
			}
		}
		i += blen;
	}
	if(curclass == Clhid && hidep >= 0)
		hidstart(epname, datafd, epctl, cfgval, curiface, cursub, curproto, hidep, hidmax, hidival);
}

# setup a control OUT (no data, or with payload).
setupout(fd: ref Sys->FD, rtype, req, value, index: int, data: array of byte): int
{
	dlen := 0;
	if(data != nil)
		dlen = len data;
	buf := array[8 + dlen] of byte;
	buf[0] = byte rtype;
	buf[1] = byte req;
	put2(buf, 2, value);
	put2(buf, 4, index);
	put2(buf, 6, dlen);
	if(dlen > 0)
		buf[8:] = data;
	return sys->write(fd, buf, len buf);
}

# setup a control IN: write the request, then read the reply.
setupin(fd: ref Sys->FD, rtype, req, value, index, count: int): array of byte
{
	buf := array[8] of byte;
	buf[0] = byte rtype;
	buf[1] = byte req;
	put2(buf, 2, value);
	put2(buf, 4, index);
	put2(buf, 6, count);
	if(sys->write(fd, buf, 8) != 8)
		return nil;
	rb := array[count] of byte;
	n := sys->read(fd, rb, count);
	if(n < 0)
		return nil;
	if(n < count)
		return rb[0:n];
	return rb;
}

getdesc(fd: ref Sys->FD, dtype, index, count: int): array of byte
{
	return setupin(fd, Rd2h|Rstd|Rdev, Getdesc, (dtype << 8) | index, 0, count);
}

# --- HID class driver -------------------------------------------------

hidstart(epname: string, datafd, epctl: ref Sys->FD, cfgval, iface, sub, proto, epnum, maxpkt, ival: int)
{
	kind := "device";
	if(sub == 1 && proto == 1)
		kind = "keyboard";
	else if(sub == 1 && proto == 2)
		kind = "mouse";
	report(sys->sprint("    HID %s on %s (iface %d ep %d)", kind, epname, iface, epnum));

	if(epctl == nil){
		report("    no ctl fd for HID setup");
		return;
	}
	# create the interrupt-IN endpoint, set its parameters.  Unlike
	# "newdev", the "new" ctl does not report a name back: the new
	# endpoint file is epD.E where D is this device's number (the
	# prefix of epname, e.g. ep3.0 -> dev 3).
	if(sys->fprint(epctl, "new %d interrupt r", epnum) < 0){
		report(sys->sprint("    new ep %d: %r", epnum));
		return;
	}
	intrname := devprefix(epname) + "." + string epnum;
	ictl := sys->open(usbroot+"/"+intrname+"/ctl", Sys->ORDWR);
	if(ictl != nil){
		sys->fprint(ictl, "maxpkt %d", maxpkt);
		if(ival > 0)
			sys->fprint(ictl, "pollival %d", ival);
	}

	# select the configuration, set HID boot protocol + idle (report on
	# change only).  The interface recipient (1) carries the class request.
	setupout(datafd, Rh2d|Rstd|Rdev, Setconf, cfgval, 0, nil);
	setupout(datafd, Rh2d|Rclass|1, Hidsetproto, 0, iface, nil);	# 0 = boot protocol
	setupout(datafd, Rh2d|Rclass|1, Hidsetidle, 0, iface, nil);	# value 0 = indefinite

	intrfd := sys->open(usbroot+"/"+intrname+"/data", Sys->OREAD);
	if(intrfd == nil){
		report(sys->sprint("    open %s/data: %r", intrname));
		return;
	}
	if(maxpkt <= 0 || maxpkt > 64)
		maxpkt = 8;
	case kind {
	"keyboard" =>
		report(sys->sprint("    HID keyboard live: %s -> %s", intrname, kbddev));
		spawn kbdreader(intrfd, maxpkt);
	"mouse" =>
		report(sys->sprint("    HID mouse live: %s -> %s", intrname, ptrdev));
		spawn mousereader(intrfd, maxpkt);
	* =>
		report(sys->sprint("    HID %s: logging raw reports from %s", kind, intrname));
		spawn rawreader(kind, intrfd, maxpkt);
	}
}

# "ep3.0" -> "ep3"
devprefix(epname: string): string
{
	for(i := 0; i < len epname; i++)
		if(epname[i] == '.')
			return epname[0:i];
	return epname;
}

# Where decoded events are injected into the kernel input path.
kbddev := "/dev/keyboard";	# devcons Qkeyboard: write UTF-8 -> kbdq
ptrdev := "/dev/pointer";	# devpointer Qpointer: write "m x y b"

# HID boot keyboard usage -> rune (US layout).  Index by usage code.
keymap := array[128] of {* => 0};
keymapsh := array[128] of {* => 0};

initkeymap()
{
	for(i := 0; i < 26; i++){
		keymap[16r04+i] = 'a'+i;
		keymapsh[16r04+i] = 'A'+i;
	}
	digits := "1234567890";
	shdigits := "!@#$%^&*()";
	for(i = 0; i < 10; i++){
		keymap[16r1e+i] = digits[i];
		keymapsh[16r1e+i] = shdigits[i];
	}
	# usage : plain : shifted
	set(16r28, '\n', '\n');		# enter
	set(16r29, 16r1b, 16r1b);	# escape
	set(16r2a, '\b', '\b');		# backspace
	set(16r2b, '\t', '\t');		# tab
	set(16r2c, ' ', ' ');		# space
	set(16r2d, '-', '_');
	set(16r2e, '=', '+');
	set(16r2f, '[', '{');
	set(16r30, ']', '}');
	set(16r31, '\\', '|');
	set(16r33, ';', ':');
	set(16r34, '\'', '"');
	set(16r35, '`', '~');
	set(16r36, ',', '<');
	set(16r37, '.', '>');
	set(16r38, '/', '?');
}

set(usage, plain, shifted: int)
{
	keymap[usage] = plain;
	keymapsh[usage] = shifted;
}

# Boot keyboard report: [mod, resv, k0..k5].  Edge-trigger on newly
# pressed usages, translate via the keymap, write the rune to the kernel
# keyboard queue.  modifier bit 0x22 = left|right shift.
kbdreader(fd: ref Sys->FD, maxpkt: int)
{
	initkeymap();
	kfd := sys->open(kbddev, Sys->OWRITE);
	if(kfd == nil){
		sys->fprint(stderr, "usbd: open %s: %r\n", kbddev);
		return;
	}
	prev := array[256] of {* => 0};	# usage -> down last report
	buf := array[maxpkt] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0){
			sys->fprint(stderr, "usbd: keyboard read: %r\n");
			return;
		}
		if(n < 3)
			continue;
		shift := (int buf[0] & 16r22) != 0;
		cur := array[256] of {* => 0};
		for(i := 2; i < n; i++){
			u := int buf[i];
			if(u == 0)
				continue;
			cur[u] = 1;
			if(prev[u] == 0){		# newly pressed
				r := keymap[u];
				if(shift && u < 128)
					r = keymapsh[u];
				if(r != 0){
					rb := array of byte sys->sprint("%c", r);
					sys->write(kfd, rb, len rb);
				}
			}
		}
		prev = cur;
	}
}

# Boot mouse report: [buttons, dx, dy(, dwheel)].  dx/dy are signed.
# devpointer only accepts absolute coordinates, so accumulate.
mousereader(fd: ref Sys->FD, maxpkt: int)
{
	pfd := sys->open(ptrdev, Sys->OWRITE);
	if(pfd == nil){
		sys->fprint(stderr, "usbd: open %s: %r\n", ptrdev);
		return;
	}
	x := 320;
	y := 240;
	buf := array[maxpkt] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0){
			sys->fprint(stderr, "usbd: mouse read: %r\n");
			return;
		}
		if(n < 3)
			continue;
		b := int buf[0];
		x += sbyte(buf[1]);
		y += sbyte(buf[2]);
		if(x < 0) x = 0;
		if(y < 0) y = 0;
		# inferno button bits: 1=left 2=middle 4=right; HID: 1=left 2=right 4=middle
		ib := (b & 1) | ((b & 2) << 1) | ((b & 4) >> 1);
		msg := array of byte sys->sprint("m%d %d %d", x, y, ib);
		sys->write(pfd, msg, len msg);
		dbg(sys->sprint("mouse x %d y %d b %d", x, y, ib));
	}
}

sbyte(b: byte): int
{
	v := int b;
	if(v >= 128)
		v -= 256;
	return v;
}

# Unknown HID device: just log the raw reports.
rawreader(kind: string, fd: ref Sys->FD, maxpkt: int)
{
	buf := array[maxpkt] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0){
			if(n < 0)
				sys->fprint(stderr, "usbd: %s read: %r\n", kind);
			return;
		}
		s := sys->sprint("usbd: %s report:", kind);
		for(i := 0; i < n; i++)
			s += sys->sprint(" %2.2ux", int buf[i]);
		sys->fprint(stderr, "%s\n", s);
	}
}
