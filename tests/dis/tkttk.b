implement TkTtk;

#
# Headless functional test for the ttk parallel widget set and the
# ttk::style engine.  Run under a graphical emu (Xvfb).
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
include "tk.m";
	tk: Tk;
include "tkclient.m";
	tkclient: Tkclient;
include "wmclient.m";
	wmclient: Wmclient;

TkTtk: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

top: ref Tk->Toplevel;
mypid := 0;
nok := 0;
nfail := 0;

ok(desc: string, cond: int)
{
	if(cond){ nok++; sys->print("ok - %s\n", desc); }
	else { nfail++; sys->print("not ok - %s\n", desc); }
}

cmd(s: string): string
{
	return tk->cmd(top, s);
}

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	mypid = sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	tkclient->init();
	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	if(ctxt == nil){
		sys->fprint(sys->fildes(2), "tkttk: no window context\n");
		raise "fail:no ctxt";
	}
	(top, nil) = tkclient->toplevel(ctxt, "320x260", "tkttk", Tkclient->Appl);

	# build the widget set inside a ttk frame
	cmd("ttk::frame .f");
	cmd("ttk::label .f.l -text Hello");
	cmd("ttk::button .f.b -text Go -command {.f.l configure -text clicked}");
	cmd("ttk::checkbutton .f.c -text Check -variable cv -onvalue on -offvalue off");
	cmd("ttk::radiobutton .f.r1 -text A -variable rv -value a");
	cmd("ttk::radiobutton .f.r2 -text B -variable rv -value b");
	cmd("ttk::separator .f.s -orient horizontal");
	cmd("ttk::label .f.out -text -");
	cmd("pack .f.l .f.b .f.c .f.r1 .f.r2 .f.s .f.out");
	cmd("pack .f");
	cmd("update");

	# 1. classes
	ok("frame class TFrame", cmd("winfo class .f") == "TFrame");
	ok("label class TLabel", cmd("winfo class .f.l") == "TLabel");
	ok("button class TButton", cmd("winfo class .f.b") == "TButton");
	ok("check class TCheckbutton", cmd("winfo class .f.c") == "TCheckbutton");
	ok("radio class TRadiobutton", cmd("winfo class .f.r1") == "TRadiobutton");
	ok("separator class TSeparator", cmd("winfo class .f.s") == "TSeparator");

	# 2. button invoke runs -command
	cmd(".f.b invoke");
	cmd("update");
	ok("button invoke fired command", cmd(".f.l cget -text") == "clicked");

	# 3. state machine
	ok("starts in empty state", cmd(".f.b state") == "");
	cmd(".f.b state disabled");
	ok("instate disabled true", cmd(".f.b instate disabled") == "1");
	ok("instate !disabled false", cmd(".f.b instate {!disabled}") == "0");
	ok("state lists disabled", cmd(".f.b state") == "disabled");
	# disabled button does not invoke
	cmd(".f.l configure -text reset");
	cmd(".f.b invoke");
	ok("disabled button ignores invoke", cmd(".f.l cget -text") == "reset");
	cmd(".f.b state {!disabled}");
	ok("re-enabled", cmd(".f.b instate disabled") == "0");

	# 4. instate with a script
	cmd(".f.out configure -text no");
	cmd(".f.b instate {!disabled} {.f.out configure -text yes}");
	ok("instate runs script when matching", cmd(".f.out cget -text") == "yes");

	# 5. checkbutton toggles variable + selected state
	ok("check starts unselected", cmd(".f.c instate selected") == "0");
	cmd(".f.c invoke");
	cmd("update");
	ok("check variable set on", cmd("variable cv") == "on");
	ok("check now selected", cmd(".f.c instate selected") == "1");
	cmd(".f.c invoke");
	ok("check variable set off", cmd("variable cv") == "off");
	ok("check now unselected", cmd(".f.c instate selected") == "0");

	# 6. radiobutton sets shared variable
	cmd(".f.r2 invoke");
	ok("radio sets variable", cmd("variable rv") == "b");
	cmd(".f.r1 invoke");
	ok("radio re-sets variable", cmd("variable rv") == "a");

	# 7. ttk::style configure + lookup
	cmd("ttk::style configure TButton -foreground #ff0000");
	ok("style lookup returns configured value", cmd("ttk::style lookup TButton -foreground") == "#ff0000");

	# 8. ttk::style map (state-specific value)
	cmd("ttk::style map TButton -foreground {disabled #808080 active #00ff00}");
	ok("style map disabled", cmd("ttk::style lookup TButton -foreground disabled") == "#808080");
	ok("style map active", cmd("ttk::style lookup TButton -foreground active") == "#00ff00");
	ok("style map falls back to configure", cmd("ttk::style lookup TButton -foreground {}") == "#ff0000");

	# 9. style inheritance via dotted prefix
	cmd("ttk::style configure Danger.TButton -background #aa0000");
	ok("dotted style own option", cmd("ttk::style lookup Danger.TButton -background") == "#aa0000");
	ok("dotted style inherits parent", cmd("ttk::style lookup Danger.TButton -foreground") == "#ff0000");

	# 10. progressbar
	cmd("ttk::progressbar .f.p -maximum 100 -value 0 -length 120");
	cmd("pack .f.p");
	cmd("update");
	ok("progressbar class", cmd("winfo class .f.p") == "TProgressbar");
	cmd(".f.p configure -value 25");
	ok("progressbar value set", int cmd(".f.p cget -value") == 25);
	cmd(".f.p step 10");
	ok("progressbar step", int cmd(".f.p cget -value") == 35);
	cmd(".f.p configure -value 90");
	cmd(".f.p step 20");	# wraps modulo maximum (110 -> 10)
	ok("progressbar step wraps", int cmd(".f.p cget -value") == 10);

	# progressbar driven by a variable
	cmd("ttk::progressbar .f.p2 -variable pv -maximum 50");
	cmd("variable pv 20");
	cmd("update");
	ok("progressbar follows variable", int cmd(".f.p2 cget -value") == 20);

	# 11. labelframe
	cmd("ttk::labelframe .f.lf -text Group");
	cmd("ttk::label .f.lf.inner -text inside");
	cmd("pack .f.lf.inner");
	cmd("pack .f.lf");
	cmd("update");
	ok("labelframe class", cmd("winfo class .f.lf") == "TLabelframe");
	ok("labelframe title", cmd(".f.lf cget -text") == "Group");
	ok("labelframe holds child", has(cmd("winfo children .f.lf"), ".f.lf.inner"));

	# 12. ttk::entry - shares the classic editing core, themed chrome + state
	cmd("ttk::entry .f.e");
	cmd("pack .f.e");
	cmd("update");
	ok("entry class TEntry", cmd("winfo class .f.e") == "TEntry");
	cmd(".f.e insert 0 hello");
	ok("entry insert+get", cmd(".f.e get") == "hello");
	cmd(".f.e delete 0 1");
	ok("entry delete", cmd(".f.e get") == "ello");
	ok("entry style default TEntry", cmd(".f.e style") == "TEntry");
	cmd(".f.e configure -style Search.TEntry");
	ok("entry -style honoured", cmd(".f.e style") == "Search.TEntry");
	ok("entry starts !disabled", cmd(".f.e instate disabled") == "0");
	cmd(".f.e state readonly");
	cmd(".f.e insert 0 X");
	ok("readonly entry ignores insert", cmd(".f.e get") == "ello");
	cmd(".f.e state {!readonly}");
	cmd(".f.e insert 0 Y");
	ok("writable entry accepts insert", cmd(".f.e get") == "Yello");
	cmd(".f.e state disabled");
	ok("entry instate disabled", cmd(".f.e instate disabled") == "1");
	cmd(".f.e state {!disabled}");

	# 13. ttk::scrollbar - shares the classic core, flat themed chrome + state
	cmd("ttk::scrollbar .f.sb -orient vertical -command {.f.e xview}");
	cmd("pack .f.sb");
	cmd("update");
	ok("scrollbar class TScrollbar", cmd("winfo class .f.sb") == "TScrollbar");
	cmd(".f.sb set 0.0 0.5");
	ok("scrollbar set+get", cmd(".f.sb get") == "0 0.5");
	ok("scrollbar style default TScrollbar", cmd(".f.sb style") == "TScrollbar");
	cmd(".f.sb configure -style Vertical.TScrollbar");
	ok("scrollbar -style honoured", cmd(".f.sb style") == "Vertical.TScrollbar");
	ok("scrollbar starts !disabled", cmd(".f.sb instate disabled") == "0");
	cmd(".f.sb state disabled");
	ok("scrollbar instate disabled", cmd(".f.sb instate disabled") == "1");
	cmd(".f.sb state {!disabled}");
	ok("scrollbar instate !disabled", cmd(".f.sb instate disabled") == "0");

	# 14. ttk::scale - shares the classic core, flat themed trough/thumb + state
	cmd("ttk::scale .f.sc -orient horizontal -from 0 -to 100 -value 25");
	cmd("pack .f.sc");
	cmd("update");
	ok("scale class TScale", cmd("winfo class .f.sc") == "TScale");
	ok("scale -value initial", cmd(".f.sc get") == "25");
	cmd(".f.sc set 60");
	ok("scale set+get", cmd(".f.sc get") == "60");
	ok("scale style default TScale", cmd(".f.sc style") == "TScale");
	cmd(".f.sc configure -style Horizontal.TScale");
	ok("scale -style honoured", cmd(".f.sc style") == "Horizontal.TScale");
	ok("scale starts !disabled", cmd(".f.sc instate disabled") == "0");
	cmd(".f.sc state disabled");
	ok("scale instate disabled", cmd(".f.sc instate disabled") == "1");
	cmd(".f.sc state {!disabled}");

	# 15. ttk::sizegrip - a themed resize-handle decoration
	cmd("ttk::sizegrip .f.sg");
	cmd("pack .f.sg");
	cmd("update");
	ok("sizegrip class TSizegrip", cmd("winfo class .f.sg") == "TSizegrip");
	ok("sizegrip style default TSizegrip", cmd(".f.sg style") == "TSizegrip");
	cmd(".f.sg configure -style Custom.TSizegrip");
	ok("sizegrip -style honoured", cmd(".f.sg style") == "Custom.TSizegrip");
	ok("sizegrip instate !disabled", cmd(".f.sg instate disabled") == "0");

	# 16. ttk::notebook - a tabbed container (embedded-window panes)
	cmd("ttk::notebook .nb");
	cmd("ttk::frame .nb.p1");
	cmd("ttk::label .nb.p1.l -text {page one}");
	cmd("pack .nb.p1.l");
	cmd("ttk::frame .nb.p2");
	cmd("ttk::label .nb.p2.l -text {page two}");
	cmd("pack .nb.p2.l");
	cmd("ttk::frame .nb.p3");
	cmd("pack .nb");
	cmd("update");
	ok("notebook class TNotebook", cmd("winfo class .nb") == "TNotebook");
	ok("notebook style default TNotebook", cmd(".nb style") == "TNotebook");
	cmd(".nb add .nb.p1 -text One");
	cmd(".nb add .nb.p2 -text Two");
	cmd(".nb add .nb.p3 -text Three");
	cmd("update");
	ok("notebook lists three tabs", cmd(".nb tabs") == ".nb.p1 .nb.p2 .nb.p3");
	ok("notebook first add auto-selects", cmd(".nb select") == ".nb.p1");
	ok("notebook index by path", cmd(".nb index .nb.p2") == "1");
	ok("notebook index end counts tabs", cmd(".nb index end") == "3");
	ok("notebook tab -text get", cmd(".nb tab .nb.p2 -text") == "Two");
	cmd(".nb select .nb.p3");
	ok("notebook select by path", cmd(".nb select") == ".nb.p3");
	cmd(".nb select 1");
	ok("notebook select by index", cmd(".nb select") == ".nb.p2");
	cmd(".nb tab .nb.p1 -text Uno");
	ok("notebook tab -text set", cmd(".nb tab .nb.p1 -text") == "Uno");
	cmd(".nb tab .nb.p3 -state disabled");
	cmd(".nb select .nb.p3");
	ok("notebook skips disabled tab on select", cmd(".nb select") == ".nb.p2");
	cmd(".nb forget .nb.p2");
	cmd("update");
	ok("notebook forget drops a tab", cmd(".nb tabs") == ".nb.p1 .nb.p3");
	cmd(".nb configure -style Custom.TNotebook");
	ok("notebook style honoured", cmd(".nb style") == "Custom.TNotebook");
	cmd(".nb state disabled");
	ok("notebook instate disabled", cmd(".nb instate disabled") == "1");
	cmd(".nb state {!disabled}");

	# 17. ttk::panedwindow - a tiled container with draggable sashes
	cmd("ttk::panedwindow .pw -orient horizontal -width 260 -height 120");
	cmd("ttk::frame .pw.a");
	cmd("ttk::label .pw.a.l -text left");
	cmd("pack .pw.a.l");
	cmd("ttk::frame .pw.b");
	cmd("ttk::label .pw.b.l -text right");
	cmd("pack .pw.b.l");
	cmd("ttk::frame .pw.c");
	cmd("pack .pw");
	cmd("update");
	ok("panedwindow class TPanedwindow", cmd("winfo class .pw") == "TPanedwindow");
	ok("panedwindow style default", cmd(".pw style") == "TPanedwindow");
	ok("panedwindow orient honoured", cmd(".pw cget -orient") == "horizontal");
	# two wide panes: sash 0 has room to move to 80
	cmd(".pw add .pw.a");
	cmd(".pw add .pw.b");
	cmd("update");
	ok("panedwindow lists panes", cmd(".pw panes") == ".pw.a .pw.b");
	cmd(".pw sashpos 0 80");
	cmd("update");
	ok("panedwindow sashpos set+get", cmd(".pw sashpos 0") == "80");
	cmd(".pw add .pw.c");
	cmd("update");
	ok("panedwindow add a third pane", cmd(".pw panes") == ".pw.a .pw.b .pw.c");
	cmd(".pw forget .pw.b");
	cmd("update");
	ok("panedwindow forget drops a pane", cmd(".pw panes") == ".pw.a .pw.c");
	cmd(".pw configure -style Custom.TPanedwindow");
	ok("panedwindow style honoured", cmd(".pw style") == "Custom.TPanedwindow");
	cmd(".pw state disabled");
	ok("panedwindow instate disabled", cmd(".pw instate disabled") == "1");
	cmd(".pw state {!disabled}");

	# ---- 18. ttk::treeview ----
	cmd("ttk::treeview .tv -columns {size kind} -height 6");
	cmd("pack .tv");
	cmd("update");
	ok("treeview class Treeview", cmd("winfo class .tv") == "Treeview");
	ok("treeview style default", cmd(".tv style") == "Treeview");
	# headings
	cmd(".tv heading #0 -text Name");
	cmd(".tv heading size -text Size");
	ok("treeview heading get", cmd(".tv heading size") == "Size");
	cmd(".tv column size -width 60 -anchor e");
	ok("treeview column width get", cmd(".tv column size") == "60");
	# insert items, capture ids
	root1 := cmd(".tv insert {} end -text alpha -values {10 dir}");
	ok("treeview insert returns id", root1 != "" && root1[0] == 'I');
	child1 := cmd(".tv insert " + root1 + " end -text beta -values {20 file}");
	cmd(".tv insert {} end -id leaf -text gamma");
	ok("treeview explicit id honoured", cmd(".tv exists leaf") == "1");
	ok("treeview exists negative", cmd(".tv exists nope") == "0");
	ok("treeview children", cmd(".tv children " + root1) == child1);
	ok("treeview parent", cmd(".tv parent " + child1) == root1);
	ok("treeview index", cmd(".tv index leaf") == "1");
	ok("treeview item -text get", cmd(".tv item " + root1 + " -text") == "alpha");
	cmd(".tv item " + root1 + " -text ALPHA");
	ok("treeview item -text set", cmd(".tv item " + root1 + " -text") == "ALPHA");
	ok("treeview item -values get", cmd(".tv item " + child1 + " -values") == "20 file");
	# selection + focus
	cmd(".tv selection set " + root1);
	ok("treeview selection set/get", cmd(".tv selection") == root1);
	cmd(".tv selection add leaf");
	ok("treeview selection add", has(cmd(".tv selection"), "leaf"));
	cmd(".tv selection remove " + root1);
	ok("treeview selection remove", cmd(".tv selection") == "leaf");
	cmd(".tv focus leaf");
	ok("treeview focus get", cmd(".tv focus") == "leaf");
	# open/close affects nothing queryable but item -open does
	cmd(".tv item " + root1 + " -open 1");
	ok("treeview item -open get", cmd(".tv item " + root1 + " -open") == "1");
	# move + reparent
	cmd(".tv move leaf " + root1 + " end");
	ok("treeview move reparents", cmd(".tv parent leaf") == root1);
	# delete
	cmd(".tv delete " + root1);
	ok("treeview delete subtree", cmd(".tv exists leaf") == "0");
	ok("treeview delete root item", cmd(".tv exists " + root1) == "0");
	# state/instate
	cmd(".tv state disabled");
	ok("treeview instate disabled", cmd(".tv instate disabled") == "1");
	cmd(".tv state {!disabled}");

	# ---- 19. ttk::combobox ----
	cmd("ttk::combobox .cb -values {red green blue}");
	cmd("pack .cb");
	cmd("update");
	ok("combobox class TCombobox", cmd("winfo class .cb") == "TCombobox");
	ok("combobox style default", cmd(".cb style") == "TCombobox");
	ok("combobox -values cget", cmd(".cb cget -values") == "red green blue");
	# current get with nothing selected
	ok("combobox current empty", cmd(".cb current") == "");
	# set by index
	cmd(".cb current 1");
	ok("combobox current set index", cmd(".cb current") == "1");
	ok("combobox text follows current", cmd(".cb get") == "green");
	# set by value string (matches a -value -> updates current)
	cmd(".cb set blue");
	ok("combobox set known value", cmd(".cb get") == "blue");
	ok("combobox current tracks set", cmd(".cb current") == "2");
	# set an unknown value -> current clears
	cmd(".cb set purple");
	ok("combobox set unknown value", cmd(".cb get") == "purple");
	ok("combobox current clears on unknown", cmd(".cb current") == "");
	# still an editable entry: insert works in normal state
	cmd(".cb delete 0 end");
	cmd(".cb insert 0 hello");
	ok("combobox editable insert", cmd(".cb get") == "hello");
	# readonly state blocks typing but keeps the widget
	cmd(".cb state readonly");
	ok("combobox instate readonly", cmd(".cb instate readonly") == "1");
	cmd(".cb insert 0 X");
	ok("combobox readonly blocks insert", cmd(".cb get") == "hello");
	cmd(".cb state {!readonly}");
	# tkComboPick (what a dropdown selection runs) sets text + current
	cmd(".cb tkComboPick 0");
	ok("combobox pick sets value", cmd(".cb get") == "red");
	ok("combobox pick sets current", cmd(".cb current") == "0");

	# ---- 20. ttk::spinbox ----
	cmd("ttk::spinbox .sp -from 0 -to 10 -increment 2");
	cmd("pack .sp");
	ok("spinbox class TSpinbox", cmd("winfo class .sp") == "TSpinbox");
	ok("spinbox style default", cmd(".sp style") == "TSpinbox");
	ok("spinbox -from cget", cmd(".sp cget -from") == "0");
	ok("spinbox -increment cget", cmd(".sp cget -increment") == "2");
	cmd(".sp set 4");
	ok("spinbox set/get", cmd(".sp get") == "4");
	cmd(".sp tkSpinStep 1");
	ok("spinbox step up by increment", cmd(".sp get") == "6");
	cmd(".sp tkSpinStep -1");
	ok("spinbox step down by increment", cmd(".sp get") == "4");
	# clamp at the top of the range (no -wrap)
	cmd(".sp set 10");
	cmd(".sp tkSpinStep 1");
	ok("spinbox clamps at -to", cmd(".sp get") == "10");
	cmd(".sp set 0");
	cmd(".sp tkSpinStep -1");
	ok("spinbox clamps at -from", cmd(".sp get") == "0");
	# -wrap wraps round the ends
	cmd(".sp configure -wrap 1");
	cmd(".sp set 10");
	cmd(".sp tkSpinStep 1");
	ok("spinbox wrap top to bottom", cmd(".sp get") == "0");
	cmd(".sp tkSpinStep -1");
	ok("spinbox wrap bottom to top", cmd(".sp get") == "10");
	# disabled state blocks stepping
	cmd(".sp configure -wrap 0");
	cmd(".sp set 4");
	cmd(".sp state disabled");
	cmd(".sp tkSpinStep 1");
	ok("spinbox disabled blocks step", cmd(".sp get") == "4");
	cmd(".sp state {!disabled}");
	# -values mode: stepping cycles the list
	cmd("ttk::spinbox .sv -values {apple banana cherry}");
	cmd("pack .sv");
	cmd(".sv set banana");
	cmd(".sv tkSpinStep 1");
	ok("spinbox values step forward", cmd(".sv get") == "cherry");
	cmd(".sv tkSpinStep -1");
	ok("spinbox values step back", cmd(".sv get") == "banana");

	# ---- 21. ttk::menubutton ----
	# (the live post path needs a wm to return the window image, like the
	#  combobox dropdown, so only the data model + state are unit-tested here)
	cmd("menu .m");
	cmd(".m add command -label One");
	cmd(".m add command -label Two");
	cmd("ttk::menubutton .mb -text Actions -menu .m");
	cmd("pack .mb");
	ok("menubutton class TMenubutton", cmd("winfo class .mb") == "TMenubutton");
	ok("menubutton style default", cmd(".mb style") == "TMenubutton");
	ok("menubutton -text cget", cmd(".mb cget -text") == "Actions");
	ok("menubutton -menu cget", cmd(".mb cget -menu") == ".m");
	ok("menubutton starts empty state", cmd(".mb state") == "");
	cmd(".mb configure -text Menu");
	ok("menubutton reconfigure -text", cmd(".mb cget -text") == "Menu");
	cmd(".mb state disabled");
	ok("menubutton instate disabled", cmd(".mb instate disabled") == "1");
	# pressing while disabled is a clean no-op (returns before any wm request)
	ok("disabled menubutton press is a no-op", cmd(".mb tkttkMbpress") == "");
	cmd(".mb state {!disabled}");
	ok("menubutton re-enabled", cmd(".mb instate disabled") == "0");

	# ---- 22. classic entry -validate (Phase 4 classic completeness) ----
	# The validatecommand is an ordinary Tk script; here it records the %P
	# substitution into one variable and returns the boolean held in another,
	# so we can drive accept/reject deterministically.
	cmd("entry .ve");
	cmd("pack .ve");
	cmd("variable allow 1");
	cmd(".ve configure -validate key -validatecommand {variable seen %P; variable allow}");
	cmd(".ve insert end abc");
	ok("validate allows when command true", cmd(".ve get") == "abc");
	ok("validate %P substituted to new value", cmd("variable seen") == "abc");
	cmd("variable allow 0");
	cmd(".ve insert end Z");
	ok("validate rejects insert when command false", cmd(".ve get") == "abc");
	# -invalidcommand fires on rejection, seeing the %S change string
	cmd("variable bads {}");
	cmd(".ve configure -invalidcommand {variable bads %S}");
	cmd(".ve insert end Q");
	ok("invalidcommand ran with %S change", cmd("variable bads") == "Q");
	ok("rejected insert left text intact", cmd(".ve get") == "abc");
	# delete is validated too (type 0)
	cmd(".ve delete 0 1");
	ok("validate blocks delete when false", cmd(".ve get") == "abc");
	cmd("variable allow 1");
	cmd(".ve delete 0 1");
	ok("validate allows delete when true", cmd(".ve get") == "bc");
	# -validate none => no checks at all
	cmd(".ve configure -validate none");
	cmd("variable allow 0");
	cmd(".ve insert end XY");
	ok("validate none ignores the command", cmd(".ve get") == "bcXY");
	# a non-boolean result disables validation (Tk's rule) and lets the edit through
	cmd(".ve configure -validate key -validatecommand {variable nope}");
	cmd(".ve insert end !");
	ok("non-boolean result lets edit through", cmd(".ve get") == "bcXY!");
	ok("non-boolean result turned validation off", cmd(".ve cget -validate") == "none");

	# ---- 23. classic spinbox (Phase 4: entry spin core, classic chrome) ----
	cmd("spinbox .cs -from 0 -to 10 -increment 2");
	cmd("pack .cs");
	ok("spinbox class spinbox", cmd("winfo class .cs") == "spinbox");
	ok("spinbox -from cget", cmd(".cs cget -from") == "0");
	cmd(".cs set 4");
	ok("spinbox set/get", cmd(".cs get") == "4");
	cmd(".cs tkSpinStep 1");
	ok("spinbox step up by increment", cmd(".cs get") == "6");
	cmd(".cs tkSpinStep -1");
	ok("spinbox step down by increment", cmd(".cs get") == "4");
	cmd(".cs set 10");
	cmd(".cs tkSpinStep 1");
	ok("spinbox clamps at -to", cmd(".cs get") == "10");
	# -values list mode works on the classic spinbox too
	cmd("spinbox .cv -values {alpha beta gamma}");
	cmd("pack .cv");
	cmd(".cv set beta");
	cmd(".cv tkSpinStep 1");
	ok("classic spinbox values step", cmd(".cv get") == "gamma");

	# ---- 24. text widget -undo / edit (Phase 4 classic completeness) ----
	cmd("text .tx -undo 1");
	cmd("pack .tx");
	cmd(".tx insert 1.0 hello");
	ok("text inserted", cmd(".tx get 1.0 1.5") == "hello");
	ok("text canundo true", cmd(".tx edit canundo") == "1");
	cmd(".tx edit separator");
	cmd(".tx insert 1.5 { world}");
	ok("text second insert", cmd(".tx get 1.0 {1.0 lineend}") == "hello world");
	cmd(".tx edit undo");
	ok("text undo last group", cmd(".tx get 1.0 {1.0 lineend}") == "hello");
	cmd(".tx edit undo");
	ok("text undo first group", cmd(".tx get 1.0 {1.0 lineend}") == "");
	ok("text canundo false now", cmd(".tx edit canundo") == "0");
	ok("text canredo true", cmd(".tx edit canredo") == "1");
	cmd(".tx edit redo");
	ok("text redo first", cmd(".tx get 1.0 {1.0 lineend}") == "hello");
	cmd(".tx edit redo");
	ok("text redo second", cmd(".tx get 1.0 {1.0 lineend}") == "hello world");
	# delete is undoable too
	cmd(".tx edit separator");
	cmd(".tx delete 1.0 1.5");
	ok("text delete", cmd(".tx get 1.0 {1.0 lineend}") == " world");
	cmd(".tx edit undo");
	ok("text undo delete", cmd(".tx get 1.0 {1.0 lineend}") == "hello world");
	# modified flag
	cmd(".tx edit modified 0");
	ok("text modified cleared", cmd(".tx edit modified") == "0");
	cmd(".tx insert 1.0 X");
	ok("text modified after edit", cmd(".tx edit modified") == "1");
	# -undo off discards history
	cmd(".tx configure -undo 0");
	ok("text undo off: canundo false", cmd(".tx edit canundo") == "0");

	# ---- 25. listbox -activestyle + extended selection (Phase 4) ----
	cmd("listbox .lb");
	cmd("pack .lb");
	cmd(".lb insert end a b c d e");
	ok("listbox activestyle default dotbox", cmd(".lb cget -activestyle") == "dotbox");
	cmd(".lb configure -activestyle underline");
	ok("listbox activestyle underline", cmd(".lb cget -activestyle") == "underline");
	cmd(".lb configure -activestyle none");
	ok("listbox activestyle none", cmd(".lb cget -activestyle") == "none");
	cmd(".lb configure -activestyle dotbox");
	ok("listbox activestyle back to dotbox", cmd(".lb cget -activestyle") == "dotbox");
	# extended-mode range selection (selection set/clear/includes/anchor)
	cmd(".lb configure -selectmode extended");
	ok("listbox selectmode extended", cmd(".lb cget -selectmode") == "extended");
	cmd(".lb selection set 1 3");
	ok("listbox range selected lo", cmd(".lb selection includes 1") == "1");
	ok("listbox range selected hi", cmd(".lb selection includes 3") == "1");
	ok("listbox outside range clear", cmd(".lb selection includes 0") == "0");
	ok("listbox above range clear", cmd(".lb selection includes 4") == "0");
	cmd(".lb selection clear 2 2");
	ok("listbox cleared one in range", cmd(".lb selection includes 2") == "0");
	ok("listbox neighbour still set", cmd(".lb selection includes 1") == "1");

	# ---- 26. text widget embedded images (Phase 4) ----
	img := cmd("image create bitmap -file clock.bit");
	ok("test image created", len img > 0 && img[0] != '!');
	cmd("text .ti");
	cmd("pack .ti");
	cmd(".ti insert 1.0 hello");
	ok("no embedded images yet", cmd(".ti image names") == "");
	nm := cmd(".ti image create 1.2 -image " + img);
	ok("image create returns a name", len nm > 0 && nm[0] != '!');
	ok("image names lists it", cmd(".ti image names") == nm);
	ok("image cget -image", cmd(".ti image cget 1.2 -image") == img);
	ok("image align defaults to center", cmd(".ti image cget 1.2 -align") == "center");
	# the image occupies exactly one index position (he<img>llo -> lineend 1.6)
	ok("embedded image is one position", cmd(".ti index {1.0 lineend}") == "1.6");
	cmd(".ti image configure 1.2 -align top");
	ok("image configure -align", cmd(".ti image cget 1.2 -align") == "top");
	# deleting the image position removes it from the line
	cmd(".ti delete 1.2 1.3");
	ok("deleted embedded image", cmd(".ti image names") == "");
	ok("line back to 5 positions", cmd(".ti index {1.0 lineend}") == "1.5");

	sys->print("1..%d\n", nok+nfail);
	if(nfail == 0)
		sys->print("# all %d ttk tests passed\n", nok);
	else
		sys->print("# %d FAILED\n", nfail);
	shutdown();
	exit;
}

has(s: string, sub: string): int
{
	n := len sub;
	for(i := 0; i+n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

shutdown()
{
	fd := sys->open("#p/" + string mypid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}
