class_name CameraStaticComponent
extends Component

enum Mode {
	ENTER,
	EXIT,
}

## Group of the [CameraStaticComponent]s that currently pin the camera to their
## target, so a newly started static can stop the previous one's tracking.
const TRACKING_GROUP: StringName = &"_camera_static_tracking"

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

## [code]true[/code] once the enter easing finished: the camera then rigidly
## follows [member target] every physics tick, which is how Geometry Dash's
## static camera tracks a centre group being panned by move triggers.
var _tracking := false


func _ready() -> void:
	await require([TargetObjectComponent, EasingComponent])
	parent.interacted.connect(start)
	parent.query(EasingComponent).progressed.connect(_on_easing_progressed)
	parent.query(EasingComponent).restored.connect(_on_easing_restored)
	# A restart rebuilds the attempt from scratch: no static may keep pinning
	# the camera to a target the fresh attempt hasn't reached yet.
	LevelManager.level_started.connect(_remove_tracking)


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


func _exit_tree() -> void:
	_remove_tracking()


func start(_player: Player) -> void:
	initial_global_position = LevelManager.player_camera.global_position
	initial_static_factor = LevelManager.player_camera.static_factor
	LevelManager.player_camera.static_offset_rotation = LevelManager.player_camera.smoothed_gameplay_rotation
	if mode == Mode.EXIT:
		# Any exit hands the camera back to the player, so no static may keep
		# pinning it to a target afterwards.
		_stop_all_tracking()
	target = _resolve_target()
	if not target and parent.query(TargetGroupComponent) == null:
		Toasts.error("In %s: target is unset" % parent.name)


func _physics_process(_delta: float) -> void:
	if not _tracking or target == null or not is_instance_valid(target):
		return
	var camera := LevelManager.player_camera
	if camera == null:
		return
	if axis == Constants.Axis.X or axis == Constants.Axis.BOTH:
		camera.global_position.x = target.global_position.x
	if axis == Constants.Axis.Y or axis == Constants.Axis.BOTH:
		camera.global_position.y = target.global_position.y


## The target the camera eases towards.
##
## An authored static names the node directly through
## [TargetObjectComponent]. An imported Geometry Dash static instead carries
## its centre group (key 71) in a [TargetGroupComponent] and follows the first
## member of that group - the camera guide technique, where the guide is panned
## around with move triggers. An imported static with no centre group has no
## target at all: the camera simply freezes where it is, like Geometry Dash.
func _resolve_target() -> Node2D:
	var target_object := parent.query(TargetObjectComponent)
	if target_object != null:
		var authored_target: Node2D = target_object.target_to_node()
		if authored_target != null:
			return authored_target
	var group_component := parent.query(TargetGroupComponent)
	if group_component != null:
		var members: Array[Node2D] = group_component.all_members()
		if not members.is_empty():
			return members[0]
	return null


func _on_easing_progressed(player: Player, _weight_delta: float) -> void:
	var entering_or_exiting: float
	match mode:
		Mode.ENTER:
			entering_or_exiting = 1.0
		Mode.EXIT:
			entering_or_exiting = 0.0
	var weight: float = parent.query(EasingComponent).weights[player]
	if axis == Constants.Axis.X or axis == Constants.Axis.BOTH:
		LevelManager.player_camera.static_factor.x = lerpf(initial_static_factor.x, entering_or_exiting, weight)
		if target:
			LevelManager.player_camera.global_position.x = lerpf(initial_global_position.x, target.global_position.x, weight)
	if axis == Constants.Axis.Y or axis == Constants.Axis.BOTH:
		LevelManager.player_camera.static_factor.y = lerpf(initial_static_factor.y, entering_or_exiting, weight)
		if target:
			LevelManager.player_camera.global_position.y = lerpf(initial_global_position.y, target.global_position.y, weight)
	if mode == Mode.ENTER and weight >= 1.0 and target != null:
		_begin_tracking()


## Once the enter easing finishes, this static owns the camera; any other
## static still tracking is stopped so the two can't fight over the position.
func _begin_tracking() -> void:
	_stop_all_tracking()
	_tracking = true
	add_to_group(TRACKING_GROUP)


func _stop_all_tracking() -> void:
	for node: Node in get_tree().get_nodes_in_group(TRACKING_GROUP):
		if node is CameraStaticComponent:
			node._remove_tracking()


func _remove_tracking() -> void:
	_tracking = false
	if is_in_group(TRACKING_GROUP):
		remove_from_group(TRACKING_GROUP)


func _on_easing_restored(_player: Player) -> void:
	target = _resolve_target()
