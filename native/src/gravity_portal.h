#pragma once

#include <cmath>

// Modes match GravityFlipChangerComponent.FlipState.
// DOWN is the blue portal (object 11), UP the yellow portal (object 10),
// TOGGLE the green portal (object 2926).
enum GravityPortalMode : int {
	GRAVITY_PORTAL_DOWN = 0,
	GRAVITY_PORTAL_UP = 1,
	GRAVITY_PORTAL_TOGGLE = 2,
};

struct GravityPortalResult {
	double gravity_flip = 1.0;
	double local_velocity_y = 0.0;
	bool changed = false;
};

inline int gravity_portal_mode_from_id(int gd_id, int explicit_mode) {
	if (explicit_mode >= GRAVITY_PORTAL_DOWN && explicit_mode <= GRAVITY_PORTAL_TOGGLE) {
		return explicit_mode;
	}
	if (gd_id == 10) {
		return GRAVITY_PORTAL_UP;
	}
	if (gd_id == 2926) {
		return GRAVITY_PORTAL_TOGGLE;
	}
	return GRAVITY_PORTAL_DOWN;
}

// Geometry Dash reverses vertical speed through a gravity portal so momentum
// continues in the new "down". A grounded player has ~0 speed; a small launch
// in the new fall direction is what actually leaves the old floor. Without it
// the next physics step still sees that floor and, once up_direction has
// flipped, classifies it as a lethal ceiling.
inline GravityPortalResult compute_gravity_portal(double current_flip, double local_velocity_y, int mode) {
	GravityPortalResult out;
	const double current = current_flip < 0.0 ? -1.0 : 1.0;
	double target = 1.0;
	if (mode == GRAVITY_PORTAL_UP) {
		target = -1.0;
	} else if (mode == GRAVITY_PORTAL_TOGGLE) {
		target = -current;
	}
	out.gravity_flip = target;
	out.local_velocity_y = local_velocity_y;
	if (target == current) {
		return out;
	}
	out.changed = true;
	double reversed = -local_velocity_y;
	constexpr double terminal = 3000.0;
	if (reversed > terminal) {
		reversed = terminal;
	}
	if (reversed < -terminal) {
		reversed = -terminal;
	}
	if (std::abs(reversed) < 80.0) {
		reversed = target * 180.0;
	}
	out.local_velocity_y = reversed;
	return out;
}
