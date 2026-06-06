implement Raymath;

#
# Raymath: a Limbo port of raylib's raymath.h.
# See module/raymath.m.  Layout matches raylib (Matrix.m[i] == raylib mi).
#

include "math.m";
	math: Math;
include "raymath.m";

init()
{
	if(math == nil)
		math = load Math Math->PATH;
}

# ---- scalar helpers ----

clamp(v, lo, hi: real): real
{
	if(v < lo)
		return lo;
	if(v > hi)
		return hi;
	return v;
}

lerp(a, b, amt: real): real
{
	return a + amt*(b - a);
}

remap(v, ins, ine, outs, oute: real): real
{
	return (v - ins)/(ine - ins)*(oute - outs) + outs;
}

wrap(v, lo, hi: real): real
{
	return v - (hi - lo)*math->floor((v - lo)/(hi - lo));
}

fequals(a, b: real): int
{
	ma := math->fabs(a);
	mb := math->fabs(b);
	m := 1.0;
	if(ma > m)
		m = ma;
	if(mb > m)
		m = mb;
	return (math->fabs(a - b) <= EPSILON*m);
}

# ---- Vector2 ----

Vector2.add(a: self Vector2, b: Vector2): Vector2 { return Vector2(a.x+b.x, a.y+b.y); }
Vector2.sub(a: self Vector2, b: Vector2): Vector2 { return Vector2(a.x-b.x, a.y-b.y); }
Vector2.scale(a: self Vector2, s: real): Vector2 { return Vector2(a.x*s, a.y*s); }
Vector2.mul(a: self Vector2, b: Vector2): Vector2 { return Vector2(a.x*b.x, a.y*b.y); }
Vector2.dot(a: self Vector2, b: Vector2): real { return a.x*b.x + a.y*b.y; }
Vector2.negate(a: self Vector2): Vector2 { return Vector2(-a.x, -a.y); }

Vector2.length(a: self Vector2): real
{
	return math->sqrt(a.x*a.x + a.y*a.y);
}

Vector2.normalize(a: self Vector2): Vector2
{
	l := math->sqrt(a.x*a.x + a.y*a.y);
	if(l == 0.0)
		return Vector2(0.0, 0.0);
	return Vector2(a.x/l, a.y/l);
}

Vector2.lerp(a: self Vector2, b: Vector2, amt: real): Vector2
{
	return Vector2(a.x + amt*(b.x-a.x), a.y + amt*(b.y-a.y));
}

Vector2.rotate(a: self Vector2, angle: real): Vector2
{
	c := math->cos(angle);
	s := math->sin(angle);
	return Vector2(a.x*c - a.y*s, a.x*s + a.y*c);
}

# ---- Vector3 ----

Vector3.add(a: self Vector3, b: Vector3): Vector3 { return Vector3(a.x+b.x, a.y+b.y, a.z+b.z); }
Vector3.addval(a: self Vector3, v: real): Vector3 { return Vector3(a.x+v, a.y+v, a.z+v); }
Vector3.sub(a: self Vector3, b: Vector3): Vector3 { return Vector3(a.x-b.x, a.y-b.y, a.z-b.z); }
Vector3.scale(a: self Vector3, s: real): Vector3 { return Vector3(a.x*s, a.y*s, a.z*s); }
Vector3.mul(a: self Vector3, b: Vector3): Vector3 { return Vector3(a.x*b.x, a.y*b.y, a.z*b.z); }
Vector3.dot(a: self Vector3, b: Vector3): real { return a.x*b.x + a.y*b.y + a.z*b.z; }
Vector3.negate(a: self Vector3): Vector3 { return Vector3(-a.x, -a.y, -a.z); }
Vector3.lengthsqr(a: self Vector3): real { return a.x*a.x + a.y*a.y + a.z*a.z; }

Vector3.cross(a: self Vector3, b: Vector3): Vector3
{
	return Vector3(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x);
}

Vector3.length(a: self Vector3): real
{
	return math->sqrt(a.x*a.x + a.y*a.y + a.z*a.z);
}

Vector3.distance(a: self Vector3, b: Vector3): real
{
	dx := b.x - a.x;
	dy := b.y - a.y;
	dz := b.z - a.z;
	return math->sqrt(dx*dx + dy*dy + dz*dz);
}

Vector3.normalize(a: self Vector3): Vector3
{
	l := math->sqrt(a.x*a.x + a.y*a.y + a.z*a.z);
	if(l == 0.0)
		return Vector3(0.0, 0.0, 0.0);
	return Vector3(a.x/l, a.y/l, a.z/l);
}

