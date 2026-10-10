#pragma once

#include <cmath>

// Spin for one sprite of a composite decoration (a sawblade built from
// mirrored quarters, a multi-sprite object, ...). Every sprite of the object
// must turn rigidly about the object's pivot, so each sprite's world basis is
// R * A (rotation applied in parent space), and its origin orbits the pivot.
//
// The old update used A * R (rotation in the sprite's local space). That is only
// rigid when A is a pure rotation. A mirrored sprite (negative determinant,
// e.g. sx = -1) then turns the opposite way from its orbit, so the quarters of
// a sawblade pull apart and the reconstructed circle tears.
//
// Plain math, no Godot types, so native/tests can check it without the engine:
//   g++ -std=c++17 -O2 native/tests/test_decoration_spin.cpp -o /tmp/decoration_spin_test

// Affine 2D transform in the Transform2D layout: x axis (xx, xy), y axis (yx, yy), origin (ox, oy).
struct SpinTransform2D {
	double xx = 1.0;
	double xy = 0.0;
	double yx = 0.0;
	double yy = 1.0;
	double ox = 0.0;
	double oy = 0.0;
};

// Rotates `t` rigidly by `angle` (radians, the same sense as Vector2.rotated)
// about the pivot (px, py).
inline SpinTransform2D spin_about_pivot(const SpinTransform2D &t, double px, double py, double angle) {
	const double c = std::cos(angle);
	const double s = std::sin(angle);
	SpinTransform2D r;
	// R * A, applied to each axis.
	r.xx = c * t.xx - s * t.xy;
	r.xy = s * t.xx + c * t.xy;
	r.yx = c * t.yx - s * t.yy;
	r.yy = s * t.yx + c * t.yy;
	// The origin orbits the pivot.
	const double dx = t.ox - px;
	const double dy = t.oy - py;
	r.ox = px + c * dx - s * dy;
	r.oy = py + s * dx + c * dy;
	return r;
}

// The bug the fix removes, kept here so the test can show the sign it produced.
inline SpinTransform2D spin_local_space_legacy(const SpinTransform2D &t, double px, double py, double angle) {
	const double c = std::cos(angle);
	const double s = std::sin(angle);
	SpinTransform2D r;
	// A * R: the axes turn in the sprite's own frame.
	r.xx = t.xx * c + t.yx * s;
	r.xy = t.xy * c + t.yy * s;
	r.yx = -t.xx * s + t.yx * c;
	r.yy = -t.xy * s + t.yy * c;
	const double dx = t.ox - px;
	const double dy = t.oy - py;
	r.ox = px + c * dx - s * dy;
	r.oy = py + s * dx + c * dy;
	return r;
}
