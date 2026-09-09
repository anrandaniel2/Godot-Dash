class_name Player
extends CharacterBody2D

signal hit_ceiling(player: Player)

enum Gamemode {
	CUBE,
	SHIP,
	UFO,
	BALL,
	WAVE,
	ROBOT,
	SPIDER,
	SWING,
}

enum ClickBufferState {
	NOT_HOLDING,
	BUFFERING,
	JUMPING,
	BUFFER_USED,
}

enum PlayerScale {
	MINI,
	NORMAL,
	BIG,
}

#region Constants
const GRAVITY: float = 10600
const SPEED := Vector2(1250.0, 2395.0)
const SPEED_MINI := Vector2(1250.0, 1600.0)
const SPEED_BIG := Vector2(1250.0, 3000.0)
const TERMINAL_VELOCITY := Vector2(0.0, 3000.0)
const FLY_TERMINAL_VELOCITY := Vector2(0.0, 1800.0)
const FLY_GRAVITY_MULTIPLIER: float = 0.5
const UFO_GRAVITY_MULTIPLIER: float = 0.7
const SPIDER_GRAVITY_MULTIPLIER: float = 0.65
const PLAYER_SCALE_WAVE := Vector2(0.6, 0.6)
const PLAYER_SCALE_MINI := Vector2(0.6, 0.6)
const PLAYER_SCALE_NORMAL := Vector2.ONE
const PLAYER_SCALE_BIG := Vector2(1.4, 1.4)
const WAVE_TRAIL_WIDTH: float = 50.0
const WAVE_TRAIL_LENGTH: int = 250
const SPIDER_TRAIL: PackedScene = preload("res://scenes/components/game_components/SpiderTrail.tscn")
const DASH_BOOM: PackedScene = preload("res://scenes/components/game_components/DashBoom.tscn")
const GROUND_HIT_PARTICLE: PackedScene = preload("uid://c3pbl5e1vp2ck")
const UFO_PARTICLE: PackedScene = preload("uid://nt6jgd7lk03t")
const ICON_LERP_FACTOR: float = 0.5
const SHIP_ROTATION_LERP_FACTOR: float = 0.15
const PLATFORMER_ACCELERATION: float = 5.0
const ENSURE_VELOCITY_REDIRECT_SAFE_MARGIN: float = 2.0
const SPIDER_BOUNCE_MULTIPLIER: float = 0.65
const ROBOT_FIRE_SCALE: float = 0.9
const DEFAULT_COLLISION_MASK: int = 1 << 1 | 1 << 3 | 1 << 4 | 1 << 5 | 1 << 6
const USED_ACTIONS: Array[String] = ["jump", "move_left", "move_right", "platformer_wave_down", "practice_create_checkpoint", "practice_remove_checkpoint"]
#endregion

#region Bit Flags
const EVALUATE_CLICK_BUFFER := 1
#endregion

@export var displayed_gamemode: Gamemode:
	set(value):
		displayed_gamemode = value
		update_player_scale(false)
		for icon: PlayerIcon in $Icon.get_children():
			icon.visible = (
					icon.gamemode == value
					and (
							icon.platformer == PlayerIcon.PlatformerState.BOTH
							or (icon.platformer == PlayerIcon.PlatformerState.PLATFORMER_ONLY and (LevelManager.platformer or speed_multiplier == 0.0))
							or (icon.platformer == PlayerIcon.PlatformerState.SIDESCROLLER_ONLY and not (LevelManager.platformer or speed_multiplier == 0.0))
					)
			)
@export var internal_gamemode: Gamemode:
	set(value):
		internal_gamemode = value
		if internal_gamemode == Gamemode.WAVE:
			$KillColliderSolid/KillColliderSolidHitbox.shape.size = Vector2.ONE * 126.0
		else:
			$KillColliderSolid/KillColliderSolidHitbox.shape.size = Vector2.ONE * 32.0
@export var default_collider: RectangleShape2D
@export var slope_collider: CircleShape2D
@export var spider_animation_tree: AnimationTree
@export var robot_animation_tree: AnimationTree

# Public
var dead: bool = false
var coyote_time: float = 0.0
var gameplay_rotation_degrees: float = 0.0
var gameplay_rotation: float:
	get():
		return deg_to_rad(gameplay_rotation_degrees)
	set(value):
		gameplay_rotation_degrees = rad_to_deg(value)
var player_scale: PlayerScale = PlayerScale.NORMAL
var can_hit_ceiling: bool
var jump_hold_disabled: bool
var speed_multiplier: float = 1.0
var gravity_flip: int = 1
var gravity_multiplier: float = 1.0
var horizontal_direction: int = 1
var speed: Vector2:
	get():
		match player_scale:
			PlayerScale.MINI:
				return SPEED_MINI
			PlayerScale.NORMAL:
				return SPEED
			PlayerScale.BIG:
				return SPEED_BIG
			_:
				return SPEED
var dash_control: FireDashComponent = null
var speed_0_portal_control: Interactable = null
var slope_velocity: Vector2
var last_collision: KinematicCollision2D
var floor_angle_history: Array[float]
var floor_angle_average: float
var sprite_floor_angle: float
var dual_index: int
# Allow Ceiling Hit blocks can stack, this avoids their effect being disabled
# in the case of a double collision, which would happen with a bool.
var allow_ceiling_hit_count: int:
	set(value):
		allow_ceiling_hit_count = max(value, 0)
var allow_wave_slide_count: int:
	set(value):
		allow_wave_slide_count = max(value, 0)
var no_auto_checkpoints_count: int:
	set(value):
		no_auto_checkpoints_count = max(value, 0)

# Queues
var orb_queue: Array[OrbInteractable] = []
var colliding_pad: PadInteractable = null

# Replay
var replay_physics_tick: int = 0
var replay: Replay = Replay.new()
var in_replay: bool = false

var in_end_level_animation: bool = false:
	set(value):
		in_end_level_animation = value
		if value:
			# Stop particles
			%GroundParticles.emitting = false
			stop_dash()

# Private
var _spider_dash_frames: int = 0
var _slope_exit_velocity_frames: int = 0
var _click_buffer_state: ClickBufferState = ClickBufferState.NOT_HOLDING
var _is_flying_gamemode: bool = false
var _wave_rotation_goal: float = 0.0
var _deferred_velocity_redirect: bool = false
var _spider_state_machine: AnimationNodeStateMachinePlayback = null
var _robot_state_machine: AnimationNodeStateMachinePlayback = null
var _snap_sprite_rotation: bool = false
var _snap_sprite_rotation_frames: int = 0
var _fire_sprite_time: float = 0.0
var _just_spawned: bool = false

@onready var last_automatic_checkpoint_position: Vector2 = position


func _ready() -> void:
	refresh_textures()
	set_meta(Constants.HSV_WATCHER_META, $"HSVWatcher")
	platform_on_leave = PlatformOnLeave.PLATFORM_ON_LEAVE_ADD_UPWARD_VELOCITY if not LevelManager.platformer else PlatformOnLeave.PLATFORM_ON_LEAVE_ADD_VELOCITY
	_spider_state_machine = spider_animation_tree["parameters/playback"]
	_robot_state_machine = robot_animation_tree["parameters/playback"]
	robot_animation_tree.active = true
	if dual_index == 0:
		LevelManager.player = self
	else:
		LevelManager.player_duals.append(self)
	_set_particles_visibility.call_deferred()
	if not Editor.in_editor:
		reset_replay.call_deferred()
	for action in USED_ACTIONS:
		InputUtils.add_action(action)


