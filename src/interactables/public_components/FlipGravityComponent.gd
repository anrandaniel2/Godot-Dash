class_name FlipGravityComponent
extends Component

func _ready() -> void:
	parent.body_entered.connect(engage_player_for_flip)
	parent.body_exited.connect(disengage_player_for_flip)


func engage_player_for_flip(player: Player) -> void:
	player.hit_ceiling.connect(flip)


func disengage_player_for_flip(player: Player) -> void:
	player.hit_ceiling.disconnect(flip)


func flip(player: Player) -> void:
	# Avoid flipping gravity multiple times in a frame
	player.set_deferred(&"gravity_flip", -player.gravity_flip)
	player.jump_hold_disabled = true
