class_name CameraGameplayOffsetChangerComponent
extends Component

enum Mode {
	SET,
	ADD,
}

@export var mode: Mode = Mode.SET
@export_custom(PROPERTY_HINT_RANGE, "-100.0,100.0,0.01,or_greater,or_less,suffix:%") var gameplay_offset := Vector2.ONE * 100.0

@export_storage var initial_gameplay_offset_factor: Vector2


func _ready() -> void:
	await require([EasingComponent])
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"initial_gameplay_offset_factor":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return initial_gameplay_offset_factor
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		_:
			set(field_name, field_data)


func _get_property_default_value(property: String) -> Variant:
	match property:
		"mode":
			return Mode.SET
		"gameplay_offset":
			return Vector2.ONE * 100.0
		_:
			return null


func start(_player: Player) -> void:
	initial_gameplay_offset_factor = LevelManager.player_camera.gameplay_offset_factor


func _on_easing_progressed(_player: Player, weight_delta: float) -> void:
	match mode:
		Mode.ADD:
			LevelManager.player_camera.gameplay_offset_factor += gameplay_offset * 0.01 * weight_delta
		Mode.SET:
			LevelManager.player_camera.gameplay_offset_factor += (gameplay_offset * 0.01 - initial_gameplay_offset_factor) * weight_delta