func _physics_process(delta: float) -> void:
	if not _should_process():
		return

	# Get velocity
	up_direction = Vector2.UP.rotated(gameplay_rotation) * gravity_flip
	var jump_state: int = _get_jump_state()

	if get_viewport().get_window().has_focus():
		InputUtils.update()

	# Direction queries can touch input/replay state and used to run repeatedly
	# in one 240 Hz tick. Sample once so simulation and recording see the same
	# value while avoiding redundant InputMap work.
	var tick_direction: int = get_direction()
	if not in_replay:
		var replay_jump_state: int = int(InputUtils.is_action_pressed(&"jump")) if not InputUtils.is_action_pressed(&"platformer_wave_down") else -1
		replay.data.append(PackedByteArray([replay_jump_state, tick_direction]))

	velocity = _compute_velocity(delta, velocity, tick_direction, jump_state, $GroundCollider.shape is CircleShape2D)

	# Slope collision resolution
	# Reset collision shape and set it back to the slope collider if needed
	$GroundCollider.shape = default_collider
	$GroundCollider.rotation = gameplay_rotation
	$CornerSnapping/GroundSnapCast.shape = default_collider
	$SolidOverlapCheck/SolidOverlapCheckCollider.shape = default_collider
	last_collision = move_and_collide(speed.y * Vector2.DOWN * delta, true)
	_handle_collision(last_collision, true)

	for i in range(4):
		last_collision = move_and_collide(velocity * delta, true)
		var had_collision := last_collision != null
		_handle_collision(last_collision, i != 0)
		# Collide down with solids so the wave can crash into them.
		if internal_gamemode == Gamemode.WAVE and allow_wave_slide_count == 0:
			last_collision = move_and_collide(speed.y * Vector2.DOWN * delta, true)
			had_collision = had_collision or last_collision != null
			_handle_collision(last_collision, true)
		# Refinement only has work after a hit. In normal airborne movement the
		# old loop submitted four identical test motions at 240 Hz.
		if not had_collision:
			break

	# Apply movement
	move_and_slide()

	# Sprite updates
	_update_sprites_rotation(delta, jump_state, tick_direction)
	%GroundParticles.emitting = is_on_floor() and not is_zero_approx(velocity.rotated(-gameplay_rotation).x) and not dash_control
	if is_on_floor() and not dash_control or displayed_gamemode == Gamemode.WAVE:
		%Trail.add_points = false
	if displayed_gamemode in [Gamemode.SHIP, Gamemode.SWING, Gamemode.UFO]:
		%Trail.add_points = true
	if %Trail.add_points:
		%Trail.material.set_shader_parameter(&"bias", float(%Trail.get_point_count()) / float(%Trail.length) * 1.2)

	match displayed_gamemode:
		Gamemode.SPIDER:
			_update_spider_state_machine(jump_state)
		Gamemode.ROBOT:
			_update_robot_fire(delta, jump_state)
			_update_robot_state_machine(jump_state)
		Gamemode.SWING:
			_update_swing_fire(delta)
	_update_wave_trail(delta)

	if not is_on_floor():
		$IdleAltAnimationCooldown.stop()
	if is_on_floor() and displayed_gamemode in [Gamemode.SPIDER, Gamemode.ROBOT] and $IdleAltAnimationCooldown.is_stopped():
		$IdleAltAnimationCooldown.start(randf_range(15.0, 30.0))

	# 0x speed portal position nudge
	if speed_0_portal_control:
		var rotation_local_global_position = global_position.rotated(-gameplay_rotation)
		var rotation_local_portal_global_position = speed_0_portal_control.global_position.rotated(-gameplay_rotation)
		var rotation_local_velocity = velocity.rotated(-gameplay_rotation)
		# Update ship icon by running `displayed_gamemode` setter
		global_position = Vector2(
			rotation_local_global_position.lerp(rotation_local_portal_global_position, 0.3 * delta * 60).x,
			rotation_local_global_position.y,
		).rotated(gameplay_rotation)
		velocity = Vector2(
			0.0,
			rotation_local_velocity.y,
		).rotated(gameplay_rotation)
		if is_equal_approx(rotation_local_global_position.x, rotation_local_portal_global_position.x):
			speed_0_portal_control = null

	if _snap_sprite_rotation:
		if _snap_sprite_rotation_frames > 0:
			_snap_sprite_rotation_frames -= 1
		elif _snap_sprite_rotation_frames == 0:
			_snap_sprite_rotation = false

	if LevelManager.level_playing:
		_handle_checkpoint_placement()

	replay_physics_tick += 1


func _exit_tree() -> void:
	if is_queued_for_deletion():
		$Icon/Robot/RobotSprites.set_modification_stack(null)
	for action in USED_ACTIONS:
		InputUtils.remove_action(action)


func refresh_textures() -> void:
	if $DebugTrail:
		refresh_debug_trail()
	$DeathEffect.sprite_frames.clear(&"default")
	for icon in DirAccess.open(Config.icon_paths[PreviewIcon.Icon.DEATH_EFFECT]).get_files():
		if icon.contains(".import"):
			continue
		var frame: Texture2D = load(Config.icon_paths[PreviewIcon.Icon.DEATH_EFFECT].path_join(icon))
		$DeathEffect.sprite_frames.add_frame(&"default", frame)
	%Trail.texture = load(Config.icon_paths[PreviewIcon.Icon.TRAIL])
	%Trail.width = %Trail.texture.get_width()
	%WaveTrail.default_color = Config.primary_color
	var empty_frame := Texture2D.new()
	$DeathEffect.sprite_frames.add_frame(&"default", empty_frame)
	$DeathEffect.frame = $DeathEffect.sprite_frames.get_frame_count(&"default") - 1
	for player_icon: PlayerIcon in $Icon.get_children():
		player_icon.refresh_texture()
	%GroundParticles.modulate = Config.secondary_color
	$DashFlame.modulate = Config.secondary_color
	$DashParticles.modulate = Config.secondary_color
	$DeathParticles.modulate = Config.secondary_color


func refresh_debug_trail() -> void:
	var enable_trail: bool = Config.draw_debug_overlays or (Config.editor_trail and Editor.in_editor)
	$DebugTrail.visible = enable_trail
	$DebugTrail.add_points = enable_trail
	$DebugTrail.process_mode = Node.PROCESS_MODE_INHERIT if enable_trail else Node.PROCESS_MODE_DISABLED


func reset() -> void:
	show()
	rotation = 0.0
	# Cancel death animation
	$DeathAnimator.stop()
	$DeathParticles.restart()
	$DeathParticles.emitting = false
	$DeathEffect.stop()
	$DeathEffect.frame = $DeathEffect.sprite_frames.get_frame_count(&"default") - 1
	# Reset trails
	$WaveTrail.clear_points()
	%Trail.clear_points()
	# Reset icon
	for icon_sprite: Node2D in $Icon.get_children():
		icon_sprite.rotation = 0.0
		icon_sprite.scale = Vector2.ONE
	$SpiderCast.rotation = 0.0
	# Reset dash
	$DashFlame.stop()
	$DashFlame.hide()
	$DashParticles.restart()
	$DashParticles.emitting = false
	NodeUtils.get_children_of_type(self, OneShotAnimatedSprite).map(NodeUtils.free_node)
	NodeUtils.get_children_of_type(self, SpiderTrail).map(NodeUtils.free_node)
	# Reset members
	dead = false
	$Icon.show()
	$Icon.transform = Transform2D.IDENTITY
	$CornerSnapping.transform = Transform2D.IDENTITY
	# Reset particles
	NodeUtils.free_children(%GroundParticles)
	%GroundParticles.restart()
	%GroundParticles.emitting = false
	for icon: PlayerIcon in $Icon.get_children():
		icon.reset()
	gameplay_rotation = 0.0
	velocity = Vector2.ZERO
	player_scale = PlayerScale.NORMAL
	can_hit_ceiling = false
	jump_hold_disabled = false
	speed_multiplier = 1.0
	gravity_flip = 1
	gravity_multiplier = 1.0
	horizontal_direction = 1
	dash_control = null
	speed_0_portal_control = null
	slope_velocity = Vector2.ZERO
	last_collision = null
	floor_angle_history.clear()
	floor_angle_average = 0.0
	sprite_floor_angle = 0.0
	allow_ceiling_hit_count = 0
	allow_wave_slide_count = 0
	no_auto_checkpoints_count = 0
	in_end_level_animation = false
	orb_queue.clear()
	colliding_pad = null
	_spider_dash_frames = 0
	_slope_exit_velocity_frames = 0
	_click_buffer_state = ClickBufferState.NOT_HOLDING
	_is_flying_gamemode = false
	_wave_rotation_goal = 0.0
	_deferred_velocity_redirect = false
	_snap_sprite_rotation = false
	_snap_sprite_rotation_frames = 0
	_fire_sprite_time = 0.0

	set_collisions_enabled(true)

	_spider_state_machine.travel(&"End")
	_robot_state_machine.travel(&"End")
	$Icon/Spider/SpiderAnimation.play(&"RESET")
	$Icon/Robot/RobotAnimation.play(&"RESET")
	robot_animation_tree.active = false
	_update_swing_fire(20)
	_update_robot_fire(20, -1)
	update_player_scale(false)
	_set_particles_visibility.call_deferred()
	if not Editor.in_editor:
		reset_replay.call_deferred()


