implement RayCube;

#
# raycube - a spinning 3D cube, rendered with the Raymath Limbo port over
# Inferno's native Draw.  A cube is convex, so the painter's algorithm
# (draw faces back-to-front by view-space depth) gives correct occlusion
# with no z-buffer; faces are filled with native fillpoly.
#
# Standalone: connects directly to /dev/draw (no window manager needed), so
# it can be screenshotted headlessly under Xvfb.
#
#	emu -g640x480 /dis/wm/raycube.dis [nframes]
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "raymath.m";
	rm: Raymath;
	Vector3, Matrix: import rm;

RayCube: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# 8 cube corners
verts := array[] of {
	Vector3(-1.0, -1.0, -1.0),
	Vector3( 1.0, -1.0, -1.0),
	Vector3( 1.0,  1.0, -1.0),
	Vector3(-1.0,  1.0, -1.0),
	Vector3(-1.0, -1.0,  1.0),
	Vector3( 1.0, -1.0,  1.0),
	Vector3( 1.0,  1.0,  1.0),
	Vector3(-1.0,  1.0,  1.0),
};

# 6 faces, each 4 corner indices wound CCW seen from outside
Face: adt {
	a, b, c, d: int;
	col: int;		# Draw colour constant
};

faces := array[] of {
	Face(0, 3, 2, 1, draw->Red),		# back  (-z)
	Face(4, 5, 6, 7, draw->Green),		# front (+z)
	Face(0, 4, 7, 3, draw->Blue),		# left  (-x)
	Face(1, 2, 6, 5, draw->Yellow),		# right (+x)
	Face(0, 1, 5, 4, draw->Cyan),		# bottom(-y)
	Face(3, 7, 6, 2, draw->Magenta),	# top   (+y)
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	rm = load Raymath Raymath->PATH;
	rm->init();

	nframes := 0;				# 0 == run forever
	if(tl argv != nil)
		nframes = int hd tl argv;

	disp := Display.allocate(nil);
	if(disp == nil){
		sys->fprint(sys->fildes(2), "raycube: cannot open display\n");
		return;
	}
	screen := disp.image;
	r := screen.r;
	w := r.dx();
	h := r.dy();

	# offscreen double buffer + a black clear colour
	buf := disp.newimage(r, screen.chans, 0, draw->Black);
	black := disp.color(draw->Black);
	white := disp.color(draw->White);

	# precompute colour images per face
	cols := array[len faces] of ref Image;
	for(i := 0; i < len faces; i++)
		cols[i] = disp.color(faces[i].col);

	# camera: eye back along +z, looking at the origin
	eye := Vector3(0.0, 0.0, 5.0);
	target := Vector3(0.0, 0.0, 0.0);
	up := Vector3(0.0, 1.0, 0.0);
	view := Matrix.lookat(eye, target, up);
	aspect := real w / real h;
	proj := Matrix.perspective(45.0*rm->DEG2RAD, aspect, 0.1, 100.0);

	scr := array[len verts] of Point;	# projected screen points
	vz := array[len verts] of real;		# view-space depth per vertex

	ang := 0.0;
	frame := 0;
	for(;;){
		# spin about a tilted axis
		model := Matrix.rotatexyz(Vector3(ang*0.6, ang, ang*0.3));
		mv := model.mul(view);		# view-space transform
		mvp := mv.mul(proj);		# full clip transform

		for(i = 0; i < len verts; i++){
			vp := verts[i].transform(mv);
			vz[i] = vp.z;
			(c, cw) := verts[i].transformp(mvp);
			if(cw == 0.0)
				cw = 0.0001;
			ndcx := c.x/cw;
			ndcy := c.y/cw;
			sx := int ((ndcx*0.5 + 0.5) * real w);
			sy := int ((1.0 - (ndcy*0.5 + 0.5)) * real h);
			scr[i] = (r.min.x + sx, r.min.y + sy);
		}

		# painter's algorithm: order faces far -> near.
		# camera looks down -z, so "farther" == more negative view z.
		order := array[len faces] of int;
		for(i = 0; i < len faces; i++)
			order[i] = i;
		for(i = 0; i < len faces; i++){
			for(j := i+1; j < len faces; j++){
				if(facedepth(faces[order[j]], vz) < facedepth(faces[order[i]], vz))
					(order[i], order[j]) = (order[j], order[i]);
			}
		}

		# clear and draw
		buf.draw(buf.r, black, nil, buf.r.min);
		for(k := 0; k < len faces; k++){
			fi := order[k];
			f := faces[fi];
			poly := array[] of { scr[f.a], scr[f.b], scr[f.c], scr[f.d] };
			buf.fillpoly(poly, 0, cols[fi], (0,0));
			# edge outline for definition
			buf.poly(poly, 0, 0, 0, white, (0,0));
			buf.line(poly[3], poly[0], 0, 0, 0, white, (0,0));
		}

		screen.draw(screen.r, buf, nil, buf.r.min);
		screen.flush(draw->Flushnow);

		ang += 0.03;
		frame++;
		if(nframes != 0 && frame >= nframes)
			break;
		sys->sleep(16);
	}
}

facedepth(f: Face, vz: array of real): real
{
	return (vz[f.a] + vz[f.b] + vz[f.c] + vz[f.d]) / 4.0;
}
