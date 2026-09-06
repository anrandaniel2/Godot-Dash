class_name EnterEffectChangerComponent
extends Component

@export_range(0.0, 1.0, 0.01, "slider") var transition_width: float = 0.15
@export_range(0.0, 1.0, 0.01, "or_greater", "or_less", "slider") var fade_power: float = 1.0
@export_range(-1.0, 1.0, 0.01, "or_greater", "or_less", "slider") var move_power: float = 0.0
@export_range(-1.0, 1.0, 0.01, "or_greater", "or_less", "slider") var scale_power: float = 0.0

@export_storage var initial_values: Dictionary


func _ready() -> void:
	await require([EasingComponent])
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"transition_width": 0.15,
		"fade_power": 1.0,
		"move_power": 0.0,
		"scale_power": 0.0,
	}
	return DEFAULT_VALUES.get(property)


func start(_player: Player) -> void:
	initial_values.transition_width = LevelManager.current_level.transition_width
	initial_values.fade_power = LevelManager.current_level.fade_power
	initial_values.move_power = LevelManager.current_level.move_power
	initial_values.scale_power = LevelManager.current_level.scale_power


func _on_easing_progressed(_player: Player, weight_delta: float) -> void:
	LevelManager.current_level.transition_width += (transition_width - initial_values.transition_width) * weight_delta
	LevelManager.current_level.fade_power += (fade_power - initial_values.fade_power) * weight_delta
	LevelManager.current_level.move_power += (move_power - initial_values.move_power) * weight_delta
	LevelManager.current_level.scale_power += (scale_power - initial_values.scale_power) * weight_delta
