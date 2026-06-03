/* libdraw geometry: Point/Rectangle arithmetic and predicates (arith.c, rectclip.c). */
#include "lib9.h"
#include "draw.h"
#include "cunit.h"

static void
test_points(void)
{
	Point a = Pt(3, 4), b = Pt(1, 2), r;
	r = addpt(a, b); CKEQ(r.x, 4); CKEQ(r.y, 6);
	r = subpt(a, b); CKEQ(r.x, 2); CKEQ(r.y, 2);
	r = mulpt(a, 3);  CKEQ(r.x, 9); CKEQ(r.y, 12);
	r = divpt(a, 2);  CKEQ(r.x, 1); CKEQ(r.y, 2);
	CK(eqpt(a, Pt(3,4)));
	CK(!eqpt(a, b));
}

static void
test_rects(void)
{
	Rectangle r = Rect(0, 0, 10, 20);
	CKEQ(Dx(r), 10);
	CKEQ(Dy(r), 20);
	CK(ptinrect(Pt(5, 5), r));
	CK(!ptinrect(Pt(10, 5), r));      /* max is exclusive */
	CK(eqrect(insetrect(r, 2), Rect(2, 2, 8, 18)));
	CK(eqrect(rectaddpt(r, Pt(1, 1)), Rect(1, 1, 11, 21)));
	CK(eqrect(canonrect(Rect(10, 20, 0, 0)), r));   /* swaps min/max */
}

static void
test_relations(void)
{
	Rectangle big = Rect(0, 0, 100, 100);
	Rectangle in  = Rect(10, 10, 20, 20);
	Rectangle overlap = Rect(90, 90, 110, 110);
	Rectangle outside = Rect(200, 200, 210, 210);

	CK(rectinrect(in, big));
	CK(!rectinrect(overlap, big));
	CK(rectXrect(overlap, big));      /* intersect */
	CK(!rectXrect(outside, big));
}

static void
test_combine_clip(void)
{
	Rectangle r = Rect(0, 0, 10, 10);
	combinerect(&r, Rect(5, 5, 20, 20));    /* bounding box of union */
	CK(eqrect(r, Rect(0, 0, 20, 20)));

	r = Rect(0, 0, 10, 10);
	CK(rectclip(&r, Rect(5, 5, 100, 100))); /* clip to intersection */
	CK(eqrect(r, Rect(5, 5, 10, 10)));

	r = Rect(0, 0, 10, 10);
	CK(!rectclip(&r, Rect(50, 50, 60, 60)));/* disjoint -> 0, r unchanged-ish */
}

CUNIT_MAIN("libdraw/geom", test_points, test_rects, test_relations, test_combine_clip)
