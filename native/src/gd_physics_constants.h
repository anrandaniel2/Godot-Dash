#pragma once
// Geometry Dash player constants converted to Godot Dash pixels per second.
//
// GD integrates once per 60 Hz frame unit (OpenGD Source/PlayerObject.cpp,
// PlayerObject::update / updateJump, a reimplementation from the decompiled
// game; the same constants appear in opendashteam/open-dash
// src/game/constants.h and GucciBot src/absense/physics/player.cpp):
//   dtSlow = dt * 0.9
//   yVel  -= gravity * dtSlow * modeFactor        (units per frame)
//   y     += dtSlow * yVel
//   x     += dt * timeMod * playerSpeed
// One GD block is 30 units and 128 px here (Constants.CELL_SIZE).
//
// Cross-checks: 1x x speed 0.9 * 5.770002 * 60 = 311.58 u/s, Pathfinder's
// measured 311.580093712804 u/s; cube airtime 2 * 11.180032 / (0.958199 * 0.9)
// frames = 0.432 s, jump peak 2.17 blocks.

namespace gd_physics {

constexpr double PX_PER_UNIT = 128.0 / 30.0;
constexpr double FRAMES_PER_SECOND = 60.0;
constexpr double SLOW = 0.9;

// A velocity in units per frame, integrated with dtSlow, to px/s.
constexpr double VELOCITY_TO_PX = SLOW * FRAMES_PER_SECOND * PX_PER_UNIT; // 230.4
// An acceleration in units per frame per frame (applied with dtSlow to a
// velocity that is itself applied with dtSlow) to px/s^2.
constexpr double ACCELERATION_TO_PX = SLOW * SLOW * FRAMES_PER_SECOND * FRAMES_PER_SECOND * PX_PER_UNIT; // 12441.6

constexpr double GRAVITY_UNITS = 0.958199;
constexpr double JUMP_UNITS = 11.180032;
constexpr double CUBE_TERMINAL_UNITS = 15.0;
constexpr double MINI_SIZE_FACTOR = 0.8;

// Speed portals: playerSpeed * timeMod (0.5x, 1x, 2x, 3x, 4x).
constexpr double SPEED_PRODUCT[5] = {
	0.7 * 5.980002, 0.9 * 5.770002, 1.1 * 5.870002, 1.3 * 6.000002, 1.6 * 6.000002,
};

constexpr double X_SPEED_PX = SPEED_PRODUCT[1] * FRAMES_PER_SECOND * PX_PER_UNIT; // 1329.41
constexpr double JUMP_PX = JUMP_UNITS * VELOCITY_TO_PX;                             // 2575.88
constexpr double MINI_JUMP_PX = JUMP_PX * MINI_SIZE_FACTOR;                         // 2060.70
constexpr double GRAVITY_PX = GRAVITY_UNITS * ACCELERATION_TO_PX;                   // 11921.53
constexpr double TERMINAL_PX = CUBE_TERMINAL_UNITS * VELOCITY_TO_PX;                // 3456

// ---- Flying modes and ball (GucciBot src/absense/physics/player.cpp, the
// fly-mode block of the updateJump port read from 2.2081, and OpenGD
// Source/PlayerObject.cpp PlayerObject::updateJump / playerIsFalling).
// All velocities here are px/s "up" relative to the current gravity
// (positive = away from the floor), accelerations px/s^2.
constexpr double FLY_MINI_SIZE = 0.85;     // vehicleSizeRelated for ship/UFO/wave/swing
constexpr double FALLING_PX = GRAVITY_UNITS * VELOCITY_TO_PX; // playerIsFalling: up < gravity

constexpr bool is_falling(double up) { return up < FALLING_PX; }

// Ship: holding takes shipAccel -1 with extraBoost 0.5 when falling, else 0.4;
// released takes 0.8 (falling) or 1.2 (rising) with extraBoost 0.4.
constexpr double ship_acceleration(double up, bool holding, bool mini) {
	const double size = mini ? FLY_MINI_SIZE : 1.0;
	if (holding) return GRAVITY_PX * (is_falling(up) ? 0.5 : 0.4) / size;
	return -GRAVITY_PX * (is_falling(up) ? 0.8 : 1.2) * 0.4 / size;
}

// UFO: gravity * 0.5 * (0.8 falling | 1.2 rising) / size.
constexpr double ufo_acceleration(double up, bool mini) {
	const double size = mini ? FLY_MINI_SIZE : 1.0;
	return -GRAVITY_PX * 0.5 * (is_falling(up) ? 0.8 : 1.2) / size;
}

// UFO tap: 7 units (mini 8 * 0.85), never slowing a faster rise.
constexpr double ufo_tap(double up, bool mini) {
	const double boost = (mini ? 8.0 * FLY_MINI_SIZE : 7.0) * VELOCITY_TO_PX;
	return up < boost ? boost : up;
}

// Swing: gravity * 0.4 (mini 0.6), no size divide; a tap flips gravity and
// keeps 0.8 of the speed.
constexpr double swing_acceleration(bool mini) { return -GRAVITY_PX * (mini ? 0.6 : 0.4); }
constexpr double SWING_TAP_KEEP = 0.8;

// Ball: gravity * 0.6. A tap sets the jump, flipGravity halves it, then * 0.6:
// it leaves toward the new floor at 0.3 of the jump (times 0.8 when mini).
constexpr double BALL_GRAVITY_FACTOR = 0.6;
constexpr double ball_tap_px(bool mini) { return JUMP_PX * (mini ? MINI_SIZE_FACTOR : 1.0) * 0.5 * 0.6; }

// Speed caps at the end of the fly block: (what * 8) / size with what 0.8
// (1.0 for swing) in normal gravity, plain 8 / size upside down.
constexpr double fly_cap(bool swing, bool mini, bool upside_down) {
	const double size = mini ? FLY_MINI_SIZE : 1.0;
	const double what = (swing || upside_down) ? 1.0 : 0.8;
	return what * 8.0 / size * VELOCITY_TO_PX;
}

constexpr double clamp_cap(double up, double cap) { return up > cap ? cap : (up < -cap ? -cap : up); }

constexpr double speed_ratio(int portal) {
	return SPEED_PRODUCT[portal] / SPEED_PRODUCT[1];
}

} // namespace gd_physics
