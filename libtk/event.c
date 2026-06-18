#include "lib9.h"
#include "draw.h"
#include "tk.h"

/*
 * The `event' command: `event generate' synthesises an event and delivers it,
 * and the virtual-event registry that backs `bind .w <<Name>> script'.
 *
 * Concrete events (<Button-1>, <Motion>, <Key-x>, ...) are parsed with the
 * same tkseqparse() the bind engine uses, then delivered through tkdeliver()
 * with a synthesised TkMouse.  Virtual events (<<Name>>) carry no bitmask and
 * are kept on a per-top list keyed by {widget, name}; `event generate' walks
 * it and re-execs each stored script.
 *
 * This is purely additive: nothing creates a virtual binding unless an app
 * uses the <<...>> form, and the concrete path only fires bindings the app
 * itself installed.
 */

/*
 * Attach (cmd != nil) or remove (cmd == nil) a virtual-event binding.
 * Removing with no name (name == nil) drops every virtual binding on tk.
 */
char*
tkvirtbind(TkTop *t, Tk *tk, char *name, char *cmd, int add)
{
	TkVirt *v, **l;

	if(!add){
		/* replace: drop existing bindings for this {tk,name} first */
		l = &t->virts;
		while((v = *l) != nil){
			if(v->tk == tk && (name == nil || strcmp(v->name, name) == 0)){
				*l = v->link;
				free(v->name);
				free(v->cmd);
				free(v);
				continue;
			}
			l = &v->link;
		}
	}
	if(cmd == nil || cmd[0] == '\0')
		return nil;

	v = malloc(sizeof(TkVirt));
	if(v == nil)
		return TkNomem;
	v->tk = tk;
	v->name = strdup(name);
	v->cmd = strdup(cmd);
	if(v->name == nil || v->cmd == nil){
		free(v->name);
		free(v->cmd);
		free(v);
		return TkNomem;
	}
	/* append, preserving bind order */
	for(l = &t->virts; *l != nil; l = &(*l)->link)
		;
	v->link = nil;
	*l = v;
	return nil;
}

/* fire every virtual binding registered for {tk, name} */
void
tkvirtgen(TkTop *t, Tk *tk, char *name)
{
	TkVirt *v;
	char *e;

	for(v = t->virts; v != nil; v = v->link){
		if(v->tk != tk || strcmp(v->name, name) != 0)
			continue;
		t->execdepth = 0;
		e = tkexec(t, v->cmd, nil);
		t->execdepth = -1;
		if(e != nil && tk->name != nil)
			print("tk: event %s <<%s>>: %s\n", tk->name->name, name, e);
	}
}

/* drop all virtual bindings owned by a widget being destroyed */
void
tkfreevirt(Tk *tk)
{
	TkTop *t;
	TkVirt *v, **l;

	if(tk->env == nil)
		return;
	t = tk->env->top;
	l = &t->virts;
	while((v = *l) != nil){
		if(v->tk == tk){
			*l = v->link;
			free(v->name);
			free(v->cmd);
			free(v);
			continue;
		}
		l = &v->link;
	}
}

static char*
tkeventgen(TkTop *t, char *arg, char **ret)
{
	Tk *tk;
	TkMouse m;
	Point p;
	char *e, *wp, *opt, *val, *name;
	int event, button, hasx, hasy;

	USED(ret);

	wp = mallocz(Tkmaxitem, 0);
	opt = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(wp == nil || opt == nil || val == nil){
		free(wp); free(opt); free(val);
		return TkNomem;
	}

	arg = tkword(t, arg, wp, wp+Tkmaxitem, nil);
	tk = tklook(t, wp, 0);
	if(tk == nil){
		tkerr(t, wp);
		e = TkBadwp;
		goto done;
	}

	arg = tkword(t, arg, opt, opt+Tkmaxitem, nil);
	if(opt[0] != '<'){
		e = TkBadsq;
		goto done;
	}

	/* virtual event: <<Name>> */
	if(opt[1] == '<'){
		name = opt+2;
		e = name;
		while(*e != '\0' && *e != '>')
			e++;
		*e = '\0';
		tkvirtgen(t, tk, name);
		e = nil;
		goto done;
	}

	/* concrete event: <Event> */
	event = tkseqparse(opt+1);
	if(event == -1){
		e = TkBadsq;
		goto done;
	}

	/* defaults: position the synthetic pointer at the widget origin */
	p = tkposn(tk);
	m.x = p.x + tk->borderwidth;
	m.y = p.y + tk->borderwidth;
	m.b = 0;
	button = 0;
	hasx = hasy = 0;

	for(;;){
		arg = tkword(t, arg, opt, opt+Tkmaxitem, nil);
		if(opt[0] == '\0')
			break;
		arg = tkword(t, arg, val, val+Tkmaxitem, nil);
		if(strcmp(opt, "-x") == 0){
			m.x = p.x + tk->borderwidth + atoi(val);
			hasx = 1;
		}else if(strcmp(opt, "-y") == 0){
			m.y = p.y + tk->borderwidth + atoi(val);
			hasy = 1;
		}else if(strcmp(opt, "-rootx") == 0){
			m.x = atoi(val);
			hasx = 1;
		}else if(strcmp(opt, "-rooty") == 0){
			m.y = atoi(val);
			hasy = 1;
		}else if(strcmp(opt, "-button") == 0){
			button = atoi(val);
		}
	}
	USED(hasx);
	USED(hasy);

	if(button != 0)
		m.b = 1 << (button-1);
	else if(event & (TkButton1P|TkButton1R))
		m.b = 1;
	else if(event & (TkButton2P|TkButton2R))
		m.b = 2;
	else if(event & (TkButton3P|TkButton3R))
		m.b = 4;

	tkdeliver(tk, event, &m);
	tkdirty(tk);
	e = nil;

done:
	free(wp);
	free(opt);
	free(val);
	return e;
}

char*
tkevent(TkTop *t, char *arg, char **ret)
{
	char *sub, *e;

	sub = mallocz(Tkmaxitem, 0);
	if(sub == nil)
		return TkNomem;

	arg = tkword(t, arg, sub, sub+Tkmaxitem, nil);
	if(strcmp(sub, "generate") == 0)
		e = tkeventgen(t, arg, ret);
	else
		e = TkBadcm;

	free(sub);
	return e;
}
