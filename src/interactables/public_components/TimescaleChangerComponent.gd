class_name TimescaleChangerComponent
extends Component

signal changed(time_scale: String)

@export_range(0.01, 2.0, 0.01, "or_greater", "slider", "percentage") var time_scale: float = 1.0:
	set(value):
		time_scale = value
		emit_changed()

@export_storage var initial_time_scale: float

## The level's own factor from Timescale triggers. Engine.time_scale is this
## times Config.game_speed, so the player's Game speed setting is kept while a
## trigger changes the level's speed.
static var level_time_scale: float = 1.0


## Sets Engine.time_scale from the level factor and the Game speed setting.
static func apply_game_speed() -> void:
	Engine.time_scale = maxf(Config.game_speed * level_time_scale, 0.001)


## Back to the level's normal factor (level start, restart, exit to menu).
static func reset_time_scale() -> void:
	level_time_scale = 1.0
	apply_game_speed()


func _ready() -> void:
	await require([EasingComponent])
	emit_changed.call_deferred()
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"time_scale": 1.0,
	}
	return DEFAULT_VALUES.get(property)


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"initial_time_scale":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return initial_time_scale
		_:
			return get(field_name)


func emit_changed() -> void:
	changed.emit("%.f%%" % (time_scale * 100))


func start(_player: Player) -> void:
	initial_time_scale = level_time_scale


func _on_easing_progressed(_player: Player, weight_delta: float) -> void:
	level_time_scale += (time_scale - initial_time_scale) * weight_delta
	level_time_scale = maxf(level_time_scale, 0.01)
	apply_game_speed()
