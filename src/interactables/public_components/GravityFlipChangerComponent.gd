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


func set_gravity(player: Player) -> void:
	if player == null or player.dead:
		return
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
	player.gravity_flip = target
	if _is_crossing_portal():
		# Same idea as the blue gravity pad: the flip has to take effect on the
		# next physics step, after the floor contact would otherwise cancel it.
		# The pad bounces. A portal only needs enough to leave that floor, and
		# keeps airborne speed instead of replacing it.
		player.queue_gravity_portal(target)
		return
	var local_velocity := player.velocity.rotated(-player.gameplay_rotation)
	local_velocity.y = clampf(local_velocity.y, -Player.TERMINAL_VELOCITY.y, Player.TERMINAL_VELOCITY.y)
	player.velocity = local_velocity.rotated(player.gameplay_rotation)


func _is_crossing_portal() -> bool:
	if "GravityPortal" in str(parent.scene_file_path):
		return true
	var gd_id := int(parent.get_meta(&"gd_object_id", 0))
	return gd_id == 10 or gd_id == 11 or gd_id == 2926
