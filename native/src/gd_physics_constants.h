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

// Speed portal index (0.5x..4x) from the player's speed multiplier
// (SPEED_PRODUCT[i] / SPEED_PRODUCT[1]: 0.806, 1, 1.243, 1.502, 1.849).
// A multiplier of 0 (platformer stop) reads as 1x.
constexpr int speed_index(double multiplier) {
	if (multiplier <= 0.0) return 1;
	if (multiplier < 0.9) return 0;
	if (multiplier < 1.12) return 1;
	if (multiplier < 1.37) return 2;
	if (multiplier < 1.67) return 3;
	return 4;
}

// Per-speed player gravity, written by PlayerObject::updateTimeMod (2.2081,
// read in gdsolver/gdsolver dp/src/models/speed.hpp accelSwitchVyForSpeed):
// 0.5x 0.940199, 1x 0.958199, 2x 0.957199, 3x/4x 0.961199 (one row in GD).
// The cube falls with it; ship, UFO and ball use the fixed 0.958199.
constexpr double SPEED_GRAVITY_UNITS[5] = {0.940199, 0.958199024, 0.957199, 0.961199, 0.961199};

// PlayerObject::playerIsFallingBugged: vy < g + g with that per-speed g. It
// picks the ship's and UFO's weak/strong acceleration (was 1 g, not 2 g).
constexpr double falling_threshold_px(int speed) {
	return 2.0 * SPEED_GRAVITY_UNITS[speed] * VELOCITY_TO_PX;
}

// Cube jump impulse per speed, measured on 2.2081 (gdsolver speed.hpp
// cubePhysFor: 0.5x 10.620, 1x 11.180, 2x 11.420, 3x and 4x 11.230). The ball's
// tap and the rings scale with the same ratio; pads do not.
constexpr double SPEED_JUMP_UNITS[5] = {10.620, JUMP_UNITS, 11.420, 11.230, 11.230};
constexpr double jump_ratio(int speed) { return SPEED_JUMP_UNITS[speed] / JUMP_UNITS; }
constexpr double cube_gravity_ratio(int speed) { return SPEED_GRAVITY_UNITS[speed] / GRAVITY_UNITS; }

// Ship: holding takes shipAccel -1 with extraBoost 0.5 when falling, else 0.4;
// released takes 0.8 (falling) or 1.2 (rising) with extraBoost 0.4.
constexpr double ship_acceleration(double up, bool holding, bool mini, int speed = 1) {
	const double size = mini ? FLY_MINI_SIZE : 1.0;
	const bool falling = up < falling_threshold_px(speed);
	if (holding) return GRAVITY_PX * (falling ? 0.5 : 0.4) / size;
	return -GRAVITY_PX * (falling ? 0.8 : 1.2) * 0.4 / size;
}

// UFO: gravity * 0.5 * (0.8 falling | 1.2 rising) / size.
constexpr double ufo_acceleration(double up, bool mini, int speed = 1) {
	const double size = mini ? FLY_MINI_SIZE : 1.0;
	return -GRAVITY_PX * 0.5 * (up < falling_threshold_px(speed) ? 0.8 : 1.2) / size;
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
constexpr double ball_tap_px(bool mini, int speed = 1) {
	return JUMP_PX * jump_ratio(speed) * (mini ? MINI_SIZE_FACTOR : 1.0) * 0.5 * 0.6;
}

// Ship and UFO velocity limits in the player frame (gdsolver ship_params.hpp /
// ufo_params.hpp, measured on 2.2081): rising at most 8, falling at most 6.4
// (mini 9.412 / 7.529 = divided by 0.85), the same with gravity flipped. The
// old single cap clamped rises at 6.4. The swing keeps 8 both ways.
constexpr double fly_up_cap(bool swing, bool mini) {
	(void)swing;
	return 8.0 / (mini ? FLY_MINI_SIZE : 1.0) * VELOCITY_TO_PX;
}
constexpr double fly_down_cap(bool swing, bool mini) {
	return (swing ? 8.0 : 6.4) / (mini ? FLY_MINI_SIZE : 1.0) * VELOCITY_TO_PX;
}
constexpr double clamp_fly(double up, bool swing, bool mini) {
	const double hi = fly_up_cap(swing, mini), lo = -fly_down_cap(swing, mini);
	return up > hi ? hi : (up < lo ? lo : up);
}


constexpr double speed_ratio(int portal) {
	return SPEED_PRODUCT[portal] / SPEED_PRODUCT[1];
}

} // namespace gd_physics