Vector3.lerp(a: self Vector3, b: Vector3, amt: real): Vector3
{
	return Vector3(a.x + amt*(b.x-a.x), a.y + amt*(b.y-a.y), a.z + amt*(b.z-a.z));
}

Vector3.reflect(a: self Vector3, n: Vector3): Vector3
{
	d := a.x*n.x + a.y*n.y + a.z*n.z;
	return Vector3(a.x - 2.0*d*n.x, a.y - 2.0*d*n.y, a.z - 2.0*d*n.z);
}

Vector3.min(a: self Vector3, b: Vector3): Vector3
{
	return Vector3(fmin(a.x,b.x), fmin(a.y,b.y), fmin(a.z,b.z));
}

Vector3.max(a: self Vector3, b: Vector3): Vector3
{
	return Vector3(fmax(a.x,b.x), fmax(a.y,b.y), fmax(a.z,b.z));
}

Vector3.transform(a: self Vector3, mat: Matrix): Vector3
{
	m := mat.m;
	return Vector3(
		m[0]*a.x + m[4]*a.y + m[8]*a.z + m[12],
		m[1]*a.x + m[5]*a.y + m[9]*a.z + m[13],
		m[2]*a.x + m[6]*a.y + m[10]*a.z + m[14]);
}

Vector3.transformp(a: self Vector3, mat: Matrix): (Vector3, real)
{
	m := mat.m;
	x := m[0]*a.x + m[4]*a.y + m[8]*a.z + m[12];
	y := m[1]*a.x + m[5]*a.y + m[9]*a.z + m[13];
	z := m[2]*a.x + m[6]*a.y + m[10]*a.z + m[14];
	w := m[3]*a.x + m[7]*a.y + m[11]*a.z + m[15];
	return (Vector3(x, y, z), w);
}

Vector3.rotateaxis(a: self Vector3, axis: Vector3, angle: real): Vector3
{
	# equivalent to transforming by the axis-angle rotation matrix
	return a.transform(Matrix.rotate(axis, angle));
}

# ---- Vector4 / Quaternion ----

Vector4.add(a: self Vector4, b: Vector4): Vector4 { return Vector4(a.x+b.x, a.y+b.y, a.z+b.z, a.w+b.w); }
Vector4.scale(a: self Vector4, s: real): Vector4 { return Vector4(a.x*s, a.y*s, a.z*s, a.w*s); }

Vector4.length(a: self Vector4): real
{
	return math->sqrt(a.x*a.x + a.y*a.y + a.z*a.z + a.w*a.w);
}

Vector4.normalize(a: self Vector4): Vector4
{
	l := math->sqrt(a.x*a.x + a.y*a.y + a.z*a.z + a.w*a.w);
	if(l == 0.0)
		return Vector4(0.0, 0.0, 0.0, 0.0);
	return Vector4(a.x/l, a.y/l, a.z/l, a.w/l);
}

Vector4.qmul(a: self Vector4, b: Vector4): Vector4
{
	return Vector4(
		a.x*b.w + a.w*b.x + a.y*b.z - a.z*b.y,
		a.y*b.w + a.w*b.y + a.z*b.x - a.x*b.z,
		a.z*b.w + a.w*b.z + a.x*b.y - a.y*b.x,
		a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z);
}

Vector4.qnlerp(a: self Vector4, b: Vector4, amt: real): Vector4
{
	r := Vector4(a.x + amt*(b.x-a.x), a.y + amt*(b.y-a.y),
		a.z + amt*(b.z-a.z), a.w + amt*(b.w-a.w));
	return r.normalize();
}

Vector4.qslerp(a: self Vector4, b: Vector4, amt: real): Vector4
{
	cosHalf := a.x*b.x + a.y*b.y + a.z*b.z + a.w*b.w;
	bb := b;
	if(cosHalf < 0.0){
		bb = Vector4(-b.x, -b.y, -b.z, -b.w);
		cosHalf = -cosHalf;
	}
	if(math->fabs(cosHalf) >= 1.0)
		return a;
	halfTheta := math->acos(cosHalf);
	sinHalf := math->sqrt(1.0 - cosHalf*cosHalf);
	if(math->fabs(sinHalf) < 0.001)
		return Vector4((a.x+bb.x)*0.5, (a.y+bb.y)*0.5, (a.z+bb.z)*0.5, (a.w+bb.w)*0.5);
	ra := math->sin((1.0-amt)*halfTheta)/sinHalf;
	rb := math->sin(amt*halfTheta)/sinHalf;
	return Vector4(a.x*ra + bb.x*rb, a.y*ra + bb.y*rb, a.z*ra + bb.z*rb, a.w*ra + bb.w*rb);
}

