class_name JumpBoostComponent
extends Component

@export var jump_boost: float


func get_velocity(player: Player) -> float:
	return jump_boost * -player.speed.y * sign(player.gravity_flip)
