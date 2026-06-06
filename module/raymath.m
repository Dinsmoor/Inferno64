# Raymath -- a Limbo port of raylib's raymath.h (vectors, matrices,
# quaternions).  Pure Limbo, software, no native dependency beyond $Math.
# Layout matches raylib: Matrix.m[i] == raylib's "mi" (OpenGL column-major),
# so a Matrix can be handed straight to a C rasterizer kernel later.
#
# Call Raymath.init() once before use (loads $Math).

Raymath: module
{
	PATH:		con "/dis/lib/raymath.dis";

	PI:		con 3.14159265358979323846;
	DEG2RAD:	con 0.017453292519943295;	# PI/180
	RAD2DEG:	con 57.29577951308232;		# 180/PI
	EPSILON:	con 0.000001;

	init:	fn();

	# scalar helpers
	clamp:		fn(v, lo, hi: real): real;
	lerp:		fn(a, b, amt: real): real;
	remap:		fn(v, ins, ine, outs, oute: real): real;
	wrap:		fn(v, lo, hi: real): real;
	fequals:	fn(a, b: real): int;

	Vector2: adt {
		x, y:	real;

		add:		fn(a: self Vector2, b: Vector2): Vector2;
		sub:		fn(a: self Vector2, b: Vector2): Vector2;
		scale:		fn(a: self Vector2, s: real): Vector2;
		mul:		fn(a: self Vector2, b: Vector2): Vector2;
		dot:		fn(a: self Vector2, b: Vector2): real;
		length:		fn(a: self Vector2): real;
		normalize:	fn(a: self Vector2): Vector2;
		negate:		fn(a: self Vector2): Vector2;
		lerp:		fn(a: self Vector2, b: Vector2, amt: real): Vector2;
		rotate:		fn(a: self Vector2, angle: real): Vector2;
	};

	Vector3: adt {
		x, y, z:	real;

		add:		fn(a: self Vector3, b: Vector3): Vector3;
		addval:		fn(a: self Vector3, v: real): Vector3;
		sub:		fn(a: self Vector3, b: Vector3): Vector3;
		scale:		fn(a: self Vector3, s: real): Vector3;
		mul:		fn(a: self Vector3, b: Vector3): Vector3;
		dot:		fn(a: self Vector3, b: Vector3): real;
		cross:		fn(a: self Vector3, b: Vector3): Vector3;
		length:		fn(a: self Vector3): real;
		lengthsqr:	fn(a: self Vector3): real;
		distance:	fn(a: self Vector3, b: Vector3): real;
		normalize:	fn(a: self Vector3): Vector3;
		negate:		fn(a: self Vector3): Vector3;
		lerp:		fn(a: self Vector3, b: Vector3, amt: real): Vector3;
		reflect:	fn(a: self Vector3, n: Vector3): Vector3;
		min:		fn(a: self Vector3, b: Vector3): Vector3;
		max:		fn(a: self Vector3, b: Vector3): Vector3;
		# transform by a 4x4 matrix (w divide not applied; see transformp)
		transform:	fn(a: self Vector3, mat: Matrix): Vector3;
		# perspective transform: returns (screen Vector3, w) for the divide
		transformp:	fn(a: self Vector3, mat: Matrix): (Vector3, real);
		rotateaxis:	fn(a: self Vector3, axis: Vector3, angle: real): Vector3;
	};

	Vector4: adt {		# also used as Quaternion
		x, y, z, w:	real;

		add:		fn(a: self Vector4, b: Vector4): Vector4;
		scale:		fn(a: self Vector4, s: real): Vector4;
		length:		fn(a: self Vector4): real;
		normalize:	fn(a: self Vector4): Vector4;
		# quaternion ops
		qmul:		fn(a: self Vector4, b: Vector4): Vector4;
		qnlerp:		fn(a: self Vector4, b: Vector4, amt: real): Vector4;
		qslerp:		fn(a: self Vector4, b: Vector4, amt: real): Vector4;
		qmatrix:	fn(a: self Vector4): Matrix;
	};

	Matrix: adt {
		m:	array of real;		# 16 reals; m[i] == raylib mi

		identity:	fn(): Matrix;
		copy:		fn(a: self Matrix): Matrix;
		mul:		fn(l: self Matrix, r: Matrix): Matrix;
		add:		fn(l: self Matrix, r: Matrix): Matrix;
		sub:		fn(l: self Matrix, r: Matrix): Matrix;
		transpose:	fn(a: self Matrix): Matrix;
		determinant:	fn(a: self Matrix): real;
		invert:		fn(a: self Matrix): Matrix;
		trace:		fn(a: self Matrix): real;

		translate:	fn(x, y, z: real): Matrix;
		scaling:	fn(x, y, z: real): Matrix;
		rotate:		fn(axis: Vector3, angle: real): Matrix;
		rotatex:	fn(angle: real): Matrix;
		rotatey:	fn(angle: real): Matrix;
		rotatez:	fn(angle: real): Matrix;
		rotatexyz:	fn(ang: Vector3): Matrix;
		frustum:	fn(left, right, bottom, top, near, far: real): Matrix;
		perspective:	fn(fovy, aspect, near, far: real): Matrix;
		ortho:		fn(left, right, bottom, top, near, far: real): Matrix;
		lookat:		fn(eye, target, up: Vector3): Matrix;
	};

	# Quaternion constructors (Vector4-valued)
	qidentity:	fn(): Vector4;
	qfromaxisangle:	fn(axis: Vector3, angle: real): Vector4;
};
