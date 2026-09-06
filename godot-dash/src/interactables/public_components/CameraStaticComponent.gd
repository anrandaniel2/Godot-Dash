class_name CameraStaticComponent
extends Component

enum Mode {
	ENTER,
	EXIT,
}

@export var mode: Mode = Mode.ENTER:
	set(value):
		mode = value
		if not is_node_ready():
			await ready
		match mode:
			Mode.ENTER:
				parent.query(TargetObjectComponent).override = ^""
			Mode.EXIT:
				parent.query(TargetObjectComponent).override = LevelManager.current_level.get_path_to(LevelManager.player)
@export var axis: Constants.Axis = Constants.Axis.BOTH

@export_storage var initial_global_position: Vector2
@export_storage var initial_static_factor: Vector2

var target: Node2D


func _ready() -> void:
	await require([TargetObjectComponent, EasingComponent])
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)
	parent.query(EasingComponent).restored.connect(_on_easing_restored)


func _get_property_default_value(property: String) -> Variant:
	match property:
		"mode":
			return Mode.ENTER
		"axis":
			return Constants.Axis.BOTH
		_:
			return null


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"initial_global_position", "initial_static_factor":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return get(field_name)
		_:
			return get(field_name)


func start(_player: Player) -> void:
	initial_global_position = LevelManager.player_camera.global_position
	initial_static_factor = LevelManager.player_camera.static_factor
	LevelManager.player_camera.static_offset_rotation = LevelManager.player_camera.smoothed_gameplay_rotation
	target = parent.query(TargetObjectComponent).target_to_node()
	if not target:
		Toasts.error("In %s: target is unset" % parent.name)


func _on_easing_progressed(player: Player, _weight_delta: float) -> void:
	if not target:
		return
	var entering_or_exiting: float
	match mode:
		Mode.ENTER:
			entering_or_exiting = 1.0
		Mode.EXIT:
			entering_or_exiting = 0.0
	var weight: float = parent.query(EasingComponent).weights[player]
	if axis == Constants.Axis.X or axis == Constants.Axis.BOTH:
		LevelManager.player_camera.static_factor.x = lerpf(initial_static_factor.x, entering_or_exiting, weight)
		LevelManager.player_camera.global_position.x = lerpf(initial_global_position.x, target.global_position.x, weight)
	if axis == Constants.Axis.Y or axis == Constants.Axis.BOTH:
		LevelManager.player_camera.static_factor.y = lerpf(initial_static_factor.y, entering_or_exiting, weight)
		LevelManager.player_camera.global_position.y = lerpf(initial_global_position.y, target.global_position.y, weight)


func _on_easing_restored(_player: Player) -> void:
	target = parent.query(TargetObjectComponent).target_to_node()
