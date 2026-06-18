implement WmRt;

#
# wm/rt - a Dis VM disassembler / module inspector.
#
# The whole module is presented at once through a ttk::notebook: a Summary
# tab (header fields as a property/value treeview), a syntax-highlighted Code
# listing, a Data segment, and columnar treeviews for the type / link / import
# descriptors and the exception handlers.  A ttk toolbar carries the File and
# Properties menus (ttk::menubutton) plus quick actions, and a themed status
# bar shows the loaded module at a glance.  The .dis / .s writers and the
# stack-extent editor are unchanged underneath.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "draw.m";

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "dialog.m";
	dialog: Dialog;

include "selectfile.m";
	selectfile: Selectfile;

include "dis.m";
	dis: Dis;
	Inst, Type, Data, Link, Mod: import dis;
	XMAGIC: import Dis;
	MUSTCOMPILE, DONTCOMPILE: import Dis;
	AMP, AFP, AIMM, AXXX, AIND, AMASK: import Dis;
	ARM, AXNON, AXIMM, AXINF, AXINM: import Dis;
	DEFB, DEFW, DEFS, DEFF, DEFA, DIND, DAPOP, DEFL: import Dis;

WmRt: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

gctxt: ref Draw->Context;
t: ref Toplevel;
disfile: string;

TK:	con 1;

CODEFONT:	con "/fonts/pelm/ascii.12.font";

m: ref Mod;
rt := 0;
ss := -1;