func defer_snap_sprite_rotation() -> void:
	_snap_sprite_rotation = true
	_snap_sprite_rotation_frames = 16


func update_player_scale(tweened: bool) -> void:
	var player_scale_value: Vector2
	match player_scale:
		PlayerScale.MINI:
			player_scale_value = PLAYER_SCALE_MINI
		PlayerScale.NORMAL:
			player_scale_value = PLAYER_SCALE_NORMAL
		PlayerScale.BIG:
			player_scale_value = PLAYER_SCALE_BIG
	if displayed_gamemode == Gamemode.WAVE:
		player_scale_value *= PLAYER_SCALE_WAVE
	if not tweened:
		scale = player_scale_value
		if not is_node_ready():
			await ready
		%Trail.width = %Trail.texture.get_width() * scale.y
		return
	var tween: Tween = create_tween() \
			.set_parallel() \
			.set_ease(Tween.EASE_OUT) \
			.set_trans(Tween.TRANS_BACK)
	tween.tween_property(self, ^"scale", player_scale_value, 0.25)
	tween.tween_property(%Trail, ^"width", %Trail.texture.get_width() * scale.y, 0.25)


func place_checkpoint() -> CheckpointPlacementBuilder:
	return CheckpointPlacementBuilder.new(self)


func set_collisions_enabled(enabled: bool) -> void:
	if enabled:
		collision_mask = DEFAULT_COLLISION_MASK
		$KillColliderSolid.process_mode = Node.PROCESS_MODE_INHERIT
		$KillColliderRectangularHazard.process_mode = Node.PROCESS_MODE_INHERIT
		$KillColliderCircularHazard.process_mode = Node.PROCESS_MODE_INHERIT
	else:
		collision_mask = 0
		$KillColliderSolid.process_mode = Node.PROCESS_MODE_DISABLED
		$KillColliderRectangularHazard.process_mode = Node.PROCESS_MODE_DISABLED
		$KillColliderCircularHazard.process_mode = Node.PROCESS_MODE_DISABLED


func stop_dash() -> void:
	if not dash_control:
		return
	$DashParticles.emitting = false
	dash_control.stop(self)
	dash_control = null


func on_level_start() -> void:
	robot_animation_tree.active = true
	_robot_state_machine.start(&"idle" if LevelManager.platformer else &"walk")
	clear_debug_trail()
	_just_spawned = true
	await get_tree().process_frame
	_just_spawned = false


func clear_debug_trail() -> void:
	$DebugTrail.clear_points()


func get_direction() -> int:
	var direction: int
	if LevelManager.platformer:
		if _is_playing_back_replay():
			direction = replay.get_direction(replay_physics_tick)
		else:
			direction = int(InputUtils.get_axis(&"move_left", &"move_right"))
		if direction != 0:
			horizontal_direction = direction
	else:
		direction = horizontal_direction
	return direction


func get_spider_trail_global_position() -> Vector2:
	return $Icon/Spider/SpiderTrailSpawnPoint.global_position


func has_just_spawned() -> bool:
	return _just_spawned


func _should_process() -> bool:
	return LevelManager.level_playing and not dead and not in_end_level_animation


func _handle_collision(collision: KinematicCollision2D, is_refine_iteration: bool) -> void:
	if not collision:
		return
	var collision_angle: float = collision.get_angle(up_direction)
	var is_floor: bool = collision_angle <= deg_to_rad(10.0)
	var is_ceiling: bool = collision_angle >= deg_to_rad(180.0 - 10.0)
	var is_wall: bool = collision_angle > floor_max_angle and collision_angle < PI - floor_max_angle
	var is_slope: bool = not is_floor and not is_ceiling and not is_wall
	var is_lower_corner: bool = $CornerSnapping/GroundCast.is_colliding() and not $CornerSnapping/InvalidCornerCast.is_colliding()
	var should_snap: bool = is_lower_corner and is_wall and not is_slope and internal_gamemode != Gamemode.WAVE

	var is_lethal_ceiling_hit: bool = is_ceiling and allow_ceiling_hit_count == 0 and internal_gamemode not in [Gamemode.SHIP, Gamemode.UFO, Gamemode.SWING]
	if (
			not should_snap
			and not LevelManager.platformer
			and (
					(is_wall or is_lethal_ceiling_hit)
					or (internal_gamemode == Gamemode.WAVE and allow_wave_slide_count == 0)
			)
	):
		var collider := collision.get_collider() as CollisionObject2D
		if collider != null and collider.collision_layer & 1 << 1:
			if LevelPhysics.is_shared_body(collider):
				# The level's shared static body: collision layers are per-body,
				# so a single block can't be re-layered. Disable the exact shape
				# the player hit instead - a dashing spider passes through, and
				# any other mode dies through the same path the kill collider
				# uses. LevelPhysics.prepare() re-enables the shape on the next
				# attempt.
				var shape := _collided_shared_shape(collision)
				if shape != null:
					shape.set_deferred(&"disabled", true)
				if _spider_dash_frames == 0:
					$DeathAnimator.play("DeathAnimation")
			else:
				# Per-object body (kept for trigger-animated or pushable
				# objects): move it to the solid_overlap_check layer (1 << 9)
				# so it stops blocking, the kill collider finishes the job, and
				# SolidOverlapCheck's body_exited restores it - as before.
				collider.collision_layer = 1 << 9
				var hitbox := collider.get_node_or_null(^"Hitbox")
				if hitbox is CollisionShape2D:
					hitbox.debug_color.s = 0.0 # DEBUG: Hardcoded name for hitbox color
	if is_ceiling and allow_ceiling_hit_count > 0:
		hit_ceiling.emit(self)
	if is_slope:
		$GroundCollider.shape = slope_collider
		$SolidOverlapCheck/SolidOverlapCheckCollider.shape = slope_collider
		$CornerSnapping/GroundSnapCast.shape = slope_collider
	if should_snap:
		var down_shapecast: ShapeCast2D = $CornerSnapping/GroundSnapCast
		down_shapecast.force_shapecast_update()
		if down_shapecast.is_colliding():
			global_position = global_position.rotated(-gameplay_rotation)
			global_position.y = down_shapecast.get_collision_point(0).y - (64.0 * scale.y + 2.0) * gravity_flip
			global_position = global_position.rotated(gameplay_rotation)
	if not is_refine_iteration:
		if is_floor and not dash_control and not _just_spawned:
			var ground_hit_particles: GPUParticles2D = GROUND_HIT_PARTICLE.instantiate()
			ground_hit_particles.modulate = Config.secondary_color
			%GroundParticles.add_child(ground_hit_particles)


