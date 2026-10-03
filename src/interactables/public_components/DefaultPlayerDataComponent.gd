class_name DefaultPlayerDataComponent
extends Component

@export var platformer: bool:
	set(value):
		platformer = value
		if Editor.in_editor:
			Editor.root.level.platformer = value
		notify_property_list_changed()
@export var reverse: bool:
	set(value):
		reverse = value
		if Editor.in_editor:
			Editor.root.level.start_reverse = value
@export_enum("x0.0", "x0.5", "x1.0", "x2.0", "x3.0", "x4.0", "x5.0", "Custom") var speed_preset: int = EasedSpeedChangerComponent.SpeedPreset.x1:
	set(value):
		speed_preset = value
		speed = Level.START_SPEED[speed_preset] if speed_preset != EasedSpeedChangerComponent.SpeedPreset.CUSTOM else manual_speed
		if Editor.in_editor:
			Editor.root.level.start_speed_preset = value
		notify_property_list_changed()
@export_range(0.0, 2.0, 0.01, "or_greater", "slider") var speed: float = 1.0:
	set(value):
		speed = value
		if speed_preset == EasedSpeedChangerComponent.SpeedPreset.CUSTOM:
			manual_speed = value
		if Editor.in_editor:
			Editor.root.level.start_speed = value
@export_range(-180, 180, 0.01, "degrees", "slider") var gameplay_rotation: float:
	set(value):
		gameplay_rotation = value
		if Editor.in_editor:
			Editor.root.level.start_gameplay_rotation_degrees = value
@export_range(0.0, 2.0, 0.01, "or_greater", "or_less", "slider") var gravity_multiplier: float = 1.0:
	set(value):
		gravity_multiplier = value
		if Editor.in_editor:
			Editor.root.level.start_gravity_multiplier = value
@export var flipped_gravity: bool = false:
	set(value):
		flipped_gravity = value
		if Editor.in_editor:
			Editor.root.level.start_gravity_flip = 1 if not flipped_gravity else -1

@export_group("Gamemode:open")
@export var internal: Player.Gamemode:
	set(value):
		internal = value
		if Editor.in_editor:
			Editor.root.level.start_internal_gamemode = value
@export var displayed: Player.Gamemode:
	set(value):
		displayed = value
		if Editor.in_editor:
			Editor.root.level.start_displayed_gamemode = value
@export var freefly: bool = true:
	set(value):
		freefly = value
		if Editor.in_editor:
			Editor.root.level.start_freefly = value

@export_storage var manual_speed: float = speed


func _validate_property(property: Dictionary) -> void:
	if property.name == "reverse" and platformer:
		property.usage |= PROPERTY_USAGE_READ_ONLY
	if property.name == "speed" and speed_preset != EasedSpeedChangerComponent.SpeedPreset.CUSTOM:
		property.usage = PROPERTY_USAGE_NO_EDITOR


func _get_property_default_value(property: String) -> Variant:
	const DEFAULT_VALUES: Dictionary[String, Variant] = {
		"platformer": false,
		"reverse": false,
		"speed_preset": EasedSpeedChangerComponent.SpeedPreset.x1,
		"speed": 1.0,
		"gameplay_rotation": 0.0,
		"gravity_multiplier": 1.0,
		"flipped_gravity": false,
		"internal": Player.Gamemode.CUBE,
		"displayed": Player.Gamemode.CUBE,
		"freefly": false,
	}
	return DEFAULT_VALUES.get(property)
