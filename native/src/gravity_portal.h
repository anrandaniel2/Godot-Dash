#pragma once

#include <cmath>
#include "gd_physics_constants.h"

// Modes match GravityFlipChangerComponent.FlipState.
// DOWN is the blue portal (object 10, atlas portal_01), UP the yellow portal
// (object 11, atlas portal_02), TOGGLE the green portal (object 2926).
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
	if (gd_id == 11) {
		return GRAVITY_PORTAL_UP;
	}
	if (gd_id == 2926) {
		return GRAVITY_PORTAL_TOGGLE;
	}
	return GRAVITY_PORTAL_DOWN;
}

// Geometry Dash halves vertical speed through a gravity portal and keeps its
// direction, so the flipped gravity curves the player round slowly (GD 2.2
// PlayerObject::flipGravity, `m_yVelocity *= 0.5`; read in GucciBot
// src/absense/physics/gravity.cpp flipGravityInner). Only a pad adds a push.
// A grounded player has ~0 speed; a small nudge in the new fall direction is
// what leaves the old floor, which the next physics step would otherwise
// classify as a lethal ceiling once up_direction has flipped.
constexpr double GRAVITY_PORTAL_SPEED_KEEP = 0.5;
constexpr double GRAVITY_PORTAL_NUDGE = 180.0;
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
	double reversed = local_velocity_y * GRAVITY_PORTAL_SPEED_KEEP;
	constexpr double terminal = gd_physics::TERMINAL_PX;
	if (reversed > terminal) {
		reversed = terminal;
	}
	if (reversed < -terminal) {
		reversed = -terminal;
	}
	if (std::abs(reversed) < 80.0) {
		reversed = target * GRAVITY_PORTAL_NUDGE;
	}
	out.local_velocity_y = reversed;
	return out;
}