Vector4.qmatrix(a: self Vector4): Matrix
{
	r := Matrix.identity();
	m := r.m;
	x := a.x; y := a.y; z := a.z; w := a.w;
	a2 := x*x; b2 := y*y; c2 := z*z;
	ab := x*y; ac := x*z; bc := y*z;
	ad := w*x; bd := w*y; cd := w*z;
	m[0] = 1.0 - 2.0*(b2 + c2);
	m[1] = 2.0*(ab + cd);
	m[2] = 2.0*(ac - bd);
	m[4] = 2.0*(ab - cd);
	m[5] = 1.0 - 2.0*(a2 + c2);
	m[6] = 2.0*(bc + ad);
	m[8] = 2.0*(ac + bd);
	m[9] = 2.0*(bc - ad);
	m[10] = 1.0 - 2.0*(a2 + b2);
	return r;
}

# ---- Matrix ----

Matrix.identity(): Matrix
{
	m := array[16] of { * => 0.0 };
	m[0] = m[5] = m[10] = m[15] = 1.0;
	return Matrix(m);
}

Matrix.copy(a: self Matrix): Matrix
{
	m := array[16] of real;
	for(i := 0; i < 16; i++)
		m[i] = a.m[i];
	return Matrix(m);
}

Matrix.trace(a: self Matrix): real
{
	return a.m[0] + a.m[5] + a.m[10] + a.m[15];
}

Matrix.add(l: self Matrix, r: Matrix): Matrix
{
	m := array[16] of real;
	for(i := 0; i < 16; i++)
		m[i] = l.m[i] + r.m[i];
	return Matrix(m);
}

Matrix.sub(l: self Matrix, r: Matrix): Matrix
{
	m := array[16] of real;
	for(i := 0; i < 16; i++)
		m[i] = l.m[i] - r.m[i];
	return Matrix(m);
}

Matrix.mul(l: self Matrix, r: Matrix): Matrix
{
	a := l.m;
	b := r.m;
	m := array[16] of real;
	m[0]  = a[0]*b[0]  + a[1]*b[4]  + a[2]*b[8]   + a[3]*b[12];
	m[1]  = a[0]*b[1]  + a[1]*b[5]  + a[2]*b[9]   + a[3]*b[13];
	m[2]  = a[0]*b[2]  + a[1]*b[6]  + a[2]*b[10]  + a[3]*b[14];
	m[3]  = a[0]*b[3]  + a[1]*b[7]  + a[2]*b[11]  + a[3]*b[15];
	m[4]  = a[4]*b[0]  + a[5]*b[4]  + a[6]*b[8]   + a[7]*b[12];
	m[5]  = a[4]*b[1]  + a[5]*b[5]  + a[6]*b[9]   + a[7]*b[13];
	m[6]  = a[4]*b[2]  + a[5]*b[6]  + a[6]*b[10]  + a[7]*b[14];
	m[7]  = a[4]*b[3]  + a[5]*b[7]  + a[6]*b[11]  + a[7]*b[15];
	m[8]  = a[8]*b[0]  + a[9]*b[4]  + a[10]*b[8]  + a[11]*b[12];
	m[9]  = a[8]*b[1]  + a[9]*b[5]  + a[10]*b[9]  + a[11]*b[13];
	m[10] = a[8]*b[2]  + a[9]*b[6]  + a[10]*b[10] + a[11]*b[14];
	m[11] = a[8]*b[3]  + a[9]*b[7]  + a[10]*b[11] + a[11]*b[15];
	m[12] = a[12]*b[0] + a[13]*b[4] + a[14]*b[8]  + a[15]*b[12];
	m[13] = a[12]*b[1] + a[13]*b[5] + a[14]*b[9]  + a[15]*b[13];
	m[14] = a[12]*b[2] + a[13]*b[6] + a[14]*b[10] + a[15]*b[14];
	m[15] = a[12]*b[3] + a[13]*b[7] + a[14]*b[11] + a[15]*b[15];
	return Matrix(m);
}

Matrix.transpose(a: self Matrix): Matrix
{
	s := a.m;
	m := array[16] of real;
	m[0]=s[0];  m[1]=s[4];  m[2]=s[8];   m[3]=s[12];
	m[4]=s[1];  m[5]=s[5];  m[6]=s[9];   m[7]=s[13];
	m[8]=s[2];  m[9]=s[6];  m[10]=s[10]; m[11]=s[14];
	m[12]=s[3]; m[13]=s[7]; m[14]=s[11]; m[15]=s[15];
	return Matrix(m);
}

