class_name JumpBoostComponent
extends Component

## GD 2.2081 cube jump per speed portal (0.5x, 1x, 2x, 3x, 4x) over the 1x jump,
## gdsolver/gdsolver dp/src/models/speed.hpp cubePhysFor; mirrors
## gd_physics::jump_ratio in native/src/gd_physics_constants.h.
const SPEED_JUMP_RATIO: Array[float] = [10.62 / 11.180032, 1.0, 11.42 / 11.180032, 11.23 / 11.180032, 11.23 / 11.180032]

@export var jump_boost: float
## Rings (orbs) scale their impulse with the per-speed jump; pads do not.
@export var scales_with_speed_jump: bool = false


## The speed portal tier for [param multiplier], as gd_physics::speed_index.
static func speed_tier(multiplier: float) -> int:
	if multiplier <= 0.0:
		return 1
	if multiplier < 0.9:
		return 0
	if multiplier < 1.12:
		return 1
	if multiplier < 1.37:
		return 2
	if multiplier < 1.67:
		return 3
	return 4


func get_velocity(player: Player) -> float:
	var ratio: float = SPEED_JUMP_RATIO[speed_tier(player.speed_multiplier)] if scales_with_speed_jump else 1.0
	return jump_boost * ratio * -player.speed.y * sign(player.gravity_flip)
