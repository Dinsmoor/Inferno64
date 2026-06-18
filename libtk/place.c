#include "lib9.h"
#include "draw.h"
#include "tk.h"

/*
 * The `place' geometry manager: position a slave at absolute or
 * master-relative coordinates, independent of pack/grid.
 *
 *	place pathName ?-opt value ...?
 *	place configure pathName ?-opt value ...?
 *	place forget pathName
 *	place info pathName
 *	place slaves pathName
 *
 * Options: -x -y -width -height -relx -rely -relwidth -relheight
 *          -anchor -in -bordermode.
 *
 * Placed slaves live on the ordinary master->slave list (so they draw and
 * receive events like any child) but carry a non-nil tk->place and are
 * therefore skipped by the pack/grid sizing passes.  Because nothing is ever
 * placed unless `place' is used, the `if(slave->place)' guards added to the
 * packer are inert for every widget laid out the classic way.
 */

/*
 * A small decimal parser for the -rel* fractions.  We avoid lib9's charstod
 * because it references NaN/Inf, which emu does not link.
 */
static double
placefrac(char *s)
{
	double v, scale;
	int neg, frac;

	v = 0.0;
	scale = 1.0;
	neg = 0;
	frac = 0;
	if(*s == '-'){
		neg = 1;
		s++;
	} else if(*s == '+')
		s++;
	for(; *s != '\0'; s++){
		if(*s == '.'){
			frac = 1;
			continue;
		}
		if(*s < '0' || *s > '9')
			break;
		if(frac){
			scale *= 0.1;
			v += (*s - '0') * scale;
		} else
			v = v*10.0 + (*s - '0');
	}
	return neg ? -v : v;
}

static int
placeanchor(char *s, int *ap)
{
	int a;

	a = 0;
	if(strcmp(s, "center") == 0){
		*ap = 0;
		return 1;
	}
	for(; *s; s++){
		switch(*s){
		case 'n':	a |= Tknorth; break;
		case 's':	a |= Tksouth; break;
		case 'e':	a |= Tkeast; break;
		case 'w':	a |= Tkwest; break;
		default:	return 0;
		}
	}
	*ap = a;
	return 1;
}

static int
placeround(double v)
{
	if(v < 0)
		return -(int)(-v + 0.5);
	return (int)(v + 0.5);
}

/*
 * Position every placed slave of master within its current actual area.
 * Returns 1 (always complete in a single pass).
 */
int
tkplacer(Tk *master)
{
	Tk *slave;
	TkPlace *p;
	TkGeom pos, old;
	int aw, ah, ox, oy, bw, w, h, px, py, left, top;
	void (*geomfn)(Tk*);

	for(slave = master->slave; slave != nil; slave = slave->next){
		p = slave->place;
		if(p == nil)
			continue;

		bw = 0;
		if(p->bordermode == TkPlinside)
			bw = master->borderwidth + master->highlightwidth;
		ox = bw;
		oy = bw;
		aw = master->act.width - 2*bw;
		ah = master->act.height - 2*bw;
		if(p->bordermode == TkPlignore){
			aw = master->act.width;
			ah = master->act.height;
		}

		if(p->set & (TkPlacewidth|TkPlacerelwidth)){
			w = (p->set & TkPlacewidth) ? p->width : 0;
			if(p->set & TkPlacerelwidth)
				w += placeround(p->relwidth * aw);
		} else
			w = slave->req.width + slave->borderwidth*2 + slave->ipad.x;

		if(p->set & (TkPlaceheight|TkPlacerelheight)){
			h = (p->set & TkPlaceheight) ? p->height : 0;
			if(p->set & TkPlacerelheight)
				h += placeround(p->relheight * ah);
		} else
			h = slave->req.height + slave->borderwidth*2 + slave->ipad.y;

		if(w < 0)
			w = 0;
		if(h < 0)
			h = 0;

		px = (p->set & TkPlacex) ? p->x : 0;
		if(p->set & TkPlacerelx)
			px += placeround(p->relx * aw);
		py = (p->set & TkPlacey) ? p->y : 0;
		if(p->set & TkPlacerely)
			py += placeround(p->rely * ah);
		px += ox;
		py += oy;

		if(p->anchor & Tkwest)
			left = px;
		else if(p->anchor & Tkeast)
			left = px - w;
		else
			left = px - w/2;
		if(p->anchor & Tknorth)
			top = py;
		else if(p->anchor & Tksouth)
			top = py - h;
		else
			top = py - h/2;

		pos.x = left;
		pos.y = top;
		pos.width = w - slave->borderwidth*2;
		pos.height = h - slave->borderwidth*2;
		if(pos.width < 0)
			pos.width = 0;
		if(pos.height < 0)
			pos.height = 0;

		if(memcmp(&slave->act, &pos, sizeof(TkGeom)) != 0){
			old = slave->act;
			slave->act = pos;
			geomfn = tkmethod[slave->type]->geom;
			if(geomfn != nil)
				geomfn(slave);
			if(slave->slave)
				tkpackqit(slave);
			tkdeliver(slave, TkConfigure, &old);
			slave->dirty = tkrect(slave, 1);
			slave->flag |= Tkrefresh;
		}
	}
	master->flag |= Tkrefresh;
	return 1;
}

