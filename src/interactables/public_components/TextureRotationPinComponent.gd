class_name TextureRotationPinComponent
extends Component

@export var pinned: CanvasItem
@export var pin_to_gameplay_rotation := false
@export var pin_scale: bool = true
@export var sprite_scale := Vector2.ONE
@export var keep_aspect: bool = true


func _process(_delta: float) -> void:
	if not pinned:
		return
	if not Engine.is_editor_hint() and LevelManager.player_camera != null:
		if pin_to_gameplay_rotation:
			pinned.set_deferred(&"global_rotation", LevelManager.player.gameplay_rotation)
		else:
			pinned.set_deferred(&"global_rotation", LevelManager.player_camera.rotation)
	else:
		pinned.set_deferred(&"global_rotation", 0.0)
	if not pin_scale:
		return
	var new_scale: Vector2 = parent.scale.abs()
	if keep_aspect:
		var uniform_factor = min(new_scale.x, new_scale.y)
		new_scale = Vector2(uniform_factor, uniform_factor)
	pinned.set_deferred(&"global_scale", new_scale * sprite_scale)
	pinned.set_deferred(&"global_skew", 0.0)