# the widget tree: a toolbar with the menus, a notebook of section views, and
# a status bar.  The classic `menu' widgets are what the ttk::menubuttons post.
ui_cfg := array[] of {
	# wm/rt keeps a deliberate light "code listing" surface for its data views,
	# to match the white code/data text panes -- an editor-style scheme that is
	# the same regardless of the desktop theme.  Pin all three Treeview surfaces
	# (body, heading, text) so the listing stays high-contrast even under a dark
	# desktop theme; the toolbar, tabs, menus, scrollbars and status bar are
	# left to follow the system theme.  (A bare ttk::treeview themes correctly
	# on its own -- libtk falls its body back to the plain themed background --
	# so this is an app choice, not a workaround.)
	"ttk::style configure Treeview -fieldbackground #ffffff "+
		"-background #e8e8e8 -foreground #1b1b1b",

	# --- menus (posted by the ttk::menubuttons) ---
	"menu .filemenu",
	".filemenu add command -label {Open module...} -command {send cmd open}",
	".filemenu add separator",
	".filemenu add command -label {Write .dis module} -command {send cmd save}",
	".filemenu add command -label {Write .s file} -command {send cmd list}",

	"menu .propmenu",
	".propmenu add checkbutton -label {Must compile} -command {send cmd must}",
	".propmenu add checkbutton -label {Don't compile} -command {send cmd dont}",
	".propmenu add separator",
	".propmenu add command -label {Set stack extent...} -command {send cmd stack}",
	".propmenu add command -label {Sign module} -command {send cmd sign}",

	# --- toolbar ---
	"ttk::frame .top",
	"ttk::menubutton .top.file -text File -menu .filemenu",
	"ttk::menubutton .top.props -text Properties -menu .propmenu",
	"ttk::separator .top.sep -orient vertical",
	"ttk::button .top.open -text {Open module} -command {send cmd open}",
	"ttk::button .top.asm -text {Export .s} -command {send cmd list}",
	"pack .top.file .top.props -side left -padx 2 -pady 3",
	"pack .top.sep -side left -fill y -padx 5 -pady 3",
	"pack .top.open .top.asm -side left -padx 2 -pady 3",
	"pack .top -side top -fill x",
	"ttk::separator .topsep -orient horizontal",
	"pack .topsep -side top -fill x",

	# --- status bar ---
	"ttk::frame .sb",
	"ttk::label .sb.l -text {No module loaded — use File ▸ Open} -anchor w",
	"pack .sb.l -side left -fill x -expand 1 -padx 8 -pady 3",
	"ttk::sizegrip .sb.grip",
	"pack .sb.grip -side right -anchor se",
	"ttk::separator .sbsep -orient horizontal",
	"pack .sb -side bottom -fill x",
	"pack .sbsep -side bottom -fill x",

	# --- notebook ---
	"ttk::notebook .nb",
	"pack .nb -side top -fill both -expand 1",

	# Summary: header fields as a property/value tree
	"ttk::frame .nb.sum",
	"ttk::treeview .nb.sum.t -columns val -height 16 -yscrollcommand {.nb.sum.sb set}",
	"ttk::scrollbar .nb.sum.sb -orient vertical -command {.nb.sum.t yview}",
	".nb.sum.t heading #0 -text Property",
	".nb.sum.t heading val -text Value",
	".nb.sum.t column #0 -width 200",
	".nb.sum.t column val -width 360",
	"pack .nb.sum.sb -side right -fill y",
	"pack .nb.sum.t -side left -fill both -expand 1",
	".nb add .nb.sum -text Summary",

	# Code: syntax-highlighted disassembly
	"ttk::frame .nb.code",
	"text .nb.code.t -width 80 -height 26 -wrap none -bg white "+
		"-yscrollcommand {.nb.code.sb set} -xscrollcommand {.nb.code.xsb set}",
	"ttk::scrollbar .nb.code.sb -orient vertical -command {.nb.code.t yview}",
	"ttk::scrollbar .nb.code.xsb -orient horizontal -command {.nb.code.t xview}",
	".nb.code.t tag configure pcnum -font "+CODEFONT+" -foreground #8a8a8a",
	".nb.code.t tag configure opcode -font "+CODEFONT+" -foreground #0b5ed7",
	".nb.code.t tag configure operand -font "+CODEFONT+" -foreground #1b1b1b",
	".nb.code.t tag configure cmt -font "+CODEFONT+" -foreground #117a3a",
	"grid .nb.code.t -row 0 -column 0 -sticky nsew",
	"grid .nb.code.sb -row 0 -column 1 -sticky ns",
	"grid .nb.code.xsb -row 1 -column 0 -sticky ew",
	"grid rowconfigure .nb.code 0 -weight 1",
	"grid columnconfigure .nb.code 0 -weight 1",
	".nb add .nb.code -text Code",

	# Data segment
	"ttk::frame .nb.data",
	"text .nb.data.t -width 80 -height 26 -wrap none -bg white "+
		"-yscrollcommand {.nb.data.sb set}",
	"ttk::scrollbar .nb.data.sb -orient vertical -command {.nb.data.t yview}",
	".nb.data.t tag configure mono -font "+CODEFONT+" -foreground #1b1b1b",
	"pack .nb.data.sb -side right -fill y",
	"pack .nb.data.t -side left -fill both -expand 1",
	".nb add .nb.data -text Data",

	# Type descriptors
	"ttk::frame .nb.types",
	"ttk::treeview .nb.types.t -columns {size map} -height 16 -yscrollcommand {.nb.types.sb set}",
	"ttk::scrollbar .nb.types.sb -orient vertical -command {.nb.types.t yview}",
	".nb.types.t heading #0 -text Desc",
	".nb.types.t heading size -text {Size (bytes)}",
	".nb.types.t heading map -text {Pointer map}",
	".nb.types.t column #0 -width 80",
	".nb.types.t column size -width 100 -anchor e",
	".nb.types.t column map -width 360",
	"pack .nb.types.sb -side right -fill y",
	"pack .nb.types.t -side left -fill both -expand 1",
	".nb add .nb.types -text Types",

	# Link descriptors
	"ttk::frame .nb.links",
	"ttk::treeview .nb.links.t -columns {desc pc sig} -height 16 -yscrollcommand {.nb.links.sb set}",
	"ttk::scrollbar .nb.links.sb -orient vertical -command {.nb.links.t yview}",
	".nb.links.t heading #0 -text Name",
	".nb.links.t heading desc -text Desc",
	".nb.links.t heading pc -text PC",
	".nb.links.t heading sig -text Signature",
	".nb.links.t column #0 -width 220",
	".nb.links.t column desc -width 60 -anchor e",
	".nb.links.t column pc -width 60 -anchor e",
	".nb.links.t column sig -width 120",
	"pack .nb.links.sb -side right -fill y",
	"pack .nb.links.t -side left -fill both -expand 1",
	".nb add .nb.links -text Links",

	# Import descriptors
	"ttk::frame .nb.imports",
	"ttk::treeview .nb.imports.t -columns sig -height 16 -yscrollcommand {.nb.imports.sb set}",
	"ttk::scrollbar .nb.imports.sb -orient vertical -command {.nb.imports.t yview}",
	".nb.imports.t heading #0 -text Name",
	".nb.imports.t heading sig -text Signature",
	".nb.imports.t column #0 -width 320",
	".nb.imports.t column sig -width 140",
	"pack .nb.imports.sb -side right -fill y",
	"pack .nb.imports.t -side left -fill both -expand 1",
	".nb add .nb.imports -text Imports",

	# Exception handlers (handler -> entries)
	"ttk::frame .nb.handlers",
	"ttk::treeview .nb.handlers.t -columns {info} -height 16 -yscrollcommand {.nb.handlers.sb set}",
	"ttk::scrollbar .nb.handlers.sb -orient vertical -command {.nb.handlers.t yview}",
	".nb.handlers.t heading #0 -text Handler",
	".nb.handlers.t heading info -text Detail",
	".nb.handlers.t column #0 -width 220",
	".nb.handlers.t column info -width 320",
	"pack .nb.handlers.sb -side right -fill y",
	"pack .nb.handlers.t -side left -fill both -expand 1",
	".nb add .nb.handlers -text Handlers",

	"update",
};

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	if (ctxt == nil) {
		sys->fprint(sys->fildes(2), "rt: no window context\n");
		raise "fail:bad context";
	}
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	dialog = load Dialog Dialog->PATH;
	selectfile = load Selectfile Selectfile->PATH;

	sys->pctl(Sys->NEWPGRP, nil);

	tkclient->init();
	dialog->init();
	selectfile->init();

	gctxt = ctxt;

	menubut: chan of string;
	(t, menubut) = tkclient->toplevel(ctxt, "", "Dis Disassembler", Tkclient->Appl);

	cmd := chan of string;

	tk->namechan(t, cmd, "cmd");
	tkcmds(t, ui_cfg);
	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd"::"ptr"::nil);

	dis = load Dis Dis->PATH;
	if(dis == nil) {
		dialog->prompt(ctxt, t.image, "error -fg red", "Load Module",
				"wmrt requires Dis",
				0, "Exit"::nil);
		return;
	}
	dis->init();

	# an optional module path on the command line opens straight away
	if(argv != nil)
		argv = tl argv;
	if(argv != nil) {
		e := loadmod(hd argv);
		if(e != nil)
			ioerror("Open " + hd argv, e);
	}

	for(;;) alt {
	s := <-t.ctxt.kbd =>
		tk->keyboard(t, s);
	s := <-t.ctxt.ptr =>
		tk->pointer(t, *s);
	s := <-t.ctxt.ctl or
	s = <-t.wreq =>
		tkclient->wmctl(t, s);
	menu := <-menubut =>
		if(menu == "exit")
			return;
		tkclient->wmctl(t, menu);
	s := <-cmd =>
		case s {
		"open" =>
			openfile(ctxt);
		"save" =>
			writedis();
		"list" =>
			writeasm();
		"must" =>
			rt ^= MUSTCOMPILE;
			setstatus();
		"dont" =>
			rt ^= DONTCOMPILE;
			setstatus();
		"stack" =>
			spawn stack(ctxt);
		"sign" =>
			dialog->prompt(ctxt, t.image, "error -fg red", "Signed Modules",
				"not implemented",
				0, "Continue"::nil);
		}
	}
}