## The CollisionShape2D on the level's shared physics body that a collision
## report hit, resolved by the collider's shape index. Null when the collider
## has no shape (or isn't a shared body).
func _collided_shared_shape(collision: KinematicCollision2D) -> CollisionShape2D:
	var body := collision.get_collider() as CollisionObject2D
	if body == null:
		return null
	var shape_index := collision.get_collider_shape_index()
	var owner_id := body.shape_find_owner(shape_index)
	if owner_id == -1:
		return null
	var shape := body.shape_owner_get_owner(owner_id)
	return shape as CollisionShape2D


func _is_playing_back_replay() -> bool:
	return in_replay and replay.data.size() > replay_physics_tick


func reset_replay() -> void:
	if LevelManager.practice_mode:
		return
	replay_physics_tick = 0
	await get_tree().process_frame
	if not in_replay:
		replay.reset()
		replay.level_name = LevelManager.current_level.name
	Input.action_release(&"move_left")
	Input.action_release(&"move_right")
	Input.action_release(&"jump")
	Input.action_release(&"platformer_wave_down")


func _get_floor_angle_signed(last_slide: bool, jump_state: int) -> float:
	var floor_normal: Vector2
	if last_slide:
		floor_normal = get_last_slide_collision().get_normal()
	else:
		floor_normal = get_floor_normal()
	var floor_angle: float
	if _is_flying_gamemode and is_on_ceiling() and jump_state == 1:
		var local_up_direction: Vector2 = Vector2.DOWN.rotated(gameplay_rotation) * sign(gravity_flip)
		floor_angle = snappedf(rad_to_deg(floor_normal.angle_to(local_up_direction)), 0.01)
	else:
		floor_angle = snappedf(rad_to_deg(floor_normal.angle_to(up_direction)), 0.01)
	# Iron out jittery angles
	if abs(floor_angle - floor_angle_average) > 0.5:
		floor_angle_history.clear()
	if len(floor_angle_history) > 10:
		floor_angle_history.pop_front()
	floor_angle_history.append(floor_angle)
	floor_angle_average = ArrayUtils.transform(floor_angle_history, ArrayUtils.Transformation.MEAN)
	floor_angle_average = snappedf(floor_angle_average, 0.01)
	if is_equal_approx(abs(floor_angle), 90.0):
		return 0.0
	return deg_to_rad(floor_angle)


func _get_jump_state() -> int:
	var jump_state: int
	var is_jump_pressed: bool = InputUtils.is_action_pressed(&"jump") if not _is_playing_back_replay() else replay.pressing_jump(replay_physics_tick)
	var is_jump_just_pressed: bool = InputUtils.is_action_just_pressed(&"jump") if not _is_playing_back_replay() else replay.just_pressed_jump(replay_physics_tick)
	var is_jump_just_released: bool = InputUtils.is_action_just_released(&"jump") if not _is_playing_back_replay() else replay.just_released_jump(replay_physics_tick)
	var is_down_pressed: bool = InputUtils.is_action_pressed(&"platformer_wave_down") if not _is_playing_back_replay() else replay.pressing_down(replay_physics_tick)

	if (
			_click_buffer_state == ClickBufferState.NOT_HOLDING
			and is_jump_just_pressed
			and not (is_on_floor() or is_on_ceiling())
			and internal_gamemode != Gamemode.SHIP and internal_gamemode != Gamemode.SWING and internal_gamemode != Gamemode.WAVE
	):
		_click_buffer_state = ClickBufferState.BUFFERING
	if _click_buffer_state == ClickBufferState.BUFFERING and not orb_queue.is_empty():
		_click_buffer_state = ClickBufferState.JUMPING
	if is_jump_just_released or ((is_on_floor() or is_on_ceiling()) and not InputUtils.is_action_pressed(&"jump")):
		_click_buffer_state = ClickBufferState.NOT_HOLDING

	if jump_hold_disabled:
		jump_state = -1
		if is_jump_just_pressed and (is_on_floor() or is_on_ceiling() or coyote_time > 0):
			jump_hold_disabled = false
	if jump_hold_disabled:
		return -1
	if internal_gamemode == Gamemode.CUBE:
		jump_state = 1 if is_jump_pressed and (is_on_floor() or coyote_time > 0) else -1
	elif internal_gamemode == Gamemode.ROBOT:
		if (
				(is_jump_just_pressed and (is_on_floor() or coyote_time > 0) and orb_queue.is_empty())
				or (_click_buffer_state == ClickBufferState.BUFFERING and is_on_floor())
		):
			$RobotTimer.start(0.25)
		if is_on_ceiling() or is_jump_just_released or colliding_pad:
			$RobotTimer.stop()
		jump_state = 1 if is_jump_pressed and $RobotTimer.time_left > 0.0 else -1
	elif internal_gamemode == Gamemode.SHIP or (internal_gamemode == Gamemode.WAVE and not LevelManager.platformer):
		jump_state = 1 if is_jump_pressed else -1
	elif internal_gamemode == Gamemode.WAVE and LevelManager.platformer:
		jump_state = 0
		if is_jump_pressed:
			jump_state += 1
		if is_down_pressed:
			jump_state -= 1
	elif internal_gamemode == Gamemode.UFO or internal_gamemode == Gamemode.SWING:
		jump_state = 1 if is_jump_just_pressed else -1
	elif internal_gamemode == Gamemode.BALL or internal_gamemode == Gamemode.SPIDER:
		jump_state = 1 if (
				(is_jump_just_pressed and (is_on_floor() or is_on_ceiling()))
				or (_click_buffer_state == ClickBufferState.BUFFERING and is_on_floor())
		) else -1

	if _click_buffer_state == ClickBufferState.BUFFERING and (is_on_floor() or is_on_ceiling()):
		_click_buffer_state = ClickBufferState.NOT_HOLDING

	var hovered_control: Control = get_viewport().gui_get_hovered_control()
	if hovered_control and hovered_control is not EditorViewport:
		return -1 if not (LevelManager.platformer and internal_gamemode == Gamemode.WAVE) else 0
	return jump_state


