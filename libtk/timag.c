#include "lib9.h"
#include "draw.h"
#include "tk.h"
#include "textw.h"

#define imark u.mark
#define iimag u.imag

#define	O(t, e)		((long)(&((t*)0)->e))

static char* tktimgcget(Tk*, char*, char**);
static char* tktimgconfigure(Tk*, char*, char**);
static char* tktimgcreate(Tk*, char*, char**);
static char* tktimgnames(Tk*, char*, char**);

static
TkStab tkalign[] =
{
	"top",		Tktop,
	"bottom",	Tkbottom,
	"center",	Tkcenter,
	"baseline",	Tkbaseline,
	nil
};

static
TkOption timgopts[] =
{
	"image",	OPTtext,	O(TkTimg, imgname),	nil,
	"align",	OPTstab,	O(TkTimg, align),	tkalign,
	"padx",		OPTnndist,	O(TkTimg, padx),	nil,
	"pady",		OPTnndist,	O(TkTimg, pady),	nil,
	"name",		OPTtext,	O(TkTimg, name),	nil,
	nil
};

TkCmdtab
tktimgcmd[] =
{
	"cget",		tktimgcget,
	"configure",	tktimgconfigure,
	"create",	tktimgcreate,
	"names",	tktimgnames,
	nil
};

/* release the image ref + strings of an embedded-image item */
void
tktimgfree(TkTimg *w)
{
	if(w == nil)
		return;
	if(w->tki != nil)
		tkimgput(w->tki);
	free(w->imgname);
	free(w->name);
	free(w);
}

/* (re)resolve -image to a held TkImg ref; sizes come from the image */
static char*
tktimgresolve(Tk *tk, TkTimg *w)
{
	TkImg *tki;

	tki = nil;
	if(w->imgname != nil && w->imgname[0] != '\0'){
		tki = tkname2img(tk->env->top, w->imgname);
		if(tki == nil)
			return TkBadvl;
		tki->ref++;
	}
	if(w->tki != nil)
		tkimgput(w->tki);
	w->tki = tki;
	return nil;
}

static char*
tktimgcget(Tk *tk, char *arg, char **val)
{
	char *e;
	TkTindex ix;
	TkOptab tko[2];

	e = tktindparse(tk, &arg, &ix);
	if(e != nil)
		return e;
	if(ix.item->kind != TkTimage)
		return TkBadwp;

	tko[0].ptr = ix.item->iimag;
	tko[0].optab = timgopts;
	tko[1].ptr = nil;

	return tkgencget(tko, arg, val, tk->env->top);
}

static char*
tktimgconfigure(Tk *tk, char *arg, char **val)
{
	char *e;
	TkTindex ix;
	TkOptab tko[2];

	USED(val);

	e = tktindparse(tk, &arg, &ix);
	if(e != nil)
		return e;
	if(ix.item->kind != TkTimage)
		return TkBadwp;

	tko[0].ptr = ix.item->iimag;
	tko[0].optab = timgopts;
	tko[1].ptr = nil;

	if(*arg == '\0')
		return tkconflist(tko, val);

	e = tkparse(tk->env->top, arg, tko, nil);
	if(e != nil)
		return e;

	e = tktimgresolve(tk, ix.item->iimag);
	if(e != nil)
		return e;

	tktfixgeom(tk, tktprevwrapline(tk, ix.line), ix.line, 0);
	tktextsize(tk, 1);
	return nil;
}

static char*
tktimgcreate(Tk *tk, char *arg, char **val)
{
	char *e;
	TkTindex ix;
	TkTitem *i;
	TkText *tkt;
	TkTimg *w;
	TkOptab tko[2];
	static int seq;

	tkt = TKobj(TkText, tk);

	e = tktindparse(tk, &arg, &ix);
	if(e != nil)
		return e;

	e = tktnewitem(TkTimage, 0, &i);
	if(e != nil)
		return e;

	i->iimag = mallocz(sizeof(TkTimg), 1);
	if(i->iimag == nil){
		tktfreeitems(tkt, i, 1);
		return TkNomem;
	}
	w = i->iimag;
	w->align = Tkcenter;

	tko[0].ptr = w;
	tko[0].optab = timgopts;
	tko[1].ptr = nil;

	e = tkparse(tk->env->top, arg, tko, nil);
	if(e != nil){
err1:
		tktfreeitems(tkt, i, 1);
		return e;
	}
	if(w->imgname == nil || w->imgname[0] == '\0'){
		e = TkOparg;
		goto err1;
	}
	e = tktimgresolve(tk, w);
	if(e != nil)
		goto err1;

	if(w->name == nil)
		w->name = smprint("tktimage#%d", ++seq);

	e = tktsplititem(&ix);
	if(e != nil)
		goto err1;

	tktiteminsert(tkt, &ix, i);

	tktadjustind(tkt, TkTbyitemback, &ix);
	tktfixgeom(tk, tktprevwrapline(tk, ix.line), ix.line, 0);
	tktextsize(tk, 1);

	return tkvalue(val, "%s", w->name);
}

static char*
tktimgnames(Tk *tk, char *arg, char **val)
{
	char *e, *fmt;
	TkTindex ix;
	TkText *tkt = TKobj(TkText, tk);

	USED(arg);

	tktstartind(tkt, &ix);
	fmt = "%s";
	do {
		if(ix.item->kind == TkTimage && ix.item->iimag->name != nil){
			e = tkvalue(val, fmt, ix.item->iimag->name);
			if(e != nil)
				return e;
			fmt = " %s";
		}
	} while(tktadjustind(tkt, TkTbyitem, &ix));
	return nil;
}
