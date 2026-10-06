class_name PlayerCamera
extends Camera2D

const DEFAULT_ZOOM: Vector2 = Vector2(0.8, 0.8)
const DEFAULT_OFFSET: Vector2 = Vector2(400.0, 0.0)
const MAX_DISTANCE := Vector2(400.0, 300.0)
## Geometry Dash vertical camera law, from Wyliemaster/Geometry-Dash-1.0
## PlayLayer/updateCamera.cpp (PlayLayer::updateCamera): in cube-style modes
## the player is kept 90 units (3 cells) below the top edge and 120 units
## (4 cells) above the bottom edge, swapped under flipped gravity, and the
## camera closes 1/10 of the gap per 60 Hz frame; fly modes chase the portal
## centre at 1/30. GD's 320-unit view (10.7 cells) matches this camera's
## 1080 / 0.8 px view (10.5 cells), so the margins carry over in cells.
## Hypothesis: GD 2.1 keeps the 1.0 law (only the 1.0 body is decompiled).
const GD_TOP_MARGIN_CELLS: float = 3.0
const GD_BOTTOM_MARGIN_CELLS: float = 4.0
const GD_FREE_EASE: float = 1.0 / 10.0
const GD_LOCKED_EASE: float = 1.0 / 30.0
## Camera Mode (2925) Edit Camera Settings: the free-follow ease is 1 / Easing
## (hypothesis: GD's default Easing 10 is updateCamera's 1/10 law).
static var free_ease: float = GD_FREE_EASE
## GD 1.0 updateCamera: within 50 units of the end clamp the camera moves to
## the end portal's height.
const GD_END_APPROACH_PX: float = 50.0 / 30.0 * Constants.CELL_SIZE

@export var position_smoothing: float = 0.1
@export var offset_smoothing: float = 0.125
@export var gameplay_offset_factor := Vector2.ONE
@export var additional_offset := Vector2.ZERO
@export var static_factor := Vector2.ZERO
@export var shake_offset := Vector2.ZERO
@export var center_on_player_at_0x_speed: bool = true

var player: Player
var freefly := true
## What the last gamemode portal set; Camera Mode Free Mode off returns here.
var portal_freefly: bool = true
## Value in pixels of the gameplay offset. Smoothed over time.
var gameplay_offset: Vector2
var is_snapping_view: bool
## Whether the last frame queued a debug-overlay redraw, so turning the
## setting off mid-play still issues the one redraw that clears the overlay.
var _debug_overlays_were_on: bool = false
var player_speed_sign: int
var static_offset_rotation: float ## Rotation used by the offset when static gets enabled.
var smoothed_gameplay_rotation: float
## GD's lastGroundPos.y == 105 test: the player last landed on the floor
## ground itself rather than on a block.
var _last_ground_was_floor: bool = false
## Geometry Dash end portal (imported classic levels), INF when none. Set by
## Level at every attempt start.
var gd_level_end: Vector2 = Vector2.INF


func _ready() -> void:
	LevelManager.player_camera = self
	player = LevelManager.player
	offset = get_offset_target(1 / offset_smoothing)