func _compute_velocity(
		delta: float,
		previous_velocity: Vector2,
		direction: int,
		jump_state: int,
		was_sliding_on_slope: bool,
) -> Vector2:
	var local_velocity: Vector2 = previous_velocity.rotated(-gameplay_rotation)
	_is_flying_gamemode = (internal_gamemode == Gamemode.SHIP or internal_gamemode == Gamemode.SWING or internal_gamemode == Gamemode.WAVE)

	if _spider_dash_frames > 0:
		_spider_dash_frames -= 1

	if _slope_exit_velocity_frames > 0:
		_slope_exit_velocity_frames -= 1

	#region Slope physics
	if was_sliding_on_slope and get_last_slide_collision():
		var floor_angle := _get_floor_angle_signed(true, jump_state)
		# 90° collision warp prevention
		if absf(sin(floor_angle)) < sin(floor_max_angle):
			slope_velocity.y = tan(-floor_angle) * abs(local_velocity.x) * direction
			_slope_exit_velocity_frames = 4
	#endregion

	if (internal_gamemode == Gamemode.SWING or internal_gamemode == Gamemode.BALL) and jump_state == 1 and orb_queue.is_empty():
		gravity_flip *= -1

	$GroundCollider.rotation = gameplay_rotation
	$SolidOverlapCheck.rotation = gameplay_rotation
	$KillColliderSolid.rotation = gameplay_rotation
	$KillColliderRectangularHazard.rotation = gameplay_rotation
	$KillColliderCircularHazard.rotation = gameplay_rotation

	#region Apply Gravity
	if not dash_control:
		if internal_gamemode == Gamemode.SHIP:
			local_velocity.y += GRAVITY * delta * gravity_flip * gravity_multiplier * jump_state * -1 * FLY_GRAVITY_MULTIPLIER
			local_velocity.y = clamp(local_velocity.y, -FLY_TERMINAL_VELOCITY.y, FLY_TERMINAL_VELOCITY.y)
		elif internal_gamemode == Gamemode.SWING:
			local_velocity.y += GRAVITY * delta * gravity_flip * gravity_multiplier * FLY_GRAVITY_MULTIPLIER
			local_velocity.y = clamp(local_velocity.y, -FLY_TERMINAL_VELOCITY.y, FLY_TERMINAL_VELOCITY.y)
		elif internal_gamemode == Gamemode.WAVE:
			local_velocity.y = SPEED.x * gravity_flip * gravity_multiplier * jump_state * -1
			if speed_multiplier > 0:
				local_velocity.y *= speed_multiplier
			if player_scale == PlayerScale.MINI:
				local_velocity.y *= 2
			elif player_scale == PlayerScale.BIG:
				local_velocity.y *= 0.5
		elif internal_gamemode == Gamemode.SPIDER:
			local_velocity.y += GRAVITY * delta * gravity_flip * gravity_multiplier * jump_state * -1 * SPIDER_GRAVITY_MULTIPLIER
			local_velocity.y = clamp(local_velocity.y, -TERMINAL_VELOCITY.y, TERMINAL_VELOCITY.y)
		elif not is_on_floor():
			if internal_gamemode == Gamemode.UFO:
				local_velocity.y += GRAVITY * delta * gravity_flip * gravity_multiplier * UFO_GRAVITY_MULTIPLIER
			else:
				local_velocity.y += GRAVITY * delta * gravity_flip * gravity_multiplier
	#endregion

	var flying_gamemode_slope_boost: bool = internal_gamemode in [Gamemode.SHIP, Gamemode.SWING] and (
			(is_on_ceiling() and jump_state >= 0)
			or (
					is_on_floor()
					and get_last_slide_collision() != null
					and _get_floor_angle_signed(true, jump_state) != 0.0
					and direction != 0
					and jump_state == 1
			)
	)
	var isnt_jumping: bool = is_on_floor() and jump_state <= 0 and not _deferred_velocity_redirect

	if not colliding_pad and flying_gamemode_slope_boost or isnt_jumping:
		local_velocity.y = slope_velocity.y

	# Robot
	if jump_state == 1 and $RobotTimer.time_left > 0.0 and internal_gamemode == Gamemode.ROBOT:
		local_velocity.y = SPEED.x * gravity_flip * -1

	#region Apply pads velocity
	if colliding_pad:
		local_velocity = _handle_velocity_interactable(local_velocity, colliding_pad, direction)
		%Trail.add_points = true
	#endregion

	#region Handle jump.
	var is_instant_jump: bool = internal_gamemode in [Gamemode.SPIDER, Gamemode.BALL, Gamemode.UFO, Gamemode.CUBE]
	if is_instant_jump and jump_state == 1 and not colliding_pad and orb_queue.is_empty():
		match internal_gamemode:
			Gamemode.SPIDER:
				_update_spider_cast_rotation()
				var dash_data: PackedFloat64Array = _get_spider_dash_data()
				var dash_height: float = dash_data[0]
				var displacement: Vector2 = Vector2.UP.rotated(gameplay_rotation) * dash_height
				position += displacement
				var trail: SpiderTrail = SPIDER_TRAIL.instantiate()
				trail.start.call_deferred(self, displacement)
				add_child(trail)
				gravity_flip *= -1
				# Force slope collider if needed
				allow_ceiling_hit_count += 1
				# Force up direction update in order for _handle_collision to work properly
				up_direction = Vector2.UP.rotated(gameplay_rotation) * sign(gravity_flip)
				last_collision = move_and_collide(displacement.normalized() * Constants.CELL_SIZE, true)
				$GroundCollider.rotation = gameplay_rotation
				_handle_collision(last_collision, false)
				allow_ceiling_hit_count -= 1
				# Snap velocity to the ground
				var floor_angle: float = dash_data[1]
				local_velocity.y = tan(-floor_angle - gameplay_rotation) * abs(local_velocity.x) * direction
				slope_velocity = Vector2.ZERO
				_spider_dash_frames = 4
				defer_snap_sprite_rotation()
			Gamemode.BALL:
				local_velocity.y = speed.y * gravity_flip * 0.5
			Gamemode.UFO:
				local_velocity.y = -speed.y * gravity_flip * UFO_GRAVITY_MULTIPLIER
			Gamemode.CUBE:
				local_velocity.y = -speed.y * gravity_flip
	#endregion

	if not LevelManager.platformer or internal_gamemode == Gamemode.WAVE:
		if direction:
			local_velocity.x = direction * speed.x * speed_multiplier
		else:
			local_velocity.x = 0
	else:
		if direction:
			local_velocity.x = move_toward(
				local_velocity.x,
				direction * speed.x * speed_multiplier,
				speed.x * delta * speed_multiplier * PLATFORMER_ACCELERATION,
			)
		else:
			local_velocity.x = move_toward(
				local_velocity.x,
				0.0,
				speed.x * delta * speed_multiplier * PLATFORMER_ACCELERATION,
			)

	#region Apply orbs velocity
	if (
			not orb_queue.is_empty()
			and (
					_click_buffer_state == ClickBufferState.JUMPING
					or InputUtils.is_action_just_pressed(&"jump")
			)
	):
		var colliding_orb: OrbInteractable = orb_queue.pop_front()
		_click_buffer_state = ClickBufferState.BUFFER_USED
		colliding_orb.interacted.emit(self)
		local_velocity = _handle_velocity_interactable(local_velocity, colliding_orb, direction)
		if not colliding_orb.has(SingleUsageComponent):
			orb_queue.append(colliding_orb)
		%Trail.add_points = true
	#endregion

	#region Dash orb velocity
	if dash_control:
		local_velocity = dash_control.get_velocity(self)
		if not InputUtils.is_action_pressed(&"jump"):
			stop_dash()
	#endregion

	var is_falling: bool = local_velocity.y * gravity_flip > 0
	if is_on_floor():
		coyote_time = 2.0 / 60.0
	else:
		if is_falling:
			coyote_time = max(0, coyote_time - delta)
		else:
			coyote_time = 0.0

	_deferred_velocity_redirect = _ensure_velocity_redirect(delta, local_velocity.rotated(gameplay_rotation))

	# Reset slope velocity if needed
	if not is_on_floor() and _slope_exit_velocity_frames == 0:
		slope_velocity = Vector2.ZERO

	# Clear colliding pad
	if colliding_pad:
		colliding_pad = null

	return local_velocity.rotated(gameplay_rotation)


func _handle_velocity_interactable(local_velocity: Vector2, interactable: Interactable, direction: int) -> Vector2:
	for component in interactable.components.filter(ArrayUtils.flatten):
		var is_rebound: bool = component is ReboundComponent and (not is_on_floor() or _deferred_velocity_redirect)
		if (
				internal_gamemode != Gamemode.WAVE
				and (component is JumpBoostComponent or is_rebound)
		):
			if internal_gamemode == Gamemode.SPIDER:
				local_velocity.y = component.get_velocity(self) * SPIDER_BOUNCE_MULTIPLIER
			else:
				local_velocity.y = component.get_velocity(self)
			if displayed_gamemode == Gamemode.SPIDER:
				_spider_state_machine.travel(&"jump")
		elif component is SpiderDashComponent:
			var raycast_rotation: float = interactable.global_rotation
			$SpiderCast.rotation = raycast_rotation
			var dash_data: PackedFloat64Array = _get_spider_dash_data()
			var dash_height: float = dash_data[0]
			var floor_angle: float = dash_data[1]
			var displacement: Vector2 = (Vector2.UP * gravity_flip).rotated(interactable.global_rotation) * dash_height
			position += displacement
			jump_hold_disabled = true
			if component.changes_gameplay_rotation():
				if absf(raycast_rotation - gameplay_rotation) <= PI / 4:
					# The teleportation is almost vertical
					gameplay_rotation = raycast_rotation
					gravity_flip *= -1
				else:
					gameplay_rotation = raycast_rotation + PI
					gravity_flip = 1
			else:
				gravity_flip = gravity_flip if absf(floor_angle - gameplay_rotation) >= PI / 2 else -gravity_flip
			# Trail
			var trail: SpiderTrail = SPIDER_TRAIL.instantiate()
			add_child(trail)
			var trail_rotation: float = raycast_rotation
			if absf(raycast_rotation) >= PI / 2:
				trail_rotation += PI
			trail.start.call_deferred(self, displacement, trail_rotation)
			# Force slope collider if needed
			allow_ceiling_hit_count += 1
			# Force up direction update in order for _handle_collision to work properly
			up_direction = Vector2.UP.rotated(gameplay_rotation) * sign(gravity_flip)
			last_collision = move_and_collide(displacement.normalized() * Constants.CELL_SIZE, true)
			$GroundCollider.rotation = gameplay_rotation
			_handle_collision(last_collision, false)
			allow_ceiling_hit_count -= 1
			_spider_dash_frames = 4
			# Snap velocity to the ground
			local_velocity.y = tan(-floor_angle - gameplay_rotation) * abs(local_velocity.x) * direction
			slope_velocity = Vector2.ZERO
			defer_snap_sprite_rotation()
	return local_velocity


