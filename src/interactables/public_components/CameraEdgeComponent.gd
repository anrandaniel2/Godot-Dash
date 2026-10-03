class_name CameraEdgeComponent
extends Component

enum Mode {
	LIMIT,
	RESET,
}

enum Edge {
	LEFT = 1 << 0,
	TOP = 1 << 1,
	RIGHT = 1 << 2,
	BOTTOM = 1 << 3,
}

@export var mode: Mode
@export_flags("Left", "Top", "Right", "Bottom") var edge: int # Bitflags<Edge>


func _ready() -> void:
	await require([TargetObjectComponent])
	parent.interacted.connect(start)


func _get_property_default_value(property: String) -> Variant:
	match property:
		"mode":
			return Mode.LIMIT
		"edge":
			return 0
		_:
			return null


func start(_player: Player):
	var player_camera: PlayerCamera = LevelManager.player_camera
	var target: Node2D = _resolve_target()
	if mode == Mode.LIMIT and not target:
		if edge != 0:
			Toasts.error("In %s: target is unset" % parent.name)
		return
	if edge & Edge.LEFT:
		match mode:
			Mode.LIMIT:
				player_camera.limit_left = int(target.global_position.x - player_camera.offset.x)
			Mode.RESET:
				player_camera.limit_left = -10000000
	if edge & Edge.TOP:
		match mode:
			Mode.LIMIT:
				player_camera.limit_top = int(target.global_position.y - player_camera.offset.y)
			Mode.RESET:
				player_camera.limit_top = -10000000
	if edge & Edge.RIGHT:
		match mode:
			Mode.LIMIT:
				player_camera.limit_right = int(target.global_position.x - player_camera.offset.x)
			Mode.RESET:
				player_camera.limit_right = 10000000
	if edge & Edge.BOTTOM:
		match mode:
			Mode.LIMIT:
				player_camera.limit_bottom = int(target.global_position.y - player_camera.offset.y)
			Mode.RESET:
				player_camera.limit_bottom = 10000000


## An authored edge trigger names its target node directly; an imported
## Geometry Dash edge trigger instead targets a group, whose first member
## marks the edge position.
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
