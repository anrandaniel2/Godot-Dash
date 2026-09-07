class_name GameScene
extends Node2D

@export var checkpoint_parent: Node2D
@export var pause_menu: PauseMenu
@export var fade_screen: FadeScreen

var cached_level_data: Dictionary
var cached_level_path: String


func _ready() -> void:
	Engine.time_scale = 1.0
	LevelManager.game_scene = self
	LevelManager.background_sprites.clear()
	LevelManager.background_sprites.append($BackgroundParallax/Background)
	LevelManager.background_sprites.append($BackgroundParallax/Background2)
	LevelManager.level_playing = false
	LevelManager.ground_down = $GroundDownParallax/GroundDownOrigin
	LevelManager.ground_up = $GroundUpParallax/GroundUpOrigin
	LevelManager.player.process_mode = Node.PROCESS_MODE_DISABLED
	Input.mouse_mode = Input.MOUSE_MODE_CONFINED_HIDDEN
	if not SceneManager.in_editor():
		pause_menu.leave_callback = _on_leave_pressed
		fade_screen.anticipate_fade_out()
		$EditorGridParallax/EditorGrid.hide()
		load_level()
		start_level()


func load_level() -> void:
	var should_use_practice_snapshot: bool = not LevelManager.practice_level_snapshots.is_empty()
	assert(
		not LevelManager.current_level_path.is_empty()
		or (Editor.in_editor and not Editor.level_data_snapshot.is_empty())
		or should_use_practice_snapshot,
		"You can't load the game from GameScene.",
	)
	if not should_use_practice_snapshot:
		for checkpoint in checkpoint_parent.get_children():
			checkpoint.queue_free()
	if LevelManager.current_level_path != cached_level_path:
		cached_level_path = LevelManager.current_level_path
		cached_level_data = LevelOperationsHandler.load_level_data_from_path(LevelManager.current_level_path)
		# This decode is unavoidable (the level is about to be built), so write
		# the metadata sidecar here: the community list reads only sidecars and
		# must never decode a level itself.
		LevelOperationsHandler.write_level_meta(LevelManager.current_level_path, cached_level_data)
	# A practice snapshot is only usable as full level data when the level was
	# duplicated into it (the non-streamed build). A streamed level never
	# duplicates itself - its checkpoint stores just the respawn point and
	# player state (see LevelStream), so a scene rebuild must fall back to the
	# resident records; restart_level is what resumes from a checkpoint mid-run.
	var level_data: Dictionary = cached_level_data
	if should_use_practice_snapshot:
		var latest_snapshot: Dictionary = LevelManager.practice_level_snapshots[-1]
		if latest_snapshot.has("layers"):
			level_data = latest_snapshot
	var level: Level = Level.from_data(level_data)
	if not SceneManager.in_editor():
		SceneManager.set_current_scene(SceneManager.Scene.LEVEL)
	add_loaded_level(level)
	if LevelStream.is_streaming(level):
		# The stream now keeps the level's gameplay records as compact packed
		# blobs and the decoration batches hold what they draw - the full
		# level-data Dictionary graph (tens of MB on a large level) was only
		# needed to build those. Releasing it here is what stops resident
		# memory from scaling with the whole level. The real start position is
		# kept on the level for restarts that leave practice mode.
		level.set_meta(Level.REAL_START_META, level.start_position)
		cached_level_data = {}
		cached_level_path = ""


func add_loaded_level(level: Level) -> Level:
	LevelManager.current_level = level
	TextComponent.DEFAULT_TEXT_SETTINGS.set_font_path()
	if level.get_parent() != $Level:
		$Level.add_child(level, true)
	return level


func start_level() -> void:
	var level: Level = LevelManager.current_level
	level.prepare_external_data()
	LevelManager.player_camera.snap_view()
	AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Music"), false)
	if LevelManager.attempt == 0 and not Editor.in_editor:
		$FadeScreen.fade_out()
		await $FadeScreen.fade_finished
	else:
		$FadeScreen.hide()
	level.start_level()
	$PercentageLayer.visible = Config.show_percentage
	LevelManager.attempt += 1
	LevelManager.player.process_mode = Node.PROCESS_MODE_INHERIT


