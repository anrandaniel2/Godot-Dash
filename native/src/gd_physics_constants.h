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

constexpr double speed_ratio(int portal) {
	return SPEED_PRODUCT[portal] / SPEED_PRODUCT[1];
}

} // namespace gd_physics
