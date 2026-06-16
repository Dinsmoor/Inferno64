implement Titlebar;
include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Point, Rect: import draw;
include "tk.m";
	tk: Tk;
include "titlebar.m";

# Titlebar colours come from the system theme (libtk "theme get": titlebg =
# unfocused bar, titlefocusbg = focused bar, titlefg = text).  These fallbacks
# match the historical hardcoded look and are used when no theme is set.
DEFTITLEBG:	con "#aaaaaaff";
DEFTITLEFG:	con "#ffffffff";
DEFTITLEFOCUSBG: con "#0000ffff";

# The window-control bindings (move/maximize/menu) never change with the theme.
title_binds := array[] of {
	"button .Wm_t.e -bitmap exit.bit -command {send wm_title exit} -takefocus 0",
	"pack .Wm_t.e -side right",
	"bind .Wm_t <Button-1> {send wm_title move %X %Y}",
	"bind .Wm_t <Double-Button-1> {send wm_title maximize}",
	"bind .Wm_t <Motion-Button-1> {}",
	"bind .Wm_t <Motion> {}",
	"bind .Wm_t.title <Button-1> {send wm_title move %X %Y}",
	"bind .Wm_t.title <Double-Button-1> {send wm_title maximize}",
	"bind .Wm_t.title <Motion-Button-1> {}",
	"bind .Wm_t.title <Motion> {}",
};

init()
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
}

# Fetch the three titlebar colours from the current theme.
titlecolours(top: ref Tk->Toplevel): (string, string, string)
{
	s := tk->cmd(top, "theme get");
	if(s == nil || s[0] == '!')
		return (DEFTITLEBG, DEFTITLEFG, DEFTITLEFOCUSBG);
	tbg := themeval(s, "titlebg");
	tfg := themeval(s, "titlefg");
	tfbg := themeval(s, "titlefocusbg");
	if(tbg == nil) tbg = DEFTITLEBG;
	if(tfg == nil) tfg = DEFTITLEFG;
	if(tfbg == nil) tfbg = DEFTITLEFOCUSBG;
	return (tbg, tfg, tfbg);
}

# Pull the value of `key` from a "key val key val ..." theme string (whole-word
# match so "bg" does not match inside "titlebg").
themeval(s, key: string): string
{
	target := key + " ";
	n := len s;
	tlen := len target;
	for(i := 0; i + tlen <= n; i++){
		if((i == 0 || s[i-1] == ' ') && s[i:i+tlen] == target){
			j := i + tlen;
			k := j;
			while(k < n && s[k] != ' ')
				k++;
			return s[j:k];
		}
	}
	return nil;
}

# Apply the focus-colour bindings for a given palette.
focusbindings(top: ref Tk->Toplevel, tbg, tfbg: string)
{
	cmd(top, "bind . <FocusIn> {.Wm_t configure -bg " + tfbg + ";"+
		".Wm_t.title configure -bg " + tfbg + ";update}");
	cmd(top, "bind . <FocusOut> {.Wm_t configure -bg " + tbg + ";"+
		".Wm_t.title configure -bg " + tbg + ";update}");
}

# Re-apply theme colours to an existing titlebar (called on live re-theme).
retheme(top: ref Tk->Toplevel)
{
	if(tk->cmd(top, "winfo class .Wm_t")[0] == '!')	# Plain window: no titlebar
		return;
	(tbg, tfg, tfbg) := titlecolours(top);
	cmd(top, ".Wm_t configure -bg " + tbg);
	cmd(top, ".Wm_t.title configure -bg " + tbg + " -fg " + tfg);
	focusbindings(top, tbg, tfbg);
	cmd(top, "update");
}

new(top: ref Tk->Toplevel, buts: int): chan of string
{
	ctl := chan of string;
	tk->namechan(top, ctl, "wm_title");

	if(buts & Plain)
		return ctl;

	(tbg, tfg, tfbg) := titlecolours(top);
	cmd(top, "frame .Wm_t -bg " + tbg + " -borderwidth 1");
	cmd(top, "label .Wm_t.title -anchor w -bg " + tbg + " -fg " + tfg);
	for(i := 0; i < len title_binds; i++)
		cmd(top, title_binds[i]);
	focusbindings(top, tbg, tfbg);

	if(buts & OK)
		cmd(top, "button .Wm_t.ok -bitmap ok.bit"+
			" -command {send wm_title ok} -takefocus 0; pack .Wm_t.ok -side right");

	if(buts & Hide)
		cmd(top, "button .Wm_t.top -bitmap task.bit"+
			" -command {send wm_title task} -takefocus 0; pack .Wm_t.top -side right");

	if(buts & Resize)
		cmd(top, "button .Wm_t.m -bitmap maxf.bit"+
			" -command {send wm_title maximize} -takefocus 0; pack .Wm_t.m -side right");

	if(buts & Help)
		cmd(top, "button .Wm_t.h -bitmap help.bit"+
			" -command {send wm_title help} -takefocus 0; pack .Wm_t.h -side right");

	# right-click window-operations menu
	cmd(top, "menu .Wm_tmenu");
	if(buts & Resize){
		cmd(top, ".Wm_tmenu add command -command {send wm_title maximize} -label {Maximize / Restore}");
		cmd(top, ".Wm_tmenu add command -command {send wm_title snap left} -label {Snap left}");
		cmd(top, ".Wm_tmenu add command -command {send wm_title snap right} -label {Snap right}");
	}
	if(buts & Hide)
		cmd(top, ".Wm_tmenu add command -command {send wm_title task} -label {Minimize}");
	cmd(top, ".Wm_tmenu add separator");
	cmd(top, ".Wm_tmenu add command -command {send wm_title exit} -label {Close}");
	cmd(top, "bind .Wm_t <Button-3> {.Wm_tmenu post %X %Y}");
	cmd(top, "bind .Wm_t.title <Button-3> {.Wm_tmenu post %X %Y}");

	# pack the title last so it gets clipped first
	cmd(top, "pack .Wm_t.title -side left");
	cmd(top, "pack .Wm_t -fill x");

	return ctl;
}

title(top: ref Tk->Toplevel): string
{
	if(tk->cmd(top, "winfo class .Wm_t.title")[0] != '!')
		return cmd(top, ".Wm_t.title cget -text");
	return nil;
}
	
settitle(top: ref Tk->Toplevel, t: string): string
{
	s := title(top);
	tk->cmd(top, ".Wm_t.title configure -text '" + t);
	return s;
}

sendctl(top: ref Tk->Toplevel, c: string)
{
	cmd(top, "send wm_title " + c);
}

minsize(top: ref Tk->Toplevel): Point
{
	buts := array[] of {"e", "ok", "top", "m", "h"};
	r := tk->rect(top, ".", Tk->Border);
	r.min.x = r.max.x;
	r.max.y = r.min.y;
	for(i := 0; i < len  buts; i++){
		br := tk->rect(top, ".Wm_t." + buts[i], Tk->Border);
		if(br.dx() > 0)
			r = r.combine(br);
	}
	r.max.x += tk->rect(top, ".Wm_t." + buts[0], Tk->Border).dx();
	return r.size();
}

cmd(top: ref Tk->Toplevel, s: string): string
{
	e := tk->cmd(top, s);
	if (e != nil && e[0] == '!')
		sys->fprint(sys->fildes(2), "wmclient: tk error %s on '%s'\n", e, s);
	return e;
}
