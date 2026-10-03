class_name GravityMultiplierChangerComponent
extends Component

signal changed(gravity_multiplier: String)

@export_range(0.0, 2.0, 0.01, "or_greater", "or_less", "slider", "percentage") var gravity_multiplier: float = 1.0:
	set(value):
		gravity_multiplier = value
		emit_changed()

@export_storage var initial_gravity_multipliers: Dictionary[Player, float]


func _ready() -> void:
	await require([EasingComponent])
	emit_changed.call_deferred()
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"gravity_multiplier": 1.0,
	}
	return DEFAULT_VALUES.get(property)


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"initial_gravity_multipliers":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return DictUtils.map_keys(initial_gravity_multipliers, Serialize.Node)
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		"initial_gravity_multipliers":
			initial_gravity_multipliers.assign(Deserialize.NodeKeyedDict(field_data))
		_:
			set(field_name, field_data)


func emit_changed() -> void:
	changed.emit("%.f%%" % (gravity_multiplier * 100))


func start(player: Player) -> void:
	initial_gravity_multipliers.set(player, player.gravity_multiplier)


func _on_easing_progressed(player: Player, weight_delta: float) -> void:
	player.gravity_multiplier += (gravity_multiplier - initial_gravity_multipliers[player]) * weight_delta