func _process(delta: float) -> void:
	if not (LevelManager.level_playing or is_snapping_view) or player.dead:
		return
	# The debug overlay draw is the only reason this camera redraws; skip the
	# queue_redraw (a canvas-item dirty pass every frame) when it is off. One
	# final redraw on the true->false transition clears whatever was drawn.
	if Config.draw_debug_overlays:
		queue_redraw()
		_debug_overlays_were_on = true
	elif _debug_overlays_were_on:
		queue_redraw()
		_debug_overlays_were_on = false
	var framerate_compensation: float = delta * 60.0
	smoothed_gameplay_rotation = lerp_angle(smoothed_gameplay_rotation, player.gameplay_rotation, 0.1 * framerate_compensation if not is_snapping_view else 1.0)

	var player_distance = player.position - position
	var ground_distance = GroundData.center - position + Vector2.from_angle(player.gameplay_rotation - PI / 2) * GroundData.offset
	# Rotation-local
	var local_player_distance = player_distance.rotated(-player.gameplay_rotation)
	var local_ground_distance = ground_distance.rotated(-player.gameplay_rotation)
	var local_added_distance = local_player_distance
	var half_view_height: float = get_viewport_rect().size.y / 2.0 / zoom.y
	if player.is_on_floor():
		_last_ground_was_floor = player.gravity_flip > 0 \
				and absf(player.global_position.y - LevelManager.ground_down.global_position.y) < Constants.CELL_SIZE
	local_added_distance.y = gd_vertical_step(
		local_player_distance.y if freefly else local_ground_distance.y,
		half_view_height,
		freefly,
		player.gravity_flip < 0,
		framerate_compensation,
	)
	# GD 1.0 updateCamera: after landing on the floor, a cube-style camera
	# whose player is not past the top margin settles back onto the floor.
	if freefly and _last_ground_was_floor and is_zero_approx(player.gameplay_rotation) \
			and local_player_distance.y >= GD_TOP_MARGIN_CELLS * Constants.CELL_SIZE - half_view_height:
		var floor_camera_y: float = LevelManager.ground_down.default_y + 160.0 - half_view_height
		local_added_distance.y = (floor_camera_y - position.y) * GD_FREE_EASE * framerate_compensation
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
	_apply_gd_level_end(framerate_compensation)

	# Clamp bottom edge of the screen to the ground
	var half_screen_height = get_viewport_rect().size.y / 2
	if position.y + half_screen_height / zoom.y > LevelManager.ground_down.default_y + 160:
		position.y = LevelManager.ground_down.default_y + 160 - half_screen_height / zoom.y
	# Same thing for the top edge of the screen
	if position.y - half_screen_height / zoom.y < LevelManager.ground_up.default_y - 160:
		position.y = LevelManager.ground_up.default_y - 160 + half_screen_height / zoom.y


## GD 1.0 PlayLayer::updateCamera (Wyliemaster/Geometry-Dash-1.0): the
## camera's right edge never passes m_fEndOfLevel, so the player runs on into
## the end portal; once the clamp is within 50 units the camera moves to the
## portal's height (moveCameraToPos; eased at GD_FREE_EASE - hypothesis, the
## action's duration is not decompiled).
func _apply_gd_level_end(framerate_compensation: float) -> void:
	if not gd_level_end.is_finite() or LevelManager.platformer:
		return
	var half_view_width: float = get_viewport_rect().size.x / 2.0 / zoom.x
	var max_center_x: float = gd_level_end.x - half_view_width - offset.x
	if position.x > max_center_x:
		position.x = max_center_x
	if max_center_x - position.x < GD_END_APPROACH_PX:
		position.y += (gd_level_end.y - offset.y - position.y) * GD_FREE_EASE * framerate_compensation


func reset() -> void:
	_last_ground_was_floor = false
	free_ease = GD_FREE_EASE
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


## One frame of GD's vertical camera follow. distance is the player's (or,
## in fly modes, the portal centre's) rotation-local offset from the view
## centre, +y down; half_height is half the visible height in px.
## Free mode closes [member free_ease] of the gap per 60 Hz frame.
static func gd_vertical_step(distance: float, half_height: float, is_freefly: bool, flipped: bool, framerate_compensation: float) -> float:
	if not is_freefly:
		return distance * GD_LOCKED_EASE * framerate_compensation
	var top_margin: float = (GD_BOTTOM_MARGIN_CELLS if flipped else GD_TOP_MARGIN_CELLS) * Constants.CELL_SIZE
	var bottom_margin: float = (GD_TOP_MARGIN_CELLS if flipped else GD_BOTTOM_MARGIN_CELLS) * Constants.CELL_SIZE
	var upper_limit: float = top_margin - half_height
	var lower_limit: float = half_height - bottom_margin
	if distance < upper_limit:
		return (distance - upper_limit) * free_ease * framerate_compensation
	if distance > lower_limit:
		return (distance - lower_limit) * free_ease * framerate_compensation
	return 0.0


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


## Camera Mode trigger (2925). geode-sdk bindings 2.2081 inline
## GJBaseGameLayer::updateCameraMode assigns m_isFreeMode (on and off), clamps
## easing to [1, 40] and calls updateDualGround when the mode changes. Turning
## Free Mode off restores the borders of the last bordered portal (hypothesis:
## GD recomputes the same band there). Cube and robot have no borders.
func apply_gd_camera_mode(free_mode: bool, edit_settings: bool, easing: float) -> void:
	freefly = free_mode or portal_freefly
	if edit_settings:
		free_ease = 1.0 / clampf(easing, 1.0, 40.0)
