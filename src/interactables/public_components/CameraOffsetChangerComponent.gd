class_name CameraOffsetChangerComponent
extends Component

enum Mode {
	ADD,
	SET,
}

@export var mode: Mode = Mode.ADD
@export_custom(PROPERTY_HINT_NONE, "suffix:cells") var offset := Vector2.ZERO

@export_storage var initial_offset: Vector2
@export_storage var initial_gameplay_offset: Vector2


func _ready() -> void:
	await require([EasingComponent])
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)


func _get_property_default_value(property: String) -> Variant:
	match property:
		"mode":
			return Mode.ADD
		"offset":
			return Vector2.ZERO
		_:
			return null


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"initial_offset":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return initial_offset
		"initial_gameplay_offset":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return initial_gameplay_offset
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		_:
			set(field_name, field_data)


func start(_player: Player) -> void:
	initial_offset = LevelManager.player_camera.additional_offset


func _on_easing_progressed(_player: Player, weight_delta: float) -> void:
	match mode:
		Mode.ADD:
			LevelManager.player_camera.additional_offset += offset * Constants.CELLS_TO_PX * weight_delta
		Mode.SET:
			LevelManager.player_camera.additional_offset += (offset * Constants.CELLS_TO_PX - initial_offset) * weight_delta
