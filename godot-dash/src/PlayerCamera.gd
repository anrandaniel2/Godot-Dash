class_name PlayerCamera
extends Camera2D

const DEFAULT_ZOOM: Vector2 = Vector2(0.8, 0.8)
const DEFAULT_OFFSET: Vector2 = Vector2(400.0, 0.0)
const MAX_DISTANCE := Vector2(400.0, 300.0)

@export var position_smoothing: float = 0.1
@export var offset_smoothing: float = 0.125
@export var gameplay_offset_factor := Vector2.ONE
@export var additional_offset := Vector2.ZERO
@export var static_factor := Vector2.ZERO
@export var shake_offset := Vector2.ZERO
@export var center_on_player_at_0x_speed: bool = true

var player: Player
var freefly := true
## Value in pixels of the gameplay offset. Smoothed over time.
var gameplay_offset: Vector2
var is_snapping_view: bool
var player_speed_sign: int
var static_offset_rotation: float ## Rotation used by the offset when static gets enabled.
var smoothed_gameplay_rotation: float


func _ready() -> void:
	LevelManager.player_camera = self
	player = LevelManager.player
	offset = get_offset_target(1 / offset_smoothing)


func _process(delta: float) -> void:
	if not (LevelManager.level_playing or is_snapping_view) or player.dead:
		return
	queue_redraw()
	var framerate_compensation: float = delta * 60.0
	smoothed_gameplay_rotation = lerp_angle(smoothed_gameplay_rotation, player.gameplay_rotation, 0.1 * framerate_compensation if not is_snapping_view else 1.0)

	var player_distance = player.position - position
	var ground_distance = GroundData.center - position + Vector2.from_angle(player.gameplay_rotation - PI / 2) * GroundData.offset
	# Rotation-local
	var local_player_distance = player_distance.rotated(-player.gameplay_rotation)
	var local_ground_distance = ground_distance.rotated(-player.gameplay_rotation)
	var local_added_distance = local_player_distance
	local_added_distance.y = local_target_distance_axis(
		local_player_distance.y if freefly else local_ground_distance.y,
		MAX_DISTANCE.y / zoom.y,
		framerate_compensation,
	)
	if LevelManager.platformer:
		local_added_distance.x = local_target_distance_axis(
			local_player_distance.x,
			MAX_DISTANCE.x / zoom.x,
			framerate_compensation,
		)

	# Apply distance
	var added_distance: Vector2 = local_added_distance.rotated(player.gameplay_rotation)
	if static_factor.x == 0:
		position.x += added_distance.x
	if static_factor.y == 0:
		position.y += added_distance.y

	offset = get_offset_target(framerate_compensation).rotated(smoothed_gameplay_rotation if static_factor == Vector2.ZERO else static_offset_rotation)

	# Clamp bottom edge of the screen to the ground
	var half_screen_height = get_viewport_rect().size.y / 2
	if position.y + half_screen_height / zoom.y > LevelManager.ground_down.default_y + 160:
		position.y = LevelManager.ground_down.default_y + 160 - half_screen_height / zoom.y
	# Same thing for the top edge of the screen
	if position.y - half_screen_height / zoom.y < LevelManager.ground_up.default_y - 160:
		position.y = LevelManager.ground_up.default_y - 160 + half_screen_height / zoom.y


func reset() -> void:
	limit_left = -10000000
	limit_top = -10000000
	limit_right = 10000000
	limit_bottom = 10000000
	center_on_player_at_0x_speed = true
	static_factor = Vector2.ZERO
	gameplay_offset_factor = Vector2.ONE
	zoom = PlayerCamera.DEFAULT_ZOOM
	offset = PlayerCamera.DEFAULT_OFFSET
	rotation = 0.0


func local_target_distance_axis(distance: float, max_distance: float, framerate_compensation: float) -> float:
	if not freefly:
		return distance * 0.2 * framerate_compensation
	if abs(distance) < max_distance:
		return 0.0
	else:
		return (distance - sign(distance) * max_distance) * 0.2 * framerate_compensation


func get_offset_target(framerate_compensation: float) -> Vector2:
	if LevelManager.platformer:
		gameplay_offset = gameplay_offset.lerp(Vector2.ZERO, offset_smoothing * framerate_compensation if not is_snapping_view else 1.0)
	else:
		if center_on_player_at_0x_speed or not is_zero_approx(player.speed_multiplier):
			player_speed_sign = sign(player.speed_multiplier)
		gameplay_offset = gameplay_offset.lerp(
			Vector2(
				(DEFAULT_OFFSET.x * player.get_direction() * player_speed_sign),
				DEFAULT_OFFSET.y,
			),
			0.125 * framerate_compensation if not is_snapping_view else 1.0,
		)
	return (gameplay_offset / zoom) * gameplay_offset_factor * (Vector2.ONE - static_factor) + additional_offset + shake_offset


func snap_view() -> void:
	is_snapping_view = true
	if is_inside_tree():
		await get_tree().process_frame
	if is_inside_tree():
		await get_tree().process_frame
	is_snapping_view = false


func _draw() -> void:
	if not Config.draw_debug_overlays or not player:
		return
	draw_set_transform(Vector2.ZERO, player.gameplay_rotation)
	draw_rect(Rect2(-MAX_DISTANCE / zoom, 2 * MAX_DISTANCE / zoom), Color.CYAN, false, 4.0)
	draw_set_transform(Vector2.ZERO, 0.0)
	draw_circle(Vector2.ZERO, 20.0, Color.GREEN, false, 4.0)
	draw_circle(offset.rotated(-rotation), 20.0, Color.MAGENTA, false, 4.0)