## Ensure velocity redirection can happen and the vertical velocity isn't reset by hitting the floor.
func _ensure_velocity_redirect(delta: float, new_velocity: Vector2) -> bool:
	$EnsureVelocityRedirect.shape = $GroundCollider.shape
	$EnsureVelocityRedirect.target_position = new_velocity * delta * ENSURE_VELOCITY_REDIRECT_SAFE_MARGIN
	$EnsureVelocityRedirect.force_shapecast_update()
	if not $EnsureVelocityRedirect.is_colliding():
		return false
	for i in $EnsureVelocityRedirect.get_collision_count():
		var collided_area := $EnsureVelocityRedirect.get_collider(i) as Area2D
		if not collided_area is Interactable:
			return false
		for component in collided_area.components:
			return (component is ReboundComponent and not is_on_floor()) or (component is TeleportComponent and component.redirect_velocity)
	return false


func _update_sprites_rotation(delta: float, jump_state: int, direction: int) -> void:
	_fire_sprite_time += delta
	var local_velocity: Vector2 = velocity.rotated(-gameplay_rotation)
	var velocity_angle: float = atan2(local_velocity.y, abs(local_velocity.x)) + gameplay_rotation
	var corrected_direction: int = horizontal_direction if not dash_control else dash_control.initial_direction
	if $GroundCollider.shape is CircleShape2D:
		var floor_angle_signed: float = _get_floor_angle_signed(false, jump_state)
		if get_floor_normal() != Vector2.ZERO:
			if not is_zero_approx(floor_angle_signed):
				sprite_floor_angle = lerp_angle(
					sprite_floor_angle,
					-floor_angle_signed + gameplay_rotation,
					delta * 60 * ICON_LERP_FACTOR,
				)
		elif last_collision != null:
			var last_collision_normal: Vector2 = last_collision.get_normal()
			if last_collision_normal != Vector2.ZERO:
				var collision_angle := -last_collision_normal.angle_to(up_direction)
				var ceiling_slide_rotation := PI if collision_angle < 0.0 or abs(collision_angle) > PI / 2 else 0.0
				sprite_floor_angle = lerp_angle(
					sprite_floor_angle,
					-collision_angle + gameplay_rotation + ceiling_slide_rotation,
					delta * 60 * ICON_LERP_FACTOR if not _snap_sprite_rotation else 1.0,
				)
	else:
		sprite_floor_angle = lerp_angle(sprite_floor_angle, gameplay_rotation, delta * 60 * ICON_LERP_FACTOR)

	$GroundParticlesOrigin.scale.y = gravity_flip
	$GroundParticlesOrigin.scale.x = horizontal_direction
	$GroundParticlesOrigin.rotation = sprite_floor_angle

	#region flip
	if corrected_direction != 0:
		$Icon.transform = Transform2D.IDENTITY \
				.rotated(-sprite_floor_angle) \
				.scaled(Vector2(corrected_direction, 1)) \
				.rotated(sprite_floor_angle) \
		if displayed_gamemode not in [Gamemode.CUBE, Gamemode.BALL] \
		else Transform2D.IDENTITY
		$CornerSnapping.rotation = gameplay_rotation
		$CornerSnapping.scale.x = corrected_direction
		$CornerSnapping.scale.y = gravity_flip

	$Icon/Cube.scale.y = 1.0
	$Icon/Ship.scale.y = gravity_flip
	$Icon/Ship/ShipParticles.emitting = $Icon/Ship.visible and jump_state > 0
	$Icon/Ship/ShipParticles.interp_to_end = 0.0 if $Icon/Ship.visible else 1.0
	$Icon/Swing.scale.y = 1.0
	$Icon/Wave.scale.y = 1.0
	$Icon/UFO.scale.y = gravity_flip
	$Icon/Jetpack.scale.y = gravity_flip
	$Icon/Jetpack/JetpackParticles.emitting = $Icon/Jetpack.visible and jump_state > 0
	$Icon/Jetpack/JetpackParticles.interp_to_end = 0.0 if $Icon/Jetpack.visible else 1.0
	$Icon/Ball.scale.y = 1.0
	$Icon/Spider.scale.y = gravity_flip
	$Icon/Robot.scale.y = gravity_flip
	#endregion

	#region ball
	if speed_multiplier > 0.0:
		var rotation_delta: float = delta * 0.45 * gravity_multiplier * (velocity.rotated(-gameplay_rotation).x / speed_multiplier)
		if not dash_control:
			rotation_delta *= gravity_flip
		else:
			rotation_delta *= 1.5
		$Icon/Ball.rotation_degrees += rotation_delta
	var ball_grounded_look_factor = $Icon/Ball.get_meta(&"ball_grounded_look_factor", 0.0)
	if (abs(velocity.rotated(-gameplay_rotation).x) / speed_multiplier) < speed.x * 0.5:
		ball_grounded_look_factor = lerpf(ball_grounded_look_factor, 1.0, 10 * delta)
	else:
		ball_grounded_look_factor = lerpf(ball_grounded_look_factor, 0.0, 10 * delta)
	$Icon/Ball.set_meta(&"ball_grounded_look_factor", ball_grounded_look_factor)
	var ball_rotation_in_air: float = Math.polar_polygon_normalized($Icon/Ball.rotation + deg_to_rad(72.0 / 2.0), 5, 2.0)
	$Icon/Ball.position = Vector2(0.0, lerpf(0.0, lerpf(0, 10, ball_rotation_in_air), ball_grounded_look_factor)).rotated(gameplay_rotation)
	#endregion

	#region dash
	if dash_control:
		var dash_angle: float = dash_control.get_velocity(self).angle()
		$DashParticles.emitting = velocity.length() > 0.0
		$DashParticles.rotation = velocity_angle
		$DashParticles.process_material.angle_min = rad_to_deg(dash_angle)
		$DashParticles.process_material.angle_max = rad_to_deg(dash_angle)
		$DashFlame.rotation = dash_angle
		$Icon/Cube.rotation_degrees += delta * 800 * corrected_direction * gravity_flip
		$Icon/Ship.rotation = lerp_angle($Icon/Ship.rotation, velocity_angle, ICON_LERP_FACTOR * delta * 60)
		$Icon/Swing.rotation = lerp_angle($Icon/Swing.rotation, velocity_angle, ICON_LERP_FACTOR * delta * 60)
		$Icon/UFO.rotation = lerp_angle($Icon/UFO.rotation, velocity_angle, ICON_LERP_FACTOR * delta * 60)
		$Icon/Jetpack.rotation = lerp_angle($Icon/Jetpack.rotation, velocity_angle, ICON_LERP_FACTOR * delta * 60)
		$Icon/Spider.rotation = lerp_angle($Icon/Spider.rotation, velocity_angle, ICON_LERP_FACTOR * delta * 60)
		$Icon/Robot.rotation = lerp_angle($Icon/Robot.rotation, velocity_angle, ICON_LERP_FACTOR * delta * 60)
		$Icon/Wave.rotation = lerp_angle($Icon/Wave.rotation, velocity_angle, ICON_LERP_FACTOR * delta * 60)
		return
	#endregion

	#region cube
	if not is_on_floor() and not is_on_ceiling() and speed_multiplier != 0.0:
		$Icon/Cube.rotation_degrees += delta * gravity_flip * 390 * direction * gravity_multiplier
	else:
		$Icon/Cube.rotation = lerp_angle(
			$Icon/Cube.rotation,
			snapped($Icon/Cube.rotation - sprite_floor_angle, PI / 2) + sprite_floor_angle,
			ICON_LERP_FACTOR * delta * 60 if not _snap_sprite_rotation else 1.0,
		)
	#endregion

	#region ship/swing
	if not is_on_floor() and not is_on_ceiling() and speed_multiplier > 0.0:
		$Icon/Ship.rotation = lerp_angle(
			$Icon/Ship.rotation,
			velocity_angle,
			SHIP_ROTATION_LERP_FACTOR * delta * 60,
		)
		$Icon/Swing.rotation = lerp_angle(
			$Icon/Swing.rotation,
			velocity_angle,
			SHIP_ROTATION_LERP_FACTOR * delta * 60,
		)
	else:
		$Icon/Ship.rotation = lerp_angle($Icon/Ship.rotation, sprite_floor_angle, ICON_LERP_FACTOR * delta * 60 if not _snap_sprite_rotation else 1.0)
		$Icon/Swing.rotation = lerp_angle($Icon/Swing.rotation, sprite_floor_angle, ICON_LERP_FACTOR * delta * 60 if not _snap_sprite_rotation else 1.0)
	#endregion

	#region wave
	if direction != 0 or jump_state != 0:
		_wave_rotation_goal = velocity_angle
	if is_on_floor():
		_wave_rotation_goal = sprite_floor_angle
	$Icon/Wave.rotation = lerp_angle(
		$Icon/Wave.rotation,
		_wave_rotation_goal,
		0.25 * delta * 60,
	)
	#endregion

	#region ufo
	if not is_on_floor() and not is_on_ceiling() and speed_multiplier > 0.0:
		$Icon/UFO.rotation_degrees = lerpf(
			$Icon/UFO.rotation_degrees,
			velocity.rotated(-gameplay_rotation).y * delta * direction * 0.5 + gameplay_rotation_degrees,
			ICON_LERP_FACTOR * delta * 60,
		)
	else:
		$Icon/UFO.rotation = lerp_angle($Icon/UFO.rotation, sprite_floor_angle, ICON_LERP_FACTOR * delta * 60 if not _snap_sprite_rotation else 1.0)
	var jetpack_rotation_target: float = deg_to_rad(absf(local_velocity.x) / speed_multiplier * delta * 5) if not is_zero_approx(speed_multiplier) else 0.0
	$Icon/Jetpack.rotation = lerp_angle(
		$Icon/Jetpack.rotation,
		jetpack_rotation_target + sprite_floor_angle,
		ICON_LERP_FACTOR * delta * 60 if not _snap_sprite_rotation else 1.0,
	)
	if jump_state > 0:
		var ufo_particle := UFO_PARTICLE.instantiate()
		$Icon/UFO/UFOParticlesOrigin.add_child(ufo_particle)
	#endregion

	#region spider/robot
	$Icon/Spider.rotation = lerp_angle(
		$Icon/Spider.rotation,
		sprite_floor_angle,
		ICON_LERP_FACTOR * delta * 60 if not _snap_sprite_rotation else 1.0,
	)
	$Icon/Robot.rotation = lerp_angle(
		$Icon/Robot.rotation,
		sprite_floor_angle,
		ICON_LERP_FACTOR * delta * 60 if not _snap_sprite_rotation else 1.0,
	)
	#endregion


