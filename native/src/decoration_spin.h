#pragma once

#include <cmath>
#include <cstdint>
#include <cstring>

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

struct SpinRotation {
	double c, s;
};

// Only the coefficients are shared: always read each record's current transform
// and pivot. Keep operation order identical to the uncached parent-space math.
inline SpinTransform2D spin_with_rotation(const SpinTransform2D &t, double px, double py, SpinRotation rotation) {
	const double c = rotation.c;
	const double s = rotation.s;
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

// Retain the angle-based API for callers/tests that do not process a batch.
inline SpinTransform2D spin_about_pivot(const SpinTransform2D &t, double px, double py, double angle) {
	return spin_with_rotation(t, px, py, { std::cos(angle), std::sin(angle) });
}

// Profile immutable speeds once when building the ordered spinning index.
// Enable reuse only when at least half the records can hit the run cache;
// alternating/unique speeds retain the original loop without per-record probes.
class SpinRunProfile {
	uint64_t count = 0, hits = 0;
	uint32_t previous = 0;
public:
	void add(float speed) {
		uint32_t bits;
		static_assert(sizeof(speed) == sizeof(bits), "Spin rates require 32-bit float");
		std::memcpy(&bits, &speed, sizeof(bits));
		if (count && bits == previous) ++hits;
		previous = bits;
		++count;
	}
	bool use_cache() const { return count > 1 && hits >= (count + 1) / 2; }
};

// Stack-local to ONE advance_animation call: no stale delta, reconfigure,
// restart, UI-layout or direct-transform-mutation invalidation is needed.
// Adjacent parts of composite decorations commonly share their float speed.
// One entry avoids allocations, hashing and a persistent per-record cache.
class SpinRotationRunCache {
	double delta;
	uint32_t last_speed = 0;
	SpinRotation rotation = {};
	bool valid = false;

public:
	explicit SpinRotationRunCache(double p_delta) : delta(p_delta) {}
	SpinRotation get(float speed) {
		static_assert(sizeof(float) == sizeof(uint32_t), "Spin rates require 32-bit float");
		uint32_t bits;
		std::memcpy(&bits, &speed, sizeof(bits));
		// Bit keys keep +0/-0 distinct and never quantize nearly equal speeds.
		if (!valid || bits != last_speed) {
			const double angle = static_cast<double>(speed) * delta;
			rotation = { std::cos(angle), std::sin(angle) };
			last_speed = bits;
			valid = true;
		}
		return rotation;
	}
};

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
