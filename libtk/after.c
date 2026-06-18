#include "lib9.h"
#include "draw.h"
#include "tk.h"

/*
 * The `after' command: deferred and idle Tk-command execution.
 *
 *	after ms ?script?	schedule script to run after ms milliseconds
 *	after idle script	schedule script to run when nothing else is due
 *	after cancel id|script	cancel a pending script
 *	after info ?id?		list pending ids, or report one
 *
 * A scheduled script is a single (brace-grouped) Tk command string, exactly
 * as a `bind' action is, and is run with tkexec on the timer proc.  This is
 * the substrate for tooltips, animation and the ttk binding tables.
 *
 * The implementation is a small registry over the shared rptproc timer (see
 * tkrepeat/tkblink in utils.c).  As with those, all registry mutation happens
 * under the interpreter (acquire) lock that both the `after' command and the
 * fire callback hold, so no extra locking is needed; the proc's active/ck
 * callbacks only read scalars.
 */

extern void	rptwakeup(void*, void*);
extern void*	rptproc(char*, int, void*, int (*)(void*), int (*)(void*,int), void (*)(void*));

typedef struct Tkafter Tkafter;
struct Tkafter
{
	int		id;
	TkTop*		top;
	char*		cmd;
	long		ms;		/* remaining ms until fire (ignored when idle) */
	int		idle;
	Tkafter*	next;
};

static Tkafter*	afterq;		/* pending timers, newest first */
static int	afterid;	/* last id handed out */
static long	afternext;	/* cached min remaining ms; read lock-free by afterck */
static long	afterelapsed;	/* ms since last fire, handed from afterck to afterfire */
static void*	afterrpt;	/* the timer proc, created lazily */

static void
afterrecalc(void)
{
	Tkafter *a;
	long m;
	int have;

	m = 0;
	have = 0;
	for(a = afterq; a != nil; a = a->next){
		if(a->idle){
			afternext = 0;		/* an idle script fires next tick */
			return;
		}
		if(!have || a->ms < m){
			m = a->ms;
			have = 1;
		}
	}
	afternext = (have && m > 0) ? m : 0;
}

static int
afteractive(void *o)
{
	USED(o);
	return afterq != nil;
}

static int
afterck(void *o, int interval)
{
	USED(o);
	if(afterq == nil)
		return -1;
	if(interval >= afternext){
		afterelapsed = interval;
		return 1;
	}
	return 0;
}

static void
afterfire(void *o)
{
	Tkafter *q, *a, *next;
	TkTop *t;
	long el;
	char *e;

	USED(o);
	el = afterelapsed;

	/*
	 * Detach the current queue so a script that itself calls `after'
	 * (re-arming, common for animation) lands on a fresh queue and is
	 * not touched by this pass.  Survivors are spliced back afterwards.
	 */
	q = afterq;
	afterq = nil;
	for(a = q; a != nil; a = next){
		next = a->next;
		if(!a->idle && a->ms > el){
			a->ms -= el;
			a->next = afterq;
			afterq = a;
			continue;
		}
		t = a->top;
		if(a->cmd != nil && a->cmd[0] != '\0'){
			t->execdepth = 0;
			e = tkexec(t, a->cmd, nil);
			t->execdepth = -1;
			if(e != nil)
				print("tk: after command \"%s\": %s\n", a->cmd, e);
			tkupdate(t);
		}
		free(a->cmd);
		free(a);
	}
	afterrecalc();
}

static void
afterstart(void)
{
	if(afterrpt == nil)
		afterrpt = rptproc("after", TkAftertick, nil, afteractive, afterck, afterfire);
	else
		rptwakeup(nil, afterrpt);
}

static Tkafter*
afternew(TkTop *t, long ms, int idle, char *cmd)
{
	Tkafter *a;

	a = malloc(sizeof(Tkafter));
	if(a == nil)
		return nil;
	a->cmd = strdup(cmd);
	if(a->cmd == nil){
		free(a);
		return nil;
	}
	a->top = t;
	a->ms = ms;
	a->idle = idle;
	a->id = ++afterid;
	a->next = afterq;
	afterq = a;
	afterrecalc();
	afterstart();
	return a;
}

static char*
aftercancel(TkTop *t, char *what)
{
	Tkafter **l, *a;
	int id;

	id = -1;
	if(strncmp(what, "after#", 6) == 0)
		id = atoi(what+6);

	for(l = &afterq; (a = *l) != nil; ){
		int match;
		if(id >= 0)
			match = a->id == id;
		else
			match = a->top == t && strcmp(a->cmd, what) == 0;
		if(match){
			*l = a->next;
			free(a->cmd);
			free(a);
			if(id >= 0)
				break;		/* ids are unique */
		} else
			l = &a->next;
	}
	afterrecalc();
	return nil;
}

static char*
afterinfo(TkTop *t, char *arg, char **ret)
{
	char *buf, *e;
	Tkafter *a;
	int n, id;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(t, arg, buf, buf+Tkmaxitem, nil);

	if(buf[0] == '\0'){
		n = 0;
		e = nil;
		for(a = afterq; a != nil && e == nil; a = a->next)
			e = tkvalue(ret, "%safter#%d", n++ == 0 ? "" : " ", a->id);
		free(buf);
		return e;
	}

	id = -1;
	if(strncmp(buf, "after#", 6) == 0)
		id = atoi(buf+6);
	for(a = afterq; a != nil; a = a->next)
		if(a->id == id){
			e = tkvalue(ret, "{%s} %s", a->cmd, a->idle ? "idle" : "timer");
			free(buf);
			return e;
		}
	free(buf);
	return TkBadvl;
}

char*
tkafter(TkTop *t, char *arg, char **ret)
{
	char *buf, *script, *ep, *e;
	long ms;
	int idle;
	Tkafter *a;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	arg = tkword(t, arg, buf, buf+Tkmaxitem, nil);

	if(strcmp(buf, "cancel") == 0){
		tkword(t, arg, buf, buf+Tkmaxitem, nil);
		e = aftercancel(t, buf);
		free(buf);
		return e;
	}
	if(strcmp(buf, "info") == 0){
		e = afterinfo(t, arg, ret);
		free(buf);
		return e;
	}

	if(strcmp(buf, "idle") == 0){
		idle = 1;
		ms = 0;
	} else {
		idle = 0;
		ms = strtol(buf, &ep, 10);
		if(ep == buf || *ep != '\0' || ms < 0){
			free(buf);
			return TkBadvl;
		}
	}

	script = mallocz(Tkmaxitem, 0);
	if(script == nil){
		free(buf);
		return TkNomem;
	}
	tkword(t, arg, script, script+Tkmaxitem, nil);
	if(script[0] == '\0'){		/* `after ms' with no script: nothing to do */
		free(script);
		free(buf);
		return nil;
	}

	a = afternew(t, ms, idle, script);
	e = a == nil ? TkNomem : tkvalue(ret, "after#%d", a->id);
	free(script);
	free(buf);
	return e;
}

/*
 * Drop every timer that belongs to a toplevel being destroyed, so a pending
 * script never fires into a freed TkTop.  Called from tkfreetop.
 */
void
tkafterfreetop(TkTop *t)
{
	Tkafter **l, *a;

	for(l = &afterq; (a = *l) != nil; ){
		if(a->top == t){
			*l = a->next;
			free(a->cmd);
			free(a);
		} else
			l = &a->next;
	}
	afterrecalc();
}