func _update_swing_fire(delta: float) -> void:
	if displayed_gamemode != Gamemode.SWING:
		$Icon/Swing/FireBoostTop/FireParticles.emitting = false
		$Icon/Swing/FireBoostMiddle/FireParticles.emitting = false
		$Icon/Swing/FireBoostBottom/FireParticles.emitting = false
		$Icon/Swing/FireBoostTop/FireParticles.interp_to_end = 1.0
		$Icon/Swing/FireBoostMiddle/FireParticles.interp_to_end = 1.0
		$Icon/Swing/FireBoostBottom/FireParticles.interp_to_end = 1.0
	else:
		var fire_boosts: Array[Sprite2D]
		fire_boosts.assign([$Icon/Swing/FireBoostTop, $Icon/Swing/FireBoostMiddle, $Icon/Swing/FireBoostBottom])
		for i: int in fire_boosts.size():
			var fire_boost: Sprite2D = fire_boosts[i]
			fire_boost.scale.x = remap(sin(PI * (_fire_sprite_time + float(i) / fire_boosts.size()) * 10), -1.0, 1.0, 0.95, 1.05) * 0.6
		$Icon/Swing/FireBoostMiddle/FireParticles.emitting = true
		$Icon/Swing/FireBoostTop/FireParticles.interp_to_end = 0.0
		$Icon/Swing/FireBoostMiddle/FireParticles.interp_to_end = 0.0
		$Icon/Swing/FireBoostBottom/FireParticles.interp_to_end = 0.0
		if gravity_flip < 0.0:
			$Icon/Swing/FireBoostTop.position = $Icon/Swing/FireBoostTop.position.lerp(Vector2.ZERO, 1 - exp(-delta * 12))
			$Icon/Swing/FireBoostBottom.position = $Icon/Swing/FireBoostBottom.position.lerp(Vector2(-54.0, 63.0), 1 - exp(-delta * 12))
			$Icon/Swing/FireBoostTop/FireParticles.emitting = false
			$Icon/Swing/FireBoostBottom/FireParticles.emitting = true
		else:
			$Icon/Swing/FireBoostTop.position = $Icon/Swing/FireBoostTop.position.lerp(Vector2(-54.0, -63.0), 1 - exp(-delta * 12))
			$Icon/Swing/FireBoostBottom.position = $Icon/Swing/FireBoostBottom.position.lerp(Vector2.ZERO, 1 - exp(-delta * 12))
			$Icon/Swing/FireBoostTop/FireParticles.emitting = true
			$Icon/Swing/FireBoostBottom/FireParticles.emitting = false


func _update_robot_fire(delta: float, jump_state: int) -> void:
	var fire_sprites: Array[Sprite2D]
	var fire_particles: Array[GPUParticles2D]
	fire_sprites.assign([$Icon/Robot/RobotSprites/Head/ConnectorBack/LegBack/FootBack/Fire, $Icon/Robot/RobotSprites/Head/ConnectorFront/LegFront/FootFront/Fire])
	fire_particles.assign([$Icon/Robot/RobotSprites/Head/ConnectorBack/LegBack/FootBack/Fire/FireParticles, $Icon/Robot/RobotSprites/Head/ConnectorFront/LegFront/FootFront/Fire/FireParticles])

	for i: int in fire_sprites.size():
		var fire_sprite: Sprite2D = fire_sprites[i]
		var fire_particle_emitter: GPUParticles2D = fire_particles[i]
		fire_particle_emitter.interp_to_end = 0.0
		if displayed_gamemode != Gamemode.ROBOT:
			fire_particle_emitter.emitting = false
			continue
		fire_sprite.scale.x = remap(sin(PI * (_fire_sprite_time + float(i) / fire_sprites.size()) * 10), -1.0, 1.0, 0.95, 1.05) * ROBOT_FIRE_SCALE
		if jump_state < 1:
			fire_particle_emitter.emitting = false
			fire_sprite.position.y = lerpf(fire_sprite.position.y, 8.0, 1 - exp(-delta * 12))
			fire_sprite.scale.y = lerpf(fire_sprite.scale.y, 0.0, 1 - exp(-delta * 12))
		else:
			fire_particle_emitter.emitting = true
			fire_sprite.position.y = lerpf(fire_sprite.position.y, 44.0, 1 - exp(-delta * 12))
			fire_sprite.scale.y = lerpf(fire_sprite.scale.y, ROBOT_FIRE_SCALE, 1 - exp(-delta * 12))


