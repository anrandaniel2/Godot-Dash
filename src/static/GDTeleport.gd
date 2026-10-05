class_name GDTeleport
extends RefCounted
## GDScript twin of the native teleport helpers in native/src/gdash_native.cpp
## (gd_teleport_*). Geometry Dash 2.2 GJBaseGameLayer::teleportPlayer, as
## transcribed in square3ang/CBFExtrapolate src/physics/gjbasegamelayer.cpp and
## cross-checked against gdsolver/gdsolver src/solver/solver.hpp.

## GD velocity unit -> px/s: 0.9 * 60 * 128 / 30 (native/src/gd_physics_constants.h,
## VELOCITY_TO_PX). Player.SPEED.y is GD's 11.180032 jump times this.
const GD_VELOCITY_TO_PX: float = 230.4
const PORTAL_IDS: Array[int] = [38, 747, 749, 2064, 2902]


static func destination(player: Vector2, portal: Vector2, target: Vector2, keep_player_x: bool, save_offset: bool, ignore_x: bool, ignore_y: bool) -> Vector2:
	var result := target
	if keep_player_x:
		result.x = player.x
	if save_offset:
		result -= portal - player
	if ignore_x:
		result.x = player.x
	if ignore_y:
		result.y = player.y
	return result


## A decoration batch is one node for many objects; aim at its drawn centre.
static func target_point(target: Node2D) -> Vector2:
	if target is DecorationBatch:
		var bounds: Rect2 = (target as DecorationBatch).get_bounds()
		if bounds.has_area():
			return target.global_transform * bounds.get_center()
	return target.global_position


## Key 354 -> GravityFlipChangerComponent.FlipState (-1 = unchanged).
static func gravity_portal_mode(mode: int) -> int:
	match mode:
		1:
			return 0
		2:
			return 1
		3:
			return 2
	return -1


static func gravity_flip(portal_mode: int, current: int) -> int:
	match portal_mode:
		0:
			return 1
		1:
			return -1
		2:
			return -current
	return current


static func force_angle(has_destination: bool, object_id: int, destination_rotation: float, portal_rotation: float, flip_x: bool) -> float:
	var flip := 180.0 if flip_x else 0.0
	if not has_destination:
		return flip - portal_rotation
	return flip + (180.0 if object_id in PORTAL_IDS else 90.0) - destination_rotation


static func static_velocity(angle_degrees: float, force: float, additive: bool, velocity: Vector2, platformer: bool) -> Vector2:
	if is_zero_approx(force) and not additive:
		return Vector2(0.0 if platformer else velocity.x, 0.0)
	var push := Vector2.from_angle(deg_to_rad(angle_degrees)) * force
	var result := velocity
	result.y = push.y + velocity.y if additive else push.y
	if platformer:
		result.x = push.x + velocity.x if additive else push.x
	return result


static func redirect_velocity(angle_degrees: float, mod: float, min_speed: float, max_speed: float, velocity: Vector2, platformer: bool) -> Vector2:
	var turn := deg_to_rad(angle_degrees) - atan2(velocity.y, velocity.x)
	var turned := velocity
	if turn != 0.0:
		var s := sin(turn)
		var c := cos(turn)
		turned = Vector2(velocity.x * s - velocity.y * c, velocity.x * c + velocity.y * s)
	turned *= mod
	var speed := turned.length()
	if speed > 0.0:
		if max_speed > 0.0 and speed > max_speed:
			turned *= max_speed / speed
		elif min_speed > 0.0 and speed < min_speed:
			turned *= min_speed / speed
	return Vector2(turned.x if platformer else velocity.x, turned.y)
