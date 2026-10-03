class_name AllowCeilingHitComponent
extends Component

func _ready() -> void:
	parent.body_entered.connect(func(player: Player): player.allow_ceiling_hit_count += 1)
	parent.body_exited.connect(func(player: Player): player.allow_ceiling_hit_count -= 1)