/* does master have any pack/grid-managed (non-placed) slaves? */
int
tkhasmanagedslave(Tk *master)
{
	Tk *s;

	for(s = master->slave; s != nil; s = s->next)
		if(s->place == nil)
			return 1;
	return 0;
}

void
tkdelplace(Tk *tk)
{
	Tk *f, **l, *m;

	if(tk->place == nil)
		return;
	free(tk->place);
	tk->place = nil;

	m = tk->master;
	if(m != nil){
		l = &m->slave;
		for(f = *l; f != nil; f = f->next){
			if(f == tk){
				*l = tk->next;
				break;
			}
			l = &f->next;
		}
		tk->master = nil;
		tkpackqit(m);
	}
}

static char*
placeset(TkTop *t, Tk *tk, char *arg)
{
	TkPlace *p;
	char *buf, *val;
	int anchor;

	p = tk->place;
	buf = mallocz(Tkmaxitem, 0);
	val = mallocz(Tkmaxitem, 0);
	if(buf == nil || val == nil){
		free(buf);
		free(val);
		return TkNomem;
	}

	for(;;){
		arg = tkword(t, arg, buf, buf+Tkmaxitem, nil);
		if(buf[0] == '\0')
			break;
		arg = tkword(t, arg, val, val+Tkmaxitem, nil);

		if(strcmp(buf, "-x") == 0){
			p->x = atoi(val); p->set |= TkPlacex;
		} else if(strcmp(buf, "-y") == 0){
			p->y = atoi(val); p->set |= TkPlacey;
		} else if(strcmp(buf, "-width") == 0){
			if(val[0] == '\0') p->set &= ~TkPlacewidth;
			else { p->width = atoi(val); p->set |= TkPlacewidth; }
		} else if(strcmp(buf, "-height") == 0){
			if(val[0] == '\0') p->set &= ~TkPlaceheight;
			else { p->height = atoi(val); p->set |= TkPlaceheight; }
		} else if(strcmp(buf, "-relx") == 0){
			p->relx = placefrac(val); p->set |= TkPlacerelx;
		} else if(strcmp(buf, "-rely") == 0){
			p->rely = placefrac(val); p->set |= TkPlacerely;
		} else if(strcmp(buf, "-relwidth") == 0){
			if(val[0] == '\0') p->set &= ~TkPlacerelwidth;
			else { p->relwidth = placefrac(val); p->set |= TkPlacerelwidth; }
		} else if(strcmp(buf, "-relheight") == 0){
			if(val[0] == '\0') p->set &= ~TkPlacerelheight;
			else { p->relheight = placefrac(val); p->set |= TkPlacerelheight; }
		} else if(strcmp(buf, "-anchor") == 0){
			if(!placeanchor(val, &anchor)){ free(buf); free(val); return TkBadvl; }
			p->anchor = anchor;
		} else if(strcmp(buf, "-bordermode") == 0){
			if(strcmp(val, "inside") == 0) p->bordermode = TkPlinside;
			else if(strcmp(val, "outside") == 0) p->bordermode = TkPloutside;
			else if(strcmp(val, "ignore") == 0) p->bordermode = TkPlignore;
			else { free(buf); free(val); return TkBadvl; }
		} else if(strcmp(buf, "-in") == 0){
			/* the master was resolved by the caller; value already consumed */
		} else {
			free(buf); free(val);
			return TkBadop;
		}
	}
	free(buf);
	free(val);
	return nil;
}

