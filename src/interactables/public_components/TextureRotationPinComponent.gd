class_name TextureRotationPinComponent
extends Component

@export var pinned: CanvasItem
@export var pin_to_gameplay_rotation := false
@export var pin_scale: bool = true
@export var sprite_scale := Vector2.ONE
@export var keep_aspect: bool = true


func _ready() -> void:
	if not pinned:
		set_process(false)
		return
	pinned.visibility_changed.connect(_on_pinned_visibility_changed)
	set_process(pinned.is_visible_in_tree())


func _on_pinned_visibility_changed() -> void:
	var should_process: bool = is_instance_valid(pinned) and pinned.is_visible_in_tree()
	set_process(should_process)
	# The old callback kept the pin current while hidden. Refresh synchronously
	# when it becomes visible so it cannot display a stale transform for a frame.
	if should_process:
		_update_pin()


func _process(_delta: float) -> void:
	_update_pin()


func _update_pin() -> void:
	if not pinned:
		return
	var target_rotation: float = 0.0
	if not Engine.is_editor_hint() and LevelManager.player_camera != null:
		if pin_to_gameplay_rotation:
			target_rotation = LevelManager.player.gameplay_rotation
		else:
			target_rotation = LevelManager.player_camera.rotation
	# These pins commonly run for hundreds of static orbs/pads. Avoid queueing
	# deferred transform writes when the inherited transform already has the
	# exact requested value; the checks preserve precision and still track all
	# live camera/group changes.
	if pinned.global_rotation != target_rotation:
		pinned.set_deferred(&"global_rotation", target_rotation)
	if not pin_scale:
		return
	var new_scale: Vector2 = parent.scale.abs()
	if keep_aspect:
		var uniform_factor: float = minf(new_scale.x, new_scale.y)
		new_scale = Vector2(uniform_factor, uniform_factor)
	var target_scale: Vector2 = new_scale * sprite_scale
	if pinned.global_scale != target_scale:
		pinned.set_deferred(&"global_scale", target_scale)
	if pinned.global_skew != 0.0:
		pinned.set_deferred(&"global_skew", 0.0)