func restart_level() -> void:
	LevelManager.player.global_position = LevelManager.current_level.start_position
	LevelManager.player.process_mode = Node.PROCESS_MODE_INHERIT
	reset()
	var level: Level = LevelManager.current_level
	if LevelStream.is_streaming(level):
		# Streamed levels respawn the way GD does: the object records stay
		# resident and the live window is rebuilt from them around the respawn
		# point (which also resets every one-shot object). No level snapshot is
		# deserialized - the level was never duplicated.
		if LevelManager.practice_mode and LevelManager.practice_level_snapshots.size() > 0:
			var snapshot: Dictionary = LevelManager.practice_level_snapshots[-1]
			if snapshot.has("practice_data"):
				level._apply_practice_data(snapshot.practice_data)
				if snapshot.has("start_position"):
					var respawn_position: Vector2 = snapshot.start_position
					# start_level()'s prepare_external_data positions the
					# player at level.start_position, so the checkpoint becomes
					# the level's start for this attempt - exactly what the
					# full-snapshot path did through use_data().
					level.start_position = respawn_position
					LevelManager.player.global_position = respawn_position
			else:
				# A full (legacy) snapshot still works on a streamed level.
				level.use_data(snapshot)
		else:
			level._elapsed_time = 0.0
			# Practice restarts move level.start_position to the checkpoint; a
			# non-practice restart (including practice just being toggled off)
			# goes back to the level's real start. Streamed levels release the
			# cached level data, so their real start lives on the level.
			var real_start: Variant = level.get_meta(Level.REAL_START_META, null)
			if real_start == null and not cached_level_data.is_empty():
				real_start = cached_level_data.get("start_position", null)
			if real_start != null:
				level.start_position = real_start as Vector2
		level.stream_restart_at(level.start_position.x)
	elif LevelManager.practice_mode and LevelManager.practice_level_snapshots.size() > 0:
		level.use_data(LevelManager.practice_level_snapshots[-1])
	elif not cached_level_data.is_empty():
		level.use_data(cached_level_data)
	await get_tree().physics_frame
	LevelManager.player.process_mode = Node.PROCESS_MODE_DISABLED
	start_level()


func free_current_level() -> void:
	LevelManager.current_level.name = "%s_Level_%s" % [Constants.FREED, hash(LevelManager.current_level)]
	LevelManager.current_level.queue_free()


func reset() -> void:
	Engine.time_scale = 1.0
	if LevelManager.current_level:
		LevelManager.current_level.stop_level()
	LevelManager.ground_up.hide()
	LevelManager.ground_up.position.y = GroundMoverComponent.DEFAULT_GROUND_UP_Y
	LevelManager.ground_down.position.y = GroundMoverComponent.DEFAULT_GROUND_DOWN_Y
	LevelManager.player_duals.map(NodeUtils.free_node)
	LevelManager.player_duals.clear()
	LevelManager.player.reset()
	LevelManager.player_camera.reset()


func _on_leave_pressed() -> PauseMenu.Leave:
	for level in $Level.get_children():
		level.stop_level()
		LevelPhysics.teardown(level)
		LevelBatching.teardown(level)
	LevelManager.player.process_mode = Node.PROCESS_MODE_DISABLED
	LevelManager.player_camera.process_mode = Node.PROCESS_MODE_DISABLED
	$FadeScreen.fade_in()
	return PauseMenu.Leave.CONTINUE


static func get_camera_rect(camera: Camera2D, viewport: Viewport) -> Rect2:
	var rect_pos := camera.get_screen_center_position()
	var rect_size := (viewport.get_visible_rect().size / camera.zoom)
	return Rect2(rect_pos - rect_size * 0.5, rect_size)
