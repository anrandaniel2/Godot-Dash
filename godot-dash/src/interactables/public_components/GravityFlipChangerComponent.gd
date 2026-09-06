class_name GravityFlipChangerComponent
extends Component

enum FlipState {
	DOWN,
	UP,
	FLIP,
}

@export var flip_state: FlipState


func _ready() -> void:
	parent.interacted.connect(set_gravity)


func set_gravity(player: Player) -> void:
	match flip_state:
		FlipState.DOWN:
			player.gravity_flip = 1
		FlipState.UP:
			player.gravity_flip = -1
		FlipState.FLIP:
			player.gravity_flip *= -1
	var local_velocity: Vector2 = player.velocity.rotated(-player.gameplay_rotation)
	local_velocity.y = clampf(local_velocity.y, -Player.TERMINAL_VELOCITY.y, Player.TERMINAL_VELOCITY.y)
	player.velocity = local_velocity.rotated(player.gameplay_rotation)