# refresh the status bar from the loaded module
setstatus()
{
	s: string;
	if(m == nil || m.magic == 0)
		s = "No module loaded — use File ▸ Open";
	else {
		fl := rtflag(rt);
		if(fl == "")
			fl = "no flags";
		s = sprint("%s   —   v%d Dis   —   %d instructions, %d type descriptors   —   %s",
			m.name, m.magic - XMAGIC + 1, m.isize, m.tsize, fl);
	}
	tk->cmd(t, ".sb.l configure -text " + tk->quote(s));
}

# wipe every section view before repopulating
clearviews()
{
	tk->cmd(t, ".nb.code.t delete 1.0 end");
	tk->cmd(t, ".nb.data.t delete 1.0 end");
	cleartree(".nb.sum.t");
	cleartree(".nb.types.t");
	cleartree(".nb.links.t");
	cleartree(".nb.imports.t");
	cleartree(".nb.handlers.t");
}

cleartree(path: string)
{
	ids := tk->cmd(t, path + " children {}");
	if(ids != "" && ids[0] != '!')
		tk->cmd(t, path + " delete " + ids);
}

# format an array of strings as a braced Tk list, each element braced
vlist(a: array of string): string
{
	s := "{";
	for(i := 0; i < len a; i++) {
		if(i > 0)
			s += " ";
		s += "{" + a[i] + "}";
	}
	return s + "}";
}

