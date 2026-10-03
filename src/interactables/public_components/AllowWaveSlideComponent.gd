class_name AllowWaveSlideComponent
extends Component

func _ready() -> void:
	parent.body_entered.connect(func(player: Player): player.allow_wave_slide_count += 1)
	parent.body_exited.connect(func(player: Player): player.allow_wave_slide_count -= 1)
