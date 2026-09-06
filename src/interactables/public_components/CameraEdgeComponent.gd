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
	var target: Node2D = parent.query(TargetObjectComponent).target_to_node()
	if mode == Mode.LIMIT and not target:
		Toasts.error("In %s: target is unset" % parent.name)
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