Matrix.determinant(a: self Matrix): real
{
	m := a.m;
	a00 := m[0]; a01 := m[1]; a02 := m[2]; a03 := m[3];
	a10 := m[4]; a11 := m[5]; a12 := m[6]; a13 := m[7];
	a20 := m[8]; a21 := m[9]; a22 := m[10]; a23 := m[11];
	a30 := m[12]; a31 := m[13]; a32 := m[14]; a33 := m[15];
	return
		a30*a21*a12*a03 - a20*a31*a12*a03 - a30*a11*a22*a03 + a10*a31*a22*a03 +
		a20*a11*a32*a03 - a10*a21*a32*a03 - a30*a21*a02*a13 + a20*a31*a02*a13 +
		a30*a01*a22*a13 - a00*a31*a22*a13 - a20*a01*a32*a13 + a00*a21*a32*a13 +
		a30*a11*a02*a23 - a10*a31*a02*a23 - a30*a01*a12*a23 + a00*a31*a12*a23 +
		a10*a01*a32*a23 - a00*a11*a32*a23 - a20*a11*a02*a33 + a10*a21*a02*a33 +
		a20*a01*a12*a33 - a00*a21*a12*a33 - a10*a01*a22*a33 + a00*a11*a22*a33;
}

Matrix.invert(a: self Matrix): Matrix
{
	s := a.m;
	a00 := s[0]; a01 := s[1]; a02 := s[2]; a03 := s[3];
	a10 := s[4]; a11 := s[5]; a12 := s[6]; a13 := s[7];
	a20 := s[8]; a21 := s[9]; a22 := s[10]; a23 := s[11];
	a30 := s[12]; a31 := s[13]; a32 := s[14]; a33 := s[15];

	b00 := a00*a11 - a01*a10;
	b01 := a00*a12 - a02*a10;
	b02 := a00*a13 - a03*a10;
	b03 := a01*a12 - a02*a11;
	b04 := a01*a13 - a03*a11;
	b05 := a02*a13 - a03*a12;
	b06 := a20*a31 - a21*a30;
	b07 := a20*a32 - a22*a30;
	b08 := a20*a33 - a23*a30;
	b09 := a21*a32 - a22*a31;
	b10 := a21*a33 - a23*a31;
	b11 := a22*a33 - a23*a32;

	invDet := 1.0/(b00*b11 - b01*b10 + b02*b09 + b03*b08 - b04*b07 + b05*b06);

	m := array[16] of real;
	m[0]  = (a11*b11 - a12*b10 + a13*b09)*invDet;
	m[1]  = (-a01*b11 + a02*b10 - a03*b09)*invDet;
	m[2]  = (a31*b05 - a32*b04 + a33*b03)*invDet;
	m[3]  = (-a21*b05 + a22*b04 - a23*b03)*invDet;
	m[4]  = (-a10*b11 + a12*b08 - a13*b07)*invDet;
	m[5]  = (a00*b11 - a02*b08 + a03*b07)*invDet;
	m[6]  = (-a30*b05 + a32*b02 - a33*b01)*invDet;
	m[7]  = (a20*b05 - a22*b02 + a23*b01)*invDet;
	m[8]  = (a10*b10 - a11*b08 + a13*b06)*invDet;
	m[9]  = (-a00*b10 + a01*b08 - a03*b06)*invDet;
	m[10] = (a30*b04 - a31*b02 + a33*b00)*invDet;
	m[11] = (-a20*b04 + a21*b02 - a23*b00)*invDet;
	m[12] = (-a10*b09 + a11*b07 - a12*b06)*invDet;
	m[13] = (a00*b09 - a01*b07 + a02*b06)*invDet;
	m[14] = (-a30*b03 + a31*b01 - a32*b00)*invDet;
	m[15] = (a20*b03 - a21*b01 + a22*b00)*invDet;
	return Matrix(m);
}

Matrix.translate(x, y, z: real): Matrix
{
	r := Matrix.identity();
	r.m[12] = x;
	r.m[13] = y;
	r.m[14] = z;
	return r;
}

Matrix.scaling(x, y, z: real): Matrix
{
	m := array[16] of { * => 0.0 };
	m[0] = x;
	m[5] = y;
	m[10] = z;
	m[15] = 1.0;
	return Matrix(m);
}

