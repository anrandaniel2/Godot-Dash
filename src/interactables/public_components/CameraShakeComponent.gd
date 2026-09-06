class_name CameraShakeComponent
extends Component

enum Axis {
	BOTH,
	ANGLE,
}

enum Eased {
	STRENGTH, ## Multiplies the strength by the easing weight
	SPEED_AND_STRENGTH,
}

@export_range(0.01, 10.0, 0.01, "or_greater", "slider") var strength: float = 5.0
@export_range(0.01, 100.0, 0.01, "or_greater", "slider", "suffix:%") var speed: float = 100.0
@export var eased: Eased = Eased.STRENGTH
@export var axis: Axis = Axis.BOTH:
	set(value):
		axis = value
		notify_property_list_changed()
@export_range(-180, 180, 0.01, "degrees", "slider") var angle: float = 0.0

var noise: FastNoiseLite
var linear_eased_weight: float


func _ready() -> void:
	await require([EasingComponent])
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)
	noise = FastNoiseLite.new()
	# RIDs will change every time the resource is created
	noise.seed = hash(noise)


func _validate_property(property: Dictionary) -> void:
	if property.name == "angle" and axis != Axis.ANGLE:
		property.usage = PROPERTY_USAGE_NO_EDITOR


func _get_property_default_value(property: String) -> Variant:
	match property:
		"strength":
			return 5.0
		"speed":
			return 100.0
		"eased":
			return Eased.STRENGTH
		"axis":
			return Axis.BOTH
		"angle":
			return 0.0
		_:
			return null


func start(_player: Player):
	linear_eased_weight = 0.0


func _on_easing_progressed(player: Player, _weight_delta: float) -> void:
	var easing_component: EasingComponent = parent.query(EasingComponent)
	var weight: float = easing_component.weights[player]
	linear_eased_weight += get_process_delta_time() / easing_component.get_duration()
	var noise_sample_position := (weight if eased == Eased.SPEED_AND_STRENGTH else linear_eased_weight) * speed / 100 * 10000
	var sample_strength := 1.0 - weight
	match axis:
		Axis.BOTH:
			LevelManager.player_camera.shake_offset.x = noise.get_noise_2d(
				noise_sample_position,
				0.0,
			) * sample_strength * strength * 10.0
			LevelManager.player_camera.shake_offset.y = noise.get_noise_2d(
				1.0, # Offset so the starting value is different
				noise_sample_position,
			) * sample_strength * strength * 10.0
		Axis.ANGLE:
			LevelManager.player_camera.shake_offset = Vector2.from_angle(deg_to_rad(angle)) * noise.get_noise_1d(
				noise_sample_position,
			) * sample_strength * strength * 10.0
