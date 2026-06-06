implement Objloader;

#
# Objloader: minimal Wavefront .obj reader.  See module/objloader.m.
#

include "sys.m";
	sys: Sys;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "raymath.m";
	rm: Raymath;
	Vector3: import rm;
include "objloader.m";

init()
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	rm = load Raymath Raymath->PATH;
	rm->init();
}

# index of the vertex named by an .obj face token ("v", "v/vt", "v//vn",
# "v/vt/vn"), resolved to 0-based against nv vertices seen so far.
faceindex(tok: string, nv: int): int
{
	(vs, nil) := str->splitl(tok, "/");
	v := int vs;
	if(v > 0)
		return v - 1;
	if(v < 0)
		return nv + v;	# negative = relative to end
	return -1;
}

readobj(path: string): (ref Mesh, string)
{
	iob := bufio->open(path, Bufio->OREAD);
	if(iob == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));

	vl: list of Vector3;	# vertices, reversed
	nv := 0;
	tlist: list of int;	# triangle indices, flattened (order irrelevant)
	nt := 0;

	for(;;){
		line := iob.gets('\n');
		if(line == "")
			break;
		(n, toks) := sys->tokenize(line, " \t\r\n");
		if(n == 0)
			continue;
		key := hd toks;
		case key {
		"v" =>
			if(n >= 4){
				t := tl1(toks);	# toks after key
				x := real hd t;
				y := real hd tl t;
				z := real hd tl tl t;
				vl = Vector3(x, y, z) :: vl;
				nv++;
			}
		"f" =>
			# gather this face's vertex indices, then fan-triangulate
			idx := array[n-1] of int;
			ni := 0;
			for(t := tl toks; t != nil; t = tl t)
				idx[ni++] = faceindex(hd t, nv);
			for(k := 2; k < ni; k++){
				tlist = idx[0] :: idx[k-1] :: idx[k] :: tlist;
				nt += 3;
			}
		* =>
			;	# ignore vt, vn, g, s, mtllib, usemtl, comments...
		}
	}

	if(nv == 0)
		return (nil, "no vertices in "+path);

	# vertices: reverse the list into an array (restore file order)
	verts := array[nv] of Vector3;
	i := nv - 1;
	for(p := vl; p != nil; p = tl p)
		verts[i--] = hd p;

	# triangles
	tris := array[nt] of int;
	i = nt - 1;
	for(q := tlist; q != nil; q = tl q)
		tris[i--] = hd q;

	# bounding box
	mn := verts[0];
	mx := verts[0];
	for(i = 1; i < nv; i++){
		mn = mn.min(verts[i]);
		mx = mx.max(verts[i]);
	}

	# smooth per-vertex normals: sum adjacent face normals, normalize
	normals := array[nv] of Vector3;
	for(i = 0; i < nv; i++)
		normals[i] = Vector3(0.0, 0.0, 0.0);
	for(i = 0; i < nt; i += 3){
		ia := tris[i];
		ib := tris[i+1];
		ic := tris[i+2];
		if(bad(ia, nv) || bad(ib, nv) || bad(ic, nv))
			continue;
		fnorm := (verts[ib].sub(verts[ia])).cross(verts[ic].sub(verts[ia]));
		normals[ia] = normals[ia].add(fnorm);
		normals[ib] = normals[ib].add(fnorm);
		normals[ic] = normals[ic].add(fnorm);
	}
	for(i = 0; i < nv; i++)
		normals[i] = normals[i].normalize();

	m := ref Mesh(verts, normals, tris, mn, mx);
	return (m, nil);
}

bad(i, n: int): int
{
	return i < 0 || i >= n;
}

# drop the first element (the record key) from a token list
tl1(toks: list of string): list of string
{
	return tl toks;
}
