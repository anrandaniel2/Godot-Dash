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
## Seconds between offset samples, held in between. 0 samples every frame.
@export_range(0.0, 0.2, 0.01, "or_greater", "suffix:s") var interval: float = 0.0

var noise: FastNoiseLite
var linear_eased_weight: float
var interval_clock: float = 0.0
var held_offset: Vector2 = Vector2.ZERO
var sampled: bool = false


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
		"interval":
			return 0.0
		_:
			return null


func start(_player: Player):
	linear_eased_weight = 0.0
	interval_clock = 0.0
	sampled = false


func _on_easing_progressed(player: Player, _weight_delta: float) -> void:
	var easing_component: EasingComponent = parent.query(EasingComponent)
	var weight: float = easing_component.weights[player]
	var delta := get_process_delta_time()
	linear_eased_weight += delta / easing_component.get_duration()
	# Interval: the offset is sampled once per interval and held until the next
	# sample; 0 samples every frame. The finishing frame samples at full weight.
	interval_clock += delta
	if not sampled or weight >= 1.0 or interval_clock >= interval:
		interval_clock = fposmod(interval_clock, interval) if interval > 0.0 else 0.0
		sampled = true
		held_offset = _sample_offset(weight)
	LevelManager.player_camera.shake_offset = held_offset


func _sample_offset(weight: float) -> Vector2:
	var noise_sample_position := (weight if eased == Eased.SPEED_AND_STRENGTH else linear_eased_weight) * speed / 100 * 10000
	var sample_strength := 1.0 - weight
	match axis:
		Axis.BOTH:
			return Vector2(
				noise.get_noise_2d(noise_sample_position, 0.0),
				noise.get_noise_2d(1.0, noise_sample_position), # Offset so the starting value is different
			) * sample_strength * strength * 10.0
		Axis.ANGLE:
			return Vector2.from_angle(deg_to_rad(angle)) * noise.get_noise_1d(
				noise_sample_position,
			) * sample_strength * strength * 10.0
	return Vector2.ZERO