trow(path: string, parent: string, id: string, text: string, vals: array of string)
{
	c := path + " insert " + parent + " end";
	if(id != "")
		c += " -id " + id;
	c += " -text " + tk->quote(text) + " -values " + vlist(vals);
	tk->cmd(t, c);
}

stack_cfg := array[] of {
	"ttk::frame .f -padding 10",
	"ttk::label .f.l -text {Stack extent (bytes):}",
	"ttk::label .f.v -text 0",
	"ttk::scale .f.s -length 260 -from 0 -to 32768 -orient horizontal "+
		"-command {.f.v configure -text}",
	"grid .f.l -row 0 -column 0 -sticky w",
	"grid .f.v -row 0 -column 1 -sticky e",
	"grid .f.s -row 1 -column 0 -columnspan 2 -sticky ew -pady 6",
	"grid columnconfigure .f 0 -weight 1",
	"pack .f -fill both -expand 1",
};

stack(ctxt: ref Draw->Context)
{
	(s, sbut) := tkclient->toplevel(ctxt, "", "Stack extent", 0);

	cmd := chan of string;
	tk->namechan(s, cmd, "cmd");
	tkcmds(s, stack_cfg);
	tk->cmd(s, ".f.s set " + string ss);
	tk->cmd(s, "update");
	tkclient->onscreen(s, nil);
	tkclient->startinput(s, "kbd"::"ptr"::nil);

	for(;;) alt {
	c := <-s.ctxt.kbd =>
		tk->keyboard(s, c);
	c := <-s.ctxt.ptr =>
		tk->pointer(s, *c);
	c := <-s.ctxt.ctl or
	c = <-s.wreq =>
		tkclient->wmctl(s, c);
	wmctl := <-sbut =>
		if(wmctl == "exit") {
			ss = int tk->cmd(s, ".f.s get");
			setstatus();
			return;
		}
		tkclient->wmctl(s, wmctl);
	}
}

openfile(ctxt: ref Draw->Context)
{
	pattern := list of {
		"*.dis (Dis VM module)",
		"* (All files)"
	};

	for(;;) {
		disfile = selectfile->filename(ctxt, t.image, "Dis file", pattern, nil);
		if(disfile == "")
			break;

		s := loadmod(disfile);
		if(s == nil)
			return;

		r := dialog->prompt(ctxt, t.image, "error -fg red", "Open Dis File",
				s,
				0, "Retry" :: "Abort" :: nil);
		if(r == 1)
			return;
	}
}

