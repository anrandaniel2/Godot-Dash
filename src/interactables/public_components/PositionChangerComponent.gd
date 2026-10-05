class_name PositionChangerComponent
extends Component

enum Mode {
	ADD,
	SET,
	MOVE_TOWARDS,
}

@export var mode: Mode = Mode.ADD:
	set(value):
		mode = value
		notify_property_list_changed()
@export_custom(PROPERTY_HINT_NONE, "suffix:cells") var position: Vector2
## Geometry Dash Move trigger keys 58/59 (Lock to Player X / Y). While the
## easing runs, that axis copies the activating player's per-tick translation
## instead of [member position]. Matches GDRweb [code]MoveTrigger.applyTransform[/code].
@export var lock_to_player_x: bool = false
@export var lock_to_player_y: bool = false
@export var move_towards: NodePath
## Multiplies the target distance between each object in the group. [br][br]
## [b]Examples:[/b] [br]
##   •  [code]0.0[/code]: the group's objects will all move towards the target object. [br]
##   •  [code]1.0[/code]: the group's objects will follow the target object but [b]keep[/b] their relative distance to it. [br]
##   •  [code]2.0[/code]: the group's objects will follow the target object but [b]double[/b] their relative distance to it. [br]
##   •  [code]-1.0[/code]: the group's objects will follow the target object but [b]invert[/b] their relative distance to it.
@export_range(0.0, 2.0, 0.05, "or_greater", "or_less", "slider") var distance_multiplier: float = 0.0
@export var offset: Vector2 ## Offset in global coordinates in units from the move target.

@export_storage var initial_global_positions: Dictionary[Node2D, Vector2]
@export_storage var initial_position_deltas: Dictionary[Node2D, Vector2]
@export_storage var group_objects: Array[Node2D]
var _last_player_positions: Dictionary[Player, Vector2]


func _ready() -> void:
	await require([TargetGroupComponent, EasingComponent])
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"mode": Mode.ADD,
		"position": Vector2.ZERO,
		"distance_multiplier": 1.0,
		"lock_to_player_x": false,
		"lock_to_player_y": false,
	}
	return DEFAULT_VALUES.get(property)


func _validate_property(property: Dictionary) -> void:
	if property.name in ["move_towards", "group_center", "offset", "distance_multiplier"] and mode != Mode.MOVE_TOWARDS:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	if property.name == "position" and mode == Mode.MOVE_TOWARDS:
		property.usage = PROPERTY_USAGE_NO_EDITOR


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"initial_global_positions":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return DictUtils.map_keys(initial_global_positions, Serialize.Node)
		"initial_position_deltas":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return DictUtils.map_keys(initial_position_deltas, Serialize.Node)
		"group_objects":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return group_objects.map(Serialize.Node)
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		"initial_global_positions":
			initial_global_positions.assign(Deserialize.NodeKeyedDict(field_data))
		"initial_position_deltas":
			initial_position_deltas.assign(Deserialize.NodeKeyedDict(field_data))
		"group_objects":
			group_objects.assign(Deserialize.Nodes(field_data))
		_:
			set(field_name, field_data)


func start(_player: Player) -> void:
	_last_player_positions.clear()
	var target_group_component := parent.query(TargetGroupComponent)
	group_objects.assign(target_group_component.all_members())
	group_objects.map(func(object): initial_global_positions.set(object, object.global_position))
	if group_objects.is_empty():
		Toasts.warning_once(
			"empty_group:" + ",".join(target_group_component.all_groups()),
			"In %s: target group doesn't contain any objects" % parent.name,
		)
	if mode == Mode.MOVE_TOWARDS:
		if move_towards != ^"":
			var move_towards_ref: Node2D = LevelManager.current_level.get_node(move_towards)
			group_objects.map(func(object): initial_position_deltas.set(object, move_towards_ref.global_position - object.global_position))
		elif Editor.in_editor:
			Toasts.error("In %s: move towards is unset" % parent.name)


func _on_easing_progressed(player: Player, weight_delta: float) -> void:
	var lock_delta := Vector2.ZERO
	if (lock_to_player_x or lock_to_player_y) and player != null and is_instance_valid(player):
		if _last_player_positions.has(player):
			lock_delta = player.global_position - _last_player_positions[player]
		_last_player_positions[player] = player.global_position
	match mode:
		Mode.ADD:
			for group_object in group_objects:
				var step: Vector2 = position * Constants.CELLS_TO_PX * weight_delta
				if lock_to_player_x:
					step.x = lock_delta.x
				if lock_to_player_y:
					step.y = lock_delta.y
				group_object.global_position += step
		Mode.SET:
			for group_object in group_objects:
				var initial_global_position = initial_global_positions[group_object]
				group_object.global_position += (parent.to_global(position * Constants.CELLS_TO_PX) - initial_global_position) * weight_delta
		Mode.MOVE_TOWARDS when not move_towards.is_empty():
			for group_object in group_objects:
				var initial_global_position: Vector2 = initial_global_positions[group_object]
				var initial_position_delta: Vector2 = initial_position_deltas[group_object]
				# FIXME: doesn't work when `move_towards` is moving
				var move_towards_ref: Node2D = LevelManager.current_level.get_node(move_towards)
				group_object.global_position += (
						move_towards_ref.global_position - initial_global_position
						+ initial_position_delta * -distance_multiplier
						+ offset * Constants.CELLS_TO_PX
				) * weight_delta
