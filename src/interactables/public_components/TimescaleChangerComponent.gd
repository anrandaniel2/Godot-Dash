class_name TimescaleChangerComponent
extends Component

signal changed(time_scale: String)

@export_range(0.01, 2.0, 0.01, "or_greater", "slider", "percentage") var time_scale: float = 1.0:
	set(value):
		time_scale = value
		emit_changed()

@export_storage var initial_time_scale: float


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
	initial_time_scale = Engine.time_scale


func _on_easing_progressed(_player: Player, weight_delta: float) -> void:
	Engine.time_scale += (time_scale - initial_time_scale) * weight_delta
	Engine.time_scale = maxf(Engine.time_scale, 0.01)