# load a .dis module and populate every section view; returns an error string
loadmod(file: string): string
{
	(mm, e) := dis->loadobj(file);
	if(e != nil)
		return e;
	m = mm;
	disfile = file;
	ss = m.ssize;
	rt = m.rt;
	clearviews();
	summary();
	das(TK);
	dat(TK);
	desc(TK);
	link(TK);
	imports(TK);
	handlers(TK);
	setstatus();
	tk->cmd(t, ".nb select .nb.code");
	tk->cmd(t, "update");
	return nil;
}

writedis()
{
	if(m == nil || m.magic == 0) {
		dialog->prompt(gctxt, t.image, "error -fg red", "Write .dis",
				"no module loaded",
				0, "Continue"::nil);
		return;
	}
	if(rt < 0)
		rt = m.rt;
	if(ss < 0)
		ss = m.ssize;
	if(rt == m.rt && ss == m.ssize)
		return;
	while((fd := sys->open(disfile, Sys->OREAD)) == nil){
		if(dialog->prompt(gctxt, t.image, "error -fg red", "Open Dis File", "open failed: "+sprint("%r"),
		     0, "Retry" :: "Abort" :: nil))
			return;
	}
	if(len discona(rt) == len discona(m.rt) && len discona(ss) == len discona(m.ssize)){
		sys->seek(fd, big 4, Sys->SEEKSTART);	# skip magic
		discon(fd, rt);
		discon(fd, ss);
		m.rt = rt;
		m.ssize = ss;
		setstatus();
		return;
	}
	# rt and ss representations changed in length: read the file in,
	# make a copy and update rt and ss when copying
	(ok, d) := sys->fstat(fd);
	if(ok < 0){
		ioerror("Reading Dis file "+disfile, "can't find file length: "+sprint("%r"));
		return;
	}
	length := int d.length;
	disbuf := array[length] of byte;
	if(sys->read(fd, disbuf, length) != length){
		ioerror("Reading Dis file "+disfile, "read error: "+sprint("%r"));
		return;
	}
	outbuf := array[length+2*4] of byte;	# could avoid this buffer if required, by writing portions of disbuf
	(magic, i) := operand(disbuf, 0);
	o := putoperand(outbuf, magic);
	if(magic == Dis->SMAGIC){
		ns: int;
		(ns, i) = operand(disbuf, i);
		o += putoperand(outbuf[o:], ns);
		sign := disbuf[i:i+ns];
		i += ns;
		outbuf[o:] = sign;
		o += ns;
	}
	(nil, i) = operand(disbuf, i);
	(nil, i) = operand(disbuf, i);
	if(i < 0){
		ioerror("Reading Dis file "+disfile, "Dis header too short");
		return;
	}
	o += putoperand(outbuf[o:], rt);
	o += putoperand(outbuf[o:], ss);
	outbuf[o:] = disbuf[i:];
	o += len disbuf - i;
	fd = sys->create(disfile, Sys->OWRITE, 8r666);
	if(fd == nil){
		ioerror("Rewriting "+disfile, sys->sprint("can't create %s: %r",disfile));
		return;
	}
	if(sys->write(fd, outbuf, o) != o)
		ioerror("Rewriting "+disfile, "write error: "+sprint("%r"));
	m.rt = rt;
	m.ssize = ss;
	setstatus();
}

ioerror(title: string, err: string)
{
	dialog->prompt(gctxt, t.image, "error -fg red", title, err, 0, "Dismiss" :: nil);
}

putoperand(out: array of byte, v: int): int
{
	a := discona(v);
	out[0:] = a;
	return len a;
}

