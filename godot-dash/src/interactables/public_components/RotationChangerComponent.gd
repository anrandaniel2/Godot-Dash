class_name RotationChangerComponent
extends Component

enum Mode {
	ADD,
	SET,
}

@export var mode: Mode = Mode.ADD:
	set(value):
		mode = value
		notify_property_list_changed()
@export_range(-180, 180, 0.01, "or_greater", "or_less", "degrees", "slider") var rotation: float
@export var pivot: NodePath
@export var rotate_around_self: bool:
	set(value):
		rotate_around_self = value
		notify_property_list_changed()

@export_storage var initial_global_rotations_degrees: Dictionary[Node2D, float]
@export_storage var group_objects: Array[Node2D]


func _ready() -> void:
	await require([TargetGroupComponent, EasingComponent])
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)


func _validate_property(property: Dictionary) -> void:
	if property.name == "pivot" and rotate_around_self:
		property.usage |= PROPERTY_USAGE_READ_ONLY


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"mode": Mode.ADD,
		"rotation": 0.0,
		"pivot": NodePath(),
		"rotate_around_self": false,
	}
	return DEFAULT_VALUES.get(property)


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"initial_global_rotations_degrees":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return DictUtils.map_keys(initial_global_rotations_degrees, Serialize.Node)
		"group_objects":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return group_objects.map(Serialize.Node)
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		"initial_global_rotations_degrees":
			initial_global_rotations_degrees.assign(Deserialize.NodeKeyedDict(field_data))
		"group_objects":
			group_objects.assign(Deserialize.Nodes(field_data))
		_:
			set(field_name, field_data)


func start(_player: Player) -> void:
	group_objects.assign(
		get_tree() \
				.get_nodes_in_group(parent.query(TargetGroupComponent).target_group) \
				.filter(func(object): return object is Node2D),
	)
	group_objects.map(func(object): initial_global_rotations_degrees.set(object, object.global_rotation))
	if group_objects.is_empty():
		Toasts.warning("In %s: target group doesn't contain any objects" % parent.name)


func _on_easing_progressed(_player: Player, weight_delta: float) -> void:
	for group_object in group_objects:
		var initial_global_rotation_degrees := initial_global_rotations_degrees[group_object]
		var rotation_delta: float
		match mode:
			Mode.SET:
				rotation_delta = (rotation - initial_global_rotation_degrees) * weight_delta
			Mode.ADD:
				rotation_delta = rotation * weight_delta
		_apply_rotation_delta(group_object, rotation_delta)


func _apply_rotation_delta(group_object: Node2D, rotation_delta: float) -> void:
	if rotate_around_self:
		group_object.global_rotation_degrees += rotation_delta
	elif pivot != ^"":
		group_object.global_rotation_degrees += rotation_delta
		var pivot_ref: Node2D = LevelManager.current_level.get_node(pivot)
		var position_relative_to_pivot: Vector2 = group_object.global_position - pivot_ref.global_position
		var position_delta := position_relative_to_pivot.rotated(deg_to_rad(rotation_delta)) - position_relative_to_pivot
		group_object.global_position += position_delta
