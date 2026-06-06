# Objloader - a minimal Wavefront .obj mesh loader for the raylib-in-Limbo
# port.  Reads v/f records (f may be polygons and may carry v/vt/vn slash
# forms; only the vertex index is used), triangulates faces by fan, and
# computes smooth per-vertex normals.  Call Objloader.init() once.

Objloader: module
{
	PATH:	con "/dis/lib/objloader.dis";

	Mesh: adt {
		verts:		array of Raymath->Vector3;
		normals:	array of Raymath->Vector3;	# smooth, per-vertex
		tris:		array of int;			# 3 indices per triangle
		min, max:	Raymath->Vector3;		# bounding box
	};

	init:	fn();
	readobj:	fn(path: string): (ref Mesh, string);
};