discona(val: int): array of byte
{
	if(val >= -64 && val <= 63)
		return array[] of { byte(val & ~16r80) };
	else if(val >= -8192 && val <= 8191)
		return array[] of { byte((val>>8) & ~16rC0 | 16r80), byte val };
	else
		return array[] of { byte(val>>24 | 16rC0), byte(val>>16), byte(val>>8), byte val };
}

discon(fd: ref Sys->FD, val: int)
{
	a := discona(val);
	sys->write(fd, a, len a);
}

operand(disobj: array of byte, o: int): (int, int)
{
	if(o >= len disobj)
		return (-1, -1);
	b := int disobj[o++];
	case b & 16rC0 {
	16r00 =>
		return (b, o);
	16r40 =>
		return (b | ~16r7F, o);
	16r80 =>
		if(o >= len disobj)
			return (-1, -1);
		if(b & 16r20)
			b |= ~16r3F;
		else
			b &= 16r3F;
		b = (b<<8) | int disobj[o++];
		return (b, o);
	16rC0 =>
		if(o+2 >= len disobj)
			return (-1, -1);
		if(b & 16r20)
			b |= ~16r3F;
		else
			b &= 16r3F;
		b = b<<24 |
			(int disobj[o]<<16) |
		    	(int disobj[o+1]<<8)|
		    	int disobj[o+2];
		o += 3;
		return (b, o);
	}
	return (0, -1);	# can't happen
}

fasm: ref Iobuf;

writeasm()
{
	if(m == nil || m.magic == 0) {
		dialog->prompt(gctxt, t.image, "error -fg red", "Write .s",
				"no module loaded",
				0, "Continue"::nil);
		return;
	}

	bufio = load Bufio Bufio->PATH;
	if(bufio == nil) {
		dialog->prompt(gctxt, t.image, "error -fg red", "Write .s",
				"Bufio load failed: "+sprint("%r"),
				0, "Exit"::nil);
		return;
	}

	for(;;) {
		asmfile: string;
		if(len disfile > 4 && disfile[len disfile-4:] == ".dis")
			asmfile = disfile[0:len disfile-3] + "s";
		else
			asmfile = disfile + ".s";
		fasm = bufio->create(asmfile, Sys->OWRITE|Sys->OTRUNC, 8r666);
		if(fasm != nil)
			break;
		r := dialog->prompt(gctxt, t.image, "error -fg red", "Create .s file",
			"open failed: "+sprint("%r"),
			0, "Retry" :: "Abort" :: nil);
		if(r == 0)
			continue;
		else
			return;
	}
	das(!TK);
	fasm.puts("\tentry\t" + string m.entry + "," + string m.entryt + "\n");
	desc(!TK);
	dat(!TK);
	fasm.puts("\tmodule\t" + m.name + "\n");
	link(!TK);
	imports(!TK);
	handlers(!TK);
	fasm.close();
}

link(flag: int)
{
	if(m == nil || m.magic == 0) {
		dialog->prompt(gctxt, t.image, "error -fg red", "Link Descriptors",
				"no module loaded",
				0, "Continue"::nil);
		return;
	}

	for(i := 0; i < m.lsize; i++) {
		l := m.links[i];
		if(flag == TK)
			trow(".nb.links.t", "{}", "", l.name,
				array[] of { string l.desc, string l.pc, sprint("0x%ux", l.sig) });
		else
			fasm.puts(sprint("	link %d,%d, 0x%ux, \"%s\"\n",
						l.desc, l.pc, l.sig, l.name));
	}
}

imports(flag: int)
{
	if(m == nil || m.magic == 0) {
		dialog->prompt(gctxt, t.image, "error -fg red", "Import Descriptors",
				"no module loaded",
				0, "Continue"::nil);
		return;
	}

	mi := m.imports;
	for(i := 0; i < len mi; i++) {
		a := mi[i];
		for(j := 0; j < len a; j++) {
			ai := a[j];
			if(flag == TK)
				trow(".nb.imports.t", "{}", "", ai.name,
					array[] of { sprint("0x%ux", ai.sig) });
			else
				fasm.puts(sprint("	import 0x%ux, \"%s\"\n", ai.sig, ai.name));
		}
	}
}

