implement WmTtkdemo;

#
# wm/ttkdemo - a gallery of the native ttk widget set (class names
# TFrame/TLabel/TButton/TCheckbutton/TRadiobutton/TSeparator/TProgressbar/
# TLabelframe), shown beside the classic widgets for comparison.  Also
# exercises `ttk::style' restyling and the progressbar animation.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;

WmTtkdemo: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

top: ref Tk->Toplevel;

cmd(s: string): string
{
	return tk->cmd(top, s);
}

cfg := array[] of {
	# classic widgets (for side-by-side comparison)
	"frame .classic -borderwidth 2 -relief groove",
	"label .classic.t -text {classic}",
	"label .classic.l -text Label",
	"button .classic.b -text Button",
	"checkbutton .classic.c -text Check",
	"radiobutton .classic.r1 -text One -variable cls -value 1",
	"radiobutton .classic.r2 -text Two -variable cls -value 2",
	"pack .classic.t .classic.l .classic.b .classic.c .classic.r1 .classic.r2 -fill x",

	# ttk widgets
	"ttk::frame .modern",
	"ttk::label .modern.t -text {ttk}",
	"ttk::label .modern.l -text Label",
	"ttk::button .modern.b -text Button -command {.modern.l configure -text clicked!}",
	"ttk::checkbutton .modern.c -text Check -variable mc",
	"ttk::radiobutton .modern.r1 -text One -variable mr -value 1",
	"ttk::radiobutton .modern.r2 -text Two -variable mr -value 2",
	"ttk::separator .modern.s -orient horizontal",
	"ttk::entry .modern.e",
	".modern.e insert 0 {edit me}",
	# a themed listbox + ttk::scrollbar, wired the usual two-way
	"frame .modern.lbf",
	"listbox .modern.lbf.l -height 4 -width 12 -yscrollcommand {.modern.lbf.sb set}",
	"ttk::scrollbar .modern.lbf.sb -orient vertical -command {.modern.lbf.l yview}",
	".modern.lbf.l insert end one two three four five six",
	"pack .modern.lbf.sb -side right -fill y",
	"pack .modern.lbf.l -side left -fill both -expand 1",
	"pack .modern.t .modern.l .modern.b .modern.c .modern.r1 .modern.r2 .modern.s .modern.e .modern.lbf -fill x",

	# progress group
	"ttk::labelframe .lf -text {Progress}",
	"ttk::progressbar .lf.p1 -length 170 -maximum 100 -value 65",
	"ttk::progressbar .lf.p2 -length 170 -mode indeterminate",
	# a ttk::scale drives the determinate bar live
	"ttk::scale .lf.sc -orient horizontal -length 170 -from 0 -to 100 -value 65 -command {.lf.p1 configure -value}",
	"ttk::button .lf.go -text {Animate} -command {.lf.p2 start}",
	"ttk::button .lf.halt -text {Stop} -command {.lf.p2 stop}",
	"pack .lf.p1 .lf.sc .lf.p2 .lf.go .lf.halt -padx 6 -pady 3 -fill x",

	# a notebook with three pages, each an embedded ttk::frame
	"ttk::notebook .nb",
	"ttk::frame .nb.f1",
	"ttk::label .nb.f1.l -text {First page content}",
	"ttk::checkbutton .nb.f1.c -text {a check on page one}",
	"pack .nb.f1.l .nb.f1.c -anchor w -padx 6 -pady 4",
	"ttk::frame .nb.f2",
	"ttk::label .nb.f2.l -text {Second page}",
	"ttk::button .nb.f2.b -text {page-two button}",
	"pack .nb.f2.l .nb.f2.b -anchor w -padx 6 -pady 4",
	"ttk::frame .nb.f3",
	"ttk::label .nb.f3.l -text {Third page}",
	"pack .nb.f3.l -anchor w -padx 6 -pady 4",
	".nb add .nb.f1 -text One",
	".nb add .nb.f2 -text Two",
	".nb add .nb.f3 -text Three",

	# a horizontal panedwindow with two draggable panes
	"ttk::panedwindow .pw -orient horizontal -width 220 -height 150",
	"ttk::labelframe .pw.left -text Left",
	"ttk::label .pw.left.l -text {drag the sash ->}",
	"pack .pw.left.l -padx 6 -pady 6",
	"ttk::labelframe .pw.right -text Right",
	"ttk::label .pw.right.l -text {... to resize}",
	"pack .pw.right.l -padx 6 -pady 6",
	".pw add .pw.left",
	".pw add .pw.right",

	# a treeview with two data columns and a nested, open subtree
	"ttk::frame .tvf",
	"ttk::treeview .tvf.t -columns {size kind} -height 7 -yscrollcommand {.tvf.sb set}",
	"ttk::scrollbar .tvf.sb -orient vertical -command {.tvf.t yview}",
	".tvf.t heading #0 -text Name",
	".tvf.t heading size -text Size",
	".tvf.t heading kind -text Kind",
	".tvf.t column #0 -width 130",
	".tvf.t column size -width 56 -anchor e",
	".tvf.t column kind -width 56",
	".tvf.t insert {} end -id src -text src -values {- dir} -open 1",
	".tvf.t insert src end -text tk.c -values {41k C}",
	".tvf.t insert src end -text ttktree.c -values {28k C}",
	".tvf.t insert src end -id img -text images -values {- dir} -open 1",
	".tvf.t insert img end -text logo.png -values {12k PNG}",
	".tvf.t insert img end -text icon.gif -values {3k GIF}",
	".tvf.t insert {} end -text README -values {2k text}",
	".tvf.t selection set src",
	"pack .tvf.sb -side right -fill y",
	"pack .tvf.t -side left -fill both -expand 1",

	"pack .classic .modern .lf .nb .pw .tvf -side left -padx 8 -pady 8 -anchor n",

	# a sizegrip in the bottom-right corner
	"ttk::sizegrip .sg",
	"pack .sg -side right -anchor se",

	# a restyled (red) button via the style engine
	"ttk::style configure Danger.TButton -foreground #ffffff",
	"ttk::style map Danger.TButton -background {active #cc0000}",
	"update",
};

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	if(ctxt == nil){
		sys->fprint(sys->fildes(2), "ttkdemo: no window context\n");
		raise "fail:bad context";
	}
	tkclient->init();
	menubut: chan of string;
	(top, menubut) = tkclient->toplevel(ctxt, "", "ttk widget gallery", Tkclient->Appl);

	for(i := 0; i < len cfg; i++)
		cmd(cfg[i]);

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd"::"ptr"::nil);
	stop := chan of int;
	spawn tkclient->handler(top, stop);
	while((menu := <-menubut) != "exit")
		tkclient->wmctl(top, menu);
	stop <-= 1;
}