func _update_wave_trail(delta: float) -> void:
	var wave_trail_width := WAVE_TRAIL_WIDTH
	var player_camera_zoom_x: float
	player_camera_zoom_x = LevelManager.player_camera.zoom.x if LevelManager.player_camera else 1.0
	if player_scale == PlayerScale.MINI:
		wave_trail_width *= PLAYER_SCALE_MINI.y
	elif player_scale == PlayerScale.BIG:
		wave_trail_width *= PLAYER_SCALE_BIG.y
	var trail_has_sharp_angles: bool = internal_gamemode == Gamemode.WAVE
	%WaveTrail.use_physics_process = trail_has_sharp_angles
	$DebugTrail.use_physics_process = trail_has_sharp_angles
	%WaveTrail.width = lerpf(%WaveTrail.width, wave_trail_width, 0.25 * delta * 60)
	if displayed_gamemode == Gamemode.WAVE:
		%WaveTrail.modulate.a = 1.0
		%WaveTrail.length = lerpf(%WaveTrail.length, WAVE_TRAIL_LENGTH / player_camera_zoom_x, delta * 60 * 0.2)
	else:
		%WaveTrail.length = 0
		%WaveTrail.modulate.a = move_toward(%WaveTrail.modulate.a, 0.0, delta * 60 * 0.2)
		if is_zero_approx(%WaveTrail.modulate.a):
			%WaveTrail.clear_points()


func _set_particles_visibility() -> void:
	var particles_visibility: bool = (
			Config.particles_visibility & Config.ParticleVisibility.PLAYER
			or (Editor.in_editor and not Config.show_particles_in_editor)
	)
	%GroundParticles.visible = particles_visibility
	%ShipParticles.visible = particles_visibility
	%JetpackParticles.visible = particles_visibility
	%UFOParticlesOrigin.visible = particles_visibility
	$DashParticles.visible = particles_visibility
	$DeathParticles.visible = particles_visibility


func _update_spider_cast_rotation() -> void:
	$SpiderCast.rotation = gameplay_rotation + (PI if gravity_flip < 0 else 0.0)


func _get_spider_dash_data() -> PackedFloat64Array:
	var raycast: RayCast2D = $SpiderCast
	raycast.force_raycast_update()
	var target_position = raycast.get_collision_point()
	var dash_height: float = (target_position - position).length()
	var floor_angle: float = raycast.get_collision_normal().angle_to(Vector2.DOWN * gravity_flip)
	dash_height -= (default_collider.size.y * 0.5 * scale.y)
	dash_height *= gravity_flip
	if not raycast.is_colliding():
		$DeathAnimator.play("DeathAnimation")
		return [dash_height * 32, floor_angle]
	return [dash_height, floor_angle]


func _update_spider_state_machine(jump_state: int) -> void:
	var is_stopped: bool = velocity.rotated(-gameplay_rotation).x == 0.0
	if dash_control or (jump_state == -1 and not is_on_floor() and not is_on_ceiling() and not is_on_wall() and not $GroundCollider.shape is CircleShape2D):
		_spider_state_machine.travel(&"fall")
	elif is_stopped:
		_spider_state_machine.travel(&"idle" if not $IdleAltAnimationCooldown.is_stopped() else &"idle_alt")
	elif speed_multiplier >= 1.849:
		spider_animation_tree["parameters/run/PlayerSpeed/scale"] = speed_multiplier / 1.849
		_spider_state_machine.travel(&"run")
	else:
		spider_animation_tree["parameters/walk/PlayerSpeed/scale"] = speed_multiplier
		_spider_state_machine.travel(&"walk")


func _update_robot_state_machine(jump_state: int) -> void:
	var is_stopped: bool = velocity.rotated(-gameplay_rotation).x == 0.0
	if dash_control:
		_robot_state_machine.travel(&"dash")
	elif jump_state == 1:
		_robot_state_machine.travel(&"jump")
	elif not is_on_floor() and not is_on_ceiling() and not is_on_wall() and not $GroundCollider.shape is CircleShape2D:
		_robot_state_machine.travel(&"fall")
	elif is_stopped:
		_robot_state_machine.travel(&"idle" if not $IdleAltAnimationCooldown.is_stopped() else &"idle_alt")
	else:
		robot_animation_tree["parameters/walk/PlayerSpeed/scale"] = speed_multiplier
		_robot_state_machine.travel(&"walk")


func _player_death() -> void:
	AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Music"), true)
	dead = true
	last_automatic_checkpoint_position = position
	$Icon.hide()
	$DeathEffect.frame = 0
	$DeathEffect.play()
	$DeathParticles.restart()
	$DashParticles.emitting = false
	%GroundParticles.emitting = false
	$Trail.clear_points()
	SFXManager.play_sfx("res://assets/sounds/sfx/game_sfx/DeathSound.mp3")


func _on_death_restart() -> void:
	var should_use_practice_snapshot: bool = not LevelManager.practice_level_snapshots.is_empty()
	if Editor.in_editor and not should_use_practice_snapshot:
		Editor.root.stop_playtest()
	else:
		LevelManager.game_scene.restart_level()


func _handle_checkpoint_placement(practice_mode: bool = LevelManager.practice_mode) -> void:
	var checkpoint_parent: Node2D = LevelManager.game_scene.checkpoint_parent
	if not practice_mode:
		return
	if InputUtils.is_action_just_pressed(&"practice_create_checkpoint"):
		place_checkpoint().use_normal_sprite().done()
		last_automatic_checkpoint_position = position
	elif InputUtils.is_action_just_pressed(&"practice_remove_checkpoint"):
		var last_checkpoint: Sprite2D = checkpoint_parent.get_child(-1)
		if not last_checkpoint:
			return
		last_checkpoint.queue_free()
		LevelManager.practice_level_snapshots.pop_back()
	elif Config.automatic_checkpoints and no_auto_checkpoints_count == 0:
		if last_automatic_checkpoint_position.is_finite() and last_automatic_checkpoint_position.distance_to(position) < Config.automatic_checkpoint_distance * Constants.CELL_SIZE:
			return
		if is_on_floor_only():
			place_checkpoint().use_auto_sprite().done()
		elif _is_flying_gamemode or internal_gamemode == Gamemode.UFO:
			place_checkpoint().use_auto_sprite().done()
		else:
			return
		last_automatic_checkpoint_position = position


func _on_kill_collider_solid_body_entered(_body: Node2D) -> void:
	if _spider_dash_frames == 0:
		$DeathAnimator.play("DeathAnimation")


func _on_kill_collider_hazard_area_entered(_area: Area2D) -> void:
	if _spider_dash_frames == 0:
		$DeathAnimator.play("DeathAnimation")


func _on_solid_overlap_check_body_exited(body: Node2D) -> void:
	if body == null:
		return
	body = body as CollisionObject2D
	# Shared level bodies never get re-layered by lethal hits; only per-object
	# bodies (trigger-animated / pushable solids) do, and those keep a Hitbox
	# child to restore the debug colour on.
	if LevelPhysics.is_shared_body(body):
		return
	body.collision_layer = 1 << 1
	if body.has_node(^"Hitbox"):
		body.get_node(^"Hitbox").debug_color = Color("#0012b340") # DEBUG: Hardcoded name for hitbox color