handlers(flag: int)
{
	if(m == nil || m.magic == 0) {
		dialog->prompt(gctxt, t.image, "error -fg red", "Exception Handlers",
				"no module loaded",
				0, "Continue"::nil);
		return;
	}

	hs := m.handlers;
	for(i := 0; i < len hs; i++) {
		h := hs[i];
		tt := -1;
		for(j := 0; j < len m.types; j++) {
			if(h.t == m.types[j]) {
				tt = j;
				break;
			}
		}
		hid := "h" + string i;
		if(flag == TK)
			trow(".nb.handlers.t", "{}", hid, sprint("handler %d", i),
				array[] of { sprint("pc %d-%d, off=%d, n=%d, type=$%d", h.pc1, h.pc2, h.eoff, h.ne, tt) });
		else
			fasm.puts(sprint("	%d-%d, o=%d, e=%d t=%d\n", h.pc1, h.pc2, h.eoff, h.ne, tt));
		et := h.etab;
		for(j = 0; j < len et; j++) {
			e := et[j];
			if(flag == TK) {
				label: string;
				if(e.s == nil)
					label = "*";
				else
					label = "\"" + e.s + "\"";
				trow(".nb.handlers.t", hid, "", sprint("pc %d", e.pc),
					array[] of { label });
			} else {
				if(e.s == nil)
					fasm.puts(sprint("		%d	*\n", e.pc));
				else
					fasm.puts(sprint("		%d	\"%s\"\n", e.pc, e.s));
			}
		}
	}
}

desc(flag: int)
{
	if(m == nil || m.magic == 0) {
		dialog->prompt(gctxt, t.image, "error -fg red", "Type Descriptors",
				"no module loaded",
				0, "Continue"::nil);
		return;
	}

	for(i := 0; i < m.tsize; i++) {
		h := m.types[i];
		mp := "";
		for(j := 0; j < h.np; j++)
			mp += sprint("%.2ux", int h.map[j]);
		if(flag == TK)
			trow(".nb.types.t", "{}", "", sprint("$%d", i),
				array[] of { string h.size, mp });
		else {
			s := sprint("	desc $%d, %d, \"%s\"\n", i, h.size, mp);
			fasm.puts(s);
		}
	}
}

# Summary tab: the header fields as a property/value tree
summary()
{
	if(m == nil || m.magic == 0)
		return;

	trow(".nb.sum.t", "{}", "", "Module", array[] of { m.name });
	trow(".nb.sum.t", "{}", "", "Version",
		array[] of { sprint("%d  (magic %.8ux)", m.magic - XMAGIC + 1, m.magic) });
	fl := rtflag(m.rt);
	if(fl == "")
		fl = "none";
	trow(".nb.sum.t", "{}", "", "Runtime flags", array[] of { fl });
	trow(".nb.sum.t", "{}", "", "Stack extent", array[] of { sprint("%d bytes", m.ssize) });
	trow(".nb.sum.t", "{}", "", "Instructions", array[] of { string m.isize });
	trow(".nb.sum.t", "{}", "", "Data size", array[] of { sprint("%d bytes", m.dsize) });
	trow(".nb.sum.t", "{}", "", "Type descriptors", array[] of { string m.tsize });
	trow(".nb.sum.t", "{}", "", "Link directives", array[] of { string m.lsize });
	trow(".nb.sum.t", "{}", "", "Entry PC", array[] of { string m.entry });
	trow(".nb.sum.t", "{}", "", "Entry type", array[] of { sprint("$%d", m.entryt) });
	sec := "Signed";
	if(m.sign == nil)
		sec = "Insecure (unsigned)";
	trow(".nb.sum.t", "{}", "", "Security", array[] of { sec });
}