Matrix.rotate(axis: Vector3, angle: real): Matrix
{
	x := axis.x; y := axis.y; z := axis.z;
	ls := x*x + y*y + z*z;
	if(ls != 1.0 && ls != 0.0){
		il := 1.0/math->sqrt(ls);
		x *= il; y *= il; z *= il;
	}
	s := math->sin(angle);
	c := math->cos(angle);
	t := 1.0 - c;
	m := array[16] of { * => 0.0 };
	m[0] = x*x*t + c;
	m[1] = y*x*t + z*s;
	m[2] = z*x*t - y*s;
	m[4] = x*y*t - z*s;
	m[5] = y*y*t + c;
	m[6] = z*y*t + x*s;
	m[8] = x*z*t + y*s;
	m[9] = y*z*t - x*s;
	m[10] = z*z*t + c;
	m[15] = 1.0;
	return Matrix(m);
}

Matrix.rotatex(angle: real): Matrix
{
	r := Matrix.identity();
	c := math->cos(angle);
	s := math->sin(angle);
	r.m[5] = c;
	r.m[6] = s;
	r.m[9] = -s;
	r.m[10] = c;
	return r;
}

Matrix.rotatey(angle: real): Matrix
{
	r := Matrix.identity();
	c := math->cos(angle);
	s := math->sin(angle);
	r.m[0] = c;
	r.m[2] = -s;
	r.m[8] = s;
	r.m[10] = c;
	return r;
}

Matrix.rotatez(angle: real): Matrix
{
	r := Matrix.identity();
	c := math->cos(angle);
	s := math->sin(angle);
	r.m[0] = c;
	r.m[1] = s;
	r.m[4] = -s;
	r.m[5] = c;
	return r;
}

Matrix.rotatexyz(ang: Vector3): Matrix
{
	# compose X, then Y, then Z
	rx := Matrix.rotatex(ang.x);
	ry := Matrix.rotatey(ang.y);
	rz := Matrix.rotatez(ang.z);
	return rx.mul(ry).mul(rz);
}

Matrix.frustum(left, right, bottom, top, near, far: real): Matrix
{
	rl := right - left;
	tb := top - bottom;
	dfar := far - near;
	m := array[16] of { * => 0.0 };
	m[0] = near*2.0/rl;
	m[5] = near*2.0/tb;
	m[8] = (right + left)/rl;
	m[9] = (top + bottom)/tb;
	m[10] = -(far + near)/dfar;
	m[11] = -1.0;
	m[14] = -(far*near*2.0)/dfar;
	return Matrix(m);
}

Matrix.perspective(fovy, aspect, near, far: real): Matrix
{
	top := near*math->tan(fovy*0.5);
	bottom := -top;
	right := top*aspect;
	left := -right;
	return Matrix.frustum(left, right, bottom, top, near, far);
}

Matrix.ortho(left, right, bottom, top, near, far: real): Matrix
{
	rl := right - left;
	tb := top - bottom;
	dfar := far - near;
	m := array[16] of { * => 0.0 };
	m[0] = 2.0/rl;
	m[5] = 2.0/tb;
	m[10] = -2.0/dfar;
	m[12] = -(left + right)/rl;
	m[13] = -(top + bottom)/tb;
	m[14] = -(far + near)/dfar;
	m[15] = 1.0;
	return Matrix(m);
}

Matrix.lookat(eye, target, up: Vector3): Matrix
{
	vz := eye.sub(target).normalize();
	vx := up.cross(vz).normalize();
	vy := vz.cross(vx);
	m := array[16] of real;
	m[0]=vx.x; m[1]=vy.x; m[2]=vz.x; m[3]=0.0;
	m[4]=vx.y; m[5]=vy.y; m[6]=vz.y; m[7]=0.0;
	m[8]=vx.z; m[9]=vy.z; m[10]=vz.z; m[11]=0.0;
	m[12] = -(vx.x*eye.x + vx.y*eye.y + vx.z*eye.z);
	m[13] = -(vy.x*eye.x + vy.y*eye.y + vy.z*eye.z);
	m[14] = -(vz.x*eye.x + vz.y*eye.y + vz.z*eye.z);
	m[15] = 1.0;
	return Matrix(m);
}

# ---- quaternion constructors ----

qidentity(): Vector4
{
	return Vector4(0.0, 0.0, 0.0, 1.0);
}

qfromaxisangle(axis: Vector3, angle: real): Vector4
{
	if(axis.length() == 0.0)
		return qidentity();
	n := axis.normalize();
	ha := angle*0.5;
	s := math->sin(ha);
	c := math->cos(ha);
	q := Vector4(n.x*s, n.y*s, n.z*s, c);
	return q.normalize();
}

# ---- internal ----

fmin(a, b: real): real { if(a < b) return a; return b; }
fmax(a, b: real): real { if(a > b) return a; return b; }
