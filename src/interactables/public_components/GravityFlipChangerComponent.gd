class_name GravityFlipChangerComponent
extends Component

enum FlipState {
	DOWN,
	UP,
	FLIP,
}

@export var flip_state: FlipState


func _ready() -> void:
	parent.interacted.connect(set_gravity)
	if not _is_crossing_portal():
		return
	# Player is collision layer 1. The portal hitbox is 384px tall, so it must
	# not also overlap solid ground.
	parent.collision_mask = 1
	add_to_group(&"_gd_gravity_portal")


func set_gravity(body: Node) -> void:
	var player := body as Player
	if player == null or player.dead:
		return
	if bool(parent.get_meta(&"_gd_native_gravity_portal", false)):
		return
	var native := NativeCore.backend()
	if native != null and native.has_method(&"apply_gravity_portal"):
		native.call(&"apply_gravity_portal", player, int(flip_state))
		return
	_apply_gravity_fallback(player)


func _is_crossing_portal() -> bool:
	if "GravityPortal" in str(parent.scene_file_path):
		return true
	var gd_id := int(parent.get_meta(&"gd_object_id", 0))
	return gd_id == 10 or gd_id == 11 or gd_id == 2926


func _apply_gravity_fallback(player: Player) -> void:
	var current := -1 if player.gravity_flip < 0 else 1
	var target := current
	match flip_state:
		FlipState.DOWN:
			target = 1
		FlipState.UP:
			target = -1
		FlipState.FLIP:
			target = -current
	if target == current:
		return
	var local_velocity := player.velocity.rotated(-player.gameplay_rotation)
	local_velocity.y = clampf(-local_velocity.y, -Player.TERMINAL_VELOCITY.y, Player.TERMINAL_VELOCITY.y)
	if absf(local_velocity.y) < 80.0:
		local_velocity.y = target * 180.0
	player.velocity = local_velocity.rotated(player.gameplay_rotation)
	player.gravity_flip = target
	var up := Vector2.UP.rotated(player.gameplay_rotation) * target
	player.up_direction = up
	player.gravity_portal_pending = true
	player.gravity_portal_grace = maxi(player.gravity_portal_grace, 4)
	player.global_position -= up * 8.0