static char*
placeconfigure(TkTop *t, char *arg)
{
	Tk *tk, *in;
	TkPlace *p;
	char *buf, *e, *scan, *val;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	arg = tkword(t, arg, buf, buf+Tkmaxitem, nil);
	tk = tklook(t, buf, 0);
	if(tk == nil){
		tkerr(t, buf);
		free(buf);
		return TkBadwp;
	}
	if(tk->flag & Tkwindow){
		free(buf);
		return TkIstop;
	}

	/* find -in if present, else the widget's logical parent */
	in = nil;
	scan = arg;
	val = mallocz(Tkmaxitem, 0);
	if(val == nil){ free(buf); return TkNomem; }
	for(;;){
		scan = tkword(t, scan, buf, buf+Tkmaxitem, nil);
		if(buf[0] == '\0')
			break;
		scan = tkword(t, scan, val, val+Tkmaxitem, nil);
		if(strcmp(buf, "-in") == 0){
			in = tklook(t, val, 0);
			if(in == nil){ tkerr(t, val); free(buf); free(val); return TkBadwp; }
			break;
		}
	}
	free(val);

	if(in == nil){
		/* keep current master if already placed, else the logical parent */
		if(tk->place != nil && tk->master != nil)
			in = tk->master;
		else {
			char *nm = tk->name != nil ? tk->name->name : nil;
			in = tklook(t, nm, 1);
		}
	}
	free(buf);
	if(in == nil)
		return TkBadwp;
	if(tkisslave(in, tk))
		return TkRecur;

	/* (re)home the widget under `in' as a placed slave */
	if(tk->place == nil){
		if(tk->master != nil){
			if(tk->master->grid != nil)
				tkgriddelslave(tk);
			tkdelpack(tk);
		}
		p = mallocz(sizeof(TkPlace), 1);
		if(p == nil)
			return TkNomem;
		p->anchor = Tknorth|Tkwest;	/* Tk default anchor is nw */
		p->bordermode = TkPlinside;
		tk->place = p;
		tkappendpack(in, tk, -1);
	} else if(tk->master != in){
		tkdelplace(tk);
		p = mallocz(sizeof(TkPlace), 1);
		if(p == nil)
			return TkNomem;
		p->anchor = Tknorth|Tkwest;
		p->bordermode = TkPlinside;
		tk->place = p;
		tkappendpack(in, tk, -1);
	}

	e = placeset(t, tk, arg);
	tkpackqit(in);
	tkrunpack(t);
	return e;
}

static char*
placeforget(TkTop *t, char *arg)
{
	Tk *tk;
	char *buf;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(t, arg, buf, buf+Tkmaxitem, nil);
	tk = tklook(t, buf, 0);
	free(buf);
	if(tk == nil)
		return nil;
	if(tk->place != nil)
		tkdelplace(tk);
	tkrunpack(t);
	return nil;
}

static char*
placeinfo(TkTop *t, char *arg, char **ret)
{
	Tk *tk;
	TkPlace *p;
	char *buf;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(t, arg, buf, buf+Tkmaxitem, nil);
	tk = tklook(t, buf, 0);
	free(buf);
	if(tk == nil || tk->place == nil)
		return nil;
	p = tk->place;
	if(tk->master != nil && tk->master->name != nil)
		tkvalue(ret, "-in %s ", tk->master->name->name);
	if(p->set & TkPlacex) tkvalue(ret, "-x %d ", p->x);
	if(p->set & TkPlacey) tkvalue(ret, "-y %d ", p->y);
	if(p->set & TkPlacewidth) tkvalue(ret, "-width %d ", p->width);
	if(p->set & TkPlaceheight) tkvalue(ret, "-height %d ", p->height);
	if(p->set & TkPlacerelx) tkvalue(ret, "-relx %g ", p->relx);
	if(p->set & TkPlacerely) tkvalue(ret, "-rely %g ", p->rely);
	if(p->set & TkPlacerelwidth) tkvalue(ret, "-relwidth %g ", p->relwidth);
	if(p->set & TkPlacerelheight) tkvalue(ret, "-relheight %g ", p->relheight);
	return nil;
}

static char*
placeslaves(TkTop *t, char *arg, char **ret)
{
	Tk *tk, *s;
	char *buf, *fmt;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	tkword(t, arg, buf, buf+Tkmaxitem, nil);
	tk = tklook(t, buf, 0);
	free(buf);
	if(tk == nil)
		return nil;
	fmt = "%s";
	for(s = tk->slave; s != nil; s = s->next)
		if(s->place != nil && s->name != nil){
			tkvalue(ret, fmt, s->name->name);
			fmt = " %s";
		}
	return nil;
}

char*
tkplace(TkTop *t, char *arg, char **ret)
{
	char *buf, *w, *e;

	buf = mallocz(Tkmaxitem, 0);
	if(buf == nil)
		return TkNomem;
	w = tkword(t, arg, buf, buf+Tkmaxitem, nil);

	if(strcmp(buf, "forget") == 0)
		e = placeforget(t, w);
	else if(strcmp(buf, "info") == 0)
		e = placeinfo(t, w, ret);
	else if(strcmp(buf, "slaves") == 0)
		e = placeslaves(t, w, ret);
	else if(strcmp(buf, "configure") == 0)
		e = placeconfigure(t, w);
	else
		e = placeconfigure(t, arg);	/* `place pathName -opt ...' shorthand */
	free(buf);
	return e;
}