rtflag(flag: int): string
{
	if(flag == 0)
		return "";

	s := "[";

	if(flag & MUSTCOMPILE)
		s += "MustCompile";
	if(flag & DONTCOMPILE) {
		if(flag & MUSTCOMPILE)
			s += "|";
		s += "DontCompile";
	}
	s[len s] = ']';

	return s;
}

das(flag: int)
{
	if(m == nil || m.magic == 0) {
		dialog->prompt(gctxt, t.image, "error -fg red", "Assembly",
				"no module loaded",
				0, "Continue"::nil);
		return;
	}

	for(i := 0; i < m.isize; i++) {
		op := dis->inst2s(m.inst[i]);
		if(flag == TK) {
			# inst2s left-justifies the opcode in 10 columns, then the
			# operands; split there for a coloured PC/opcode/operands listing.
			opc := op;
			opr := "";
			if(len op > 10) {
				opc = op[0:10];
				opr = op[10:];
			}
			tk->cmd(t, ".nb.code.t insert end {" + sprint("%6d  ", i) + "} pcnum");
			tk->cmd(t, ".nb.code.t insert end {" + opc + "} opcode");
			tk->cmd(t, ".nb.code.t insert end {" + opr + "\n} operand");
		} else {
			if(i % 10 == 0)
				fasm.puts("#" + string i + "\n");
			fasm.puts("\t" + op + "\n");
		}
	}
	if(flag == TK)
		tk->cmd(t, ".nb.code.t see 1.0");
}

dat(flag: int)
{
	if(m == nil || m.magic == 0) {
		dialog->prompt(gctxt, t.image, "error -fg red", "Module Data",
				"no module loaded",
				0, "Continue"::nil);
		return;
	}
	hdr := sprint("\tvar @mp, %d\n", m.types[0].size);
	if(flag == TK)
		datline(hdr);
	else
		fasm.puts(hdr);

	s := "";
	for(d := m.data; d != nil; d = tl d) {
		pick dat := hd d {
		Bytes =>
			s = sprint("\tbyte @mp+%d", dat.off);
			for(n := 0; n < dat.n; n++)
				s += sprint(",%d", int dat.bytes[n]);
		Words =>
			s = sprint("\tword @mp+%d", dat.off);
			for(n := 0; n < dat.n; n++)
				s += sprint(",%d", dat.words[n]);
		String =>
			s = sprint("\tstring @mp+%d, \"%s\"", dat.off, mapstr(dat.str));
		Reals =>
			s = sprint("\treal @mp+%d", dat.off);
			for(n := 0; n < dat.n; n++)
				s += sprint(", %g", dat.reals[n]);
			break;
		Array =>
			s = sprint("\tarray @mp+%d,$%d,%d", dat.off, dat.typex, dat.length);
		Aindex =>
			s = sprint("\tindir @mp+%d,%d", dat.off, dat.index);
		Arestore =>
			s = "\tapop";
			break;
		Bigs =>
			s = sprint("\tlong @mp+%d", dat.off);
			for(n := 0; n < dat.n; n++)
				s += sprint(", %bd", dat.bigs[n]);
		}
		if(flag == TK)
			datline(s + "\n");
		else
			fasm.puts(s+"\n");
	}

	if(flag == TK)
		tk->cmd(t, ".nb.data.t see 1.0");
}

# insert one literal line into the data text view (the ' prefix keeps the
# whole line, including embedded quotes, verbatim)
datline(s: string)
{
	tk->cmd(t, ".nb.data.t insert end '" + s);
}

mapstr(s: string): string
{
	for(i := 0; i < len s; i++) {
		if(s[i] == '\n')
			s = s[0:i] + "\\n" + s[i+1:];
	}
	return s;
}

tkcmds(top: ref Toplevel, cfg: array of string)
{
	for(i := 0; i < len cfg; i++)
		tk->cmd(top, cfg[i]);
}
