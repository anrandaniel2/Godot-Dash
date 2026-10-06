class_name GDPhysics
## Twin of native/src/gd_physics_constants.h: GD fly-mode and ball rules in
## px/s, as "up" relative to the current gravity (positive = away from the
## floor). Sources: GucciBot src/absense/physics/player.cpp (2.2081 updateJump
## port) and OpenGD Source/PlayerObject.cpp (updateJump, playerIsFalling).

const VELOCITY_TO_PX: float = 230.4
const GRAVITY_PX: float = 11921.53
const JUMP_PX: float = 2575.88
const MINI_SIZE_FACTOR: float = 0.8
const FLY_MINI_SIZE: float = 0.85
const FALLING_PX: float = 0.958199 * VELOCITY_TO_PX
const SWING_TAP_KEEP: float = 0.8
const BALL_GRAVITY_FACTOR: float = 0.6


static func is_falling(up: float) -> bool:
	return up < FALLING_PX


static func ship_acceleration(up: float, holding: bool, mini: bool) -> float:
	var size: float = FLY_MINI_SIZE if mini else 1.0
	if holding:
		return GRAVITY_PX * (0.5 if is_falling(up) else 0.4) / size
	return -GRAVITY_PX * (0.8 if is_falling(up) else 1.2) * 0.4 / size


static func ufo_acceleration(up: float, mini: bool) -> float:
	var size: float = FLY_MINI_SIZE if mini else 1.0
	return -GRAVITY_PX * 0.5 * (0.8 if is_falling(up) else 1.2) / size


static func ufo_tap(up: float, mini: bool) -> float:
	var boost: float = (8.0 * FLY_MINI_SIZE if mini else 7.0) * VELOCITY_TO_PX
	return boost if up < boost else up


static func swing_acceleration(mini: bool) -> float:
	return -GRAVITY_PX * (0.6 if mini else 0.4)


static func ball_tap_px(mini: bool) -> float:
	return JUMP_PX * (MINI_SIZE_FACTOR if mini else 1.0) * 0.5 * 0.6


static func fly_cap(swing: bool, mini: bool, upside_down: bool) -> float:
	var size: float = FLY_MINI_SIZE if mini else 1.0
	var what: float = 1.0 if swing or upside_down else 0.8
	return what * 8.0 / size * VELOCITY_TO_PX
