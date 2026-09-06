class_name GameplayRotationChangerComponent
extends Component

@export_range(-180, 180, 0.01, "degrees", "or_greater", "or_less", "slider") var gameplay_rotation: float

var initial_gameplay_rotations: Dictionary[Player, float]


func _ready() -> void:
	await require([EasingComponent])
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)


func start(player: Player) -> void:
	initial_gameplay_rotations.set(player, player.gameplay_rotation_degrees)


func _on_easing_progressed(player: Player, weight_delta: float) -> void:
	player.gameplay_rotation_degrees += (gameplay_rotation - initial_gameplay_rotations[player]) * weight_delta
	if is_equal_approx(weight_delta, 1.0) and is_equal_approx(absf(gameplay_rotation - initial_gameplay_rotations[player]), PI):
		player.defer_snap_sprite_rotation()
