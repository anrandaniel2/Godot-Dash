class_name CameraGameplayOffsetChangerComponent
extends Component

enum Mode {
	SET,
	ADD,
}

@export var mode: Mode = Mode.SET
## GD's GP Offset value: the editor default is 25, which is the default
## 75-unit look-ahead (gd_docs camera properties, PlayerCamera.gd). Values are
## raw GD values, so a parsed level keeps its numbers.
const GD_DEFAULT_OFFSET_VALUE: float = 25.0

@export_custom(PROPERTY_HINT_RANGE, "-100.0,100.0,0.1,or_greater,or_less") var gameplay_offset := Vector2.ONE * GD_DEFAULT_OFFSET_VALUE

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
			return Vector2.ONE * GD_DEFAULT_OFFSET_VALUE
		_:
			return null


## The camera's gameplay offset factor for a GD GP Offset value: 1.0 is the
## default look-ahead, so 25 maps to 1.0 and 12.5 to half of it.
static func gd_offset_factor(value: float) -> float:
	return value / GD_DEFAULT_OFFSET_VALUE


func start(_player: Player) -> void:
	initial_gameplay_offset_factor = LevelManager.player_camera.gameplay_offset_factor


func _on_easing_progressed(_player: Player, weight_delta: float) -> void:
	match mode:
		Mode.ADD:
			LevelManager.player_camera.gameplay_offset_factor += gameplay_offset / GD_DEFAULT_OFFSET_VALUE * weight_delta
		Mode.SET:
			LevelManager.player_camera.gameplay_offset_factor += (gameplay_offset / GD_DEFAULT_OFFSET_VALUE - initial_gameplay_offset_factor) * weight_delta
