class_name StopDashComponent
extends Component

func _ready() -> void:
	parent.interacted.connect(stop_dash)


func stop_dash(player: Player) -> void:
	player.stop_dash()
