class_name GameScene
extends Node2D

## Geometry Dash art sets bundled from RobTop's HD textures (gd-textures
## 2.207 mirror): game_bg_%02d_001 (59), groundSquare_%02d_001 (22, plus a
## _2 layer from ground 8 on, GJGroundLayer::init), fg_%02d_001 / _2 (3; 0 is
## no middleground). Clamps: GameManager::getBGTexture / getGTexture /
## getMGTexture (geode-sdk bindings GameManager.cpp).
const GD_ART_DIR: String = "res://assets/textures/gd_art/"
const GD_BG_COUNT: int = 59
const GD_GROUND_COUNT: int = 22
const GD_MG_COUNT: int = 3
## Engine pixels per GD point; HD textures carry two texels per point.
const GD_PX_PER_TEXEL: float = Constants.CELL_SIZE / 30.0 / 2.0
## gd_docs triggers/level/bg_speed.md and mg_speed.md defaults.
const GD_DEFAULT_BG_SPEED: Vector2 = Vector2(0.1, 0.1)
const GD_DEFAULT_MG_SPEED: Vector2 = Vector2(0.3, 0.5)
const GD_GROUND_SPAN_PX: float = 24000.0
const FLOOR_Y: float = 925.0

@export var checkpoint_parent: Node2D
@export var pause_menu: PauseMenu
@export var fade_screen: FadeScreen

var cached_level_data: Dictionary
var cached_level_path: String
var native_trigger_bridge: NativeTriggerBridge


## Device memory diagnostics (2026-09-13): the app dies at Amethyst level
## start with no tombstone - lmkd (the low-memory killer) is the prime
## suspect on this device. Print this process's RSS and peak from
## /proc/self/status at the key level-lifecycle moments and every 10 s
## while playing, so one more session in logcat (grep gdash-mem) shows
## the full RAM trajectory into the kill.
func _print_process_memory(tag: String) -> void:
	var status := FileAccess.open("/proc/self/status", FileAccess.READ)
	if status == null:
		return
	var rss := ""
	var peak := ""
	while not status.eof_reached():
		var line := status.get_line()
		if line.begins_with("VmRSS"):
			rss = line.strip_edges()
		elif line.begins_with("VmHWM"):
			peak = line.strip_edges()
	status.close()
	if not rss.is_empty():
		print("[gdash-mem] %s | %s | %s" % [tag, rss, peak])


func _ready() -> void:
	print("[gdash-mem] game scene ready")
	Engine.time_scale = 1.0
	LevelManager.game_scene = self
	LevelManager.background_sprites.clear()
	LevelManager.background_sprites.append($BackgroundParallax/Background)
	LevelManager.background_sprites.append($BackgroundParallax/Background2)
	LevelManager.level_playing = false
	LevelManager.ground_down = $GroundDownParallax/GroundDownOrigin
	LevelManager.ground_up = $GroundUpParallax/GroundUpOrigin
	LevelManager.player.process_mode = Node.PROCESS_MODE_DISABLED
	Input.mouse_mode = InputUtils.confined_hidden_mouse_mode()
	_probe_native_core()
	var memory_report_timer := Timer.new()
	memory_report_timer.name = "MemoryReportTimer"
	memory_report_timer.wait_time = 10.0
	memory_report_timer.autostart = true
	memory_report_timer.timeout.connect(func() -> void:
		if LevelManager.level_playing:
			_print_process_memory("playing"))
	add_child(memory_report_timer)
	if not SceneManager.in_editor():
		pause_menu.leave_callback = _on_leave_pressed
		fade_screen.anticipate_fade_out()
		$EditorGridParallax/EditorGrid.hide()
		_open_level_paced()


## Opens the level on device without freezing the app: the level is built a
## few milliseconds at a time across frames (see LevelBuildJob), so a large
## level shows a loading pause instead of an Android ANR dialog, then plays.
func _open_level_paced() -> void:
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
	# A practice snapshot is usable as full level data: practice checkpoints
	# duplicate the whole level (see CheckpointPlacementBuilder), so a scene
	# rebuild resumes from the duplicated data.
	var level_data: Dictionary = cached_level_data
	if should_use_practice_snapshot:
		var latest_snapshot: Dictionary = LevelManager.practice_level_snapshots[-1]
		if latest_snapshot.has("layers"):
			level_data = latest_snapshot

	var open_started_ms: int = Time.get_ticks_msec()
	_print_process_memory("level open start")
	var job := LevelBuildJob.new(level_data)
	# Component setters and player initialization legitimately consult the
	# current level while LevelBuildJob performs its final use_data pass. Publish
	# the new instance before stepping the job; previously current_level stayed
	# null until after construction, causing thousands of color-trigger errors.
	LevelManager.current_level = job.level
	if Config.paced_level_open:
		while not job.finished:
			job.step(Config.level_open_frame_budget_ms)
			await get_tree().process_frame
			if not is_inside_tree():
				# The player left while the level was still building.
				return
	else:
		while not job.finished:
			job.step(0x7fffffff)
	var level: Level = job.level
	_print_process_memory("level built")
	if not SceneManager.in_editor():
		SceneManager.set_current_scene(SceneManager.Scene.LEVEL)
	add_loaded_level(level, level_data)
	_print_process_memory("native runtime registered")

	var open_ms: int = Time.get_ticks_msec() - open_started_ms
	await start_level()
	if not is_inside_tree():
		return

	if not Editor.in_editor and open_ms > 400:
		var object_count := 0
		for layer_data: Dictionary in level_data.layers:
			object_count += layer_data.objects.size()
			object_count += PackedDecorations.size_of(layer_data.get(PackedDecorations.LAYER_KEY, { }))
		object_count += PackedTriggers.size_of(level_data.get(PackedTriggers.DATA_KEY, { }))
		var node_count := 0
		for layer: Layer in level.layers:
			node_count += layer.get_child_count()
		# The native runtime (GdashNative, bundled into the CI Android APK) loads
		# at startup regardless of Config.use_native_core; report whether the
		# library actually made it into this build so device tests can confirm
		# the C++ pipeline without logcat.
		var native_loaded := ClassDB.class_exists(&"GdashNative")
		Toasts.new_toast(
			"Level open: %.1f s · %d objects · %d nodes · native %s"
			% [open_ms / 1000.0, object_count, node_count, "yes" if native_loaded else "no"],
			6.0,
		)


func add_loaded_level(level: Level, level_data: Dictionary = {}) -> Level:
	LevelManager.current_level = level
	TextComponent.DEFAULT_TEXT_SETTINGS.set_font_path()
	if level.get_parent() != $Level:
		$Level.add_child(level, true)
	if not Editor.in_editor and NativeCore.available():
		if native_trigger_bridge != null:
			native_trigger_bridge.queue_free()
		native_trigger_bridge = NativeTriggerBridge.new()
		native_trigger_bridge.name = "NativeTriggerBridge"
		add_child(native_trigger_bridge)
		if not native_trigger_bridge.setup(level, level_data):
			native_trigger_bridge.queue_free()
			native_trigger_bridge = null
	return level


func start_level() -> void:
	var level: Level = LevelManager.current_level
	level.prepare_external_data()
	apply_gd_level_art(level)
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
	_print_process_memory("play start")


func restart_level() -> void:
	LevelManager.player.global_position = LevelManager.current_level.start_position
	LevelManager.player.process_mode = Node.PROCESS_MODE_INHERIT
	reset()
	var level: Level = LevelManager.current_level
	if LevelManager.practice_mode and LevelManager.practice_level_snapshots.size() > 0:
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
	ToggleComponent.reset_items()
	GDLevelOptions.reset()
	get_tree().call_group(DecorationBatch.MONSTER_BATCH_GROUP, &"reset_monster_animations")
	if native_trigger_bridge != null:
		native_trigger_bridge.reset_runtime()
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
	LevelManager.player.process_mode = Node.PROCESS_MODE_DISABLED
	LevelManager.player_camera.process_mode = Node.PROCESS_MODE_DISABLED
	$FadeScreen.fade_in()
	return PauseMenu.Leave.CONTINUE


## Verifies the compiled C++ runtime when Config.use_native_core is on.
##
## GdashNative only exists inside the CI Android APK (native/bin/gdash_native.gdextension;
## desktop/editor builds never load the library), so it is looked up through
## ClassDB rather than a typed reference - a static type would stop the whole
## script from parsing on platforms without the library.
func _probe_native_core() -> void:
	if not Config.use_native_core:
		return
	if not ClassDB.class_exists(&"GdashNative"):
		push_warning("Native core is enabled in Config but GdashNative is not loaded.")
		return
	var native: Object = ClassDB.instantiate(&"GdashNative")
	if native == null:
		push_warning("Native core is enabled in Config but GdashNative could not be instantiated.")
		return
	# str() accepts any Variant; String() only converts String/StringName/
	# NodePath, so String(int-returning calls) raised "Nonexistent 'String'
	# constructor" in every build's logcat and hid the self-check output.
	var build: Variant = native.call(&"build_string")
	var checksum: Variant = native.call(&"add", 2, 3)
	print("[gdash] native core loaded: %s (self-check add(2, 3) == %s, types %d/%d)" % [
		str(build), str(checksum), typeof(build), typeof(checksum),
	])


static func get_camera_rect(camera: Camera2D, viewport: Viewport) -> Rect2:
	var rect_pos := camera.get_screen_center_position()
	var rect_size := (viewport.get_visible_rect().size / camera.zoom)
	return Rect2(rect_pos - rect_size * 0.5, rect_size)


var _gd_mg_speed: Vector2 = GD_DEFAULT_MG_SPEED
var _gd_mg_offset: float = 0.0
var _gd_mg_parallax: Parallax2D
var _gd_mg_sprites: Array[Sprite2D] = []
var _gd_ground_layers: Array[Sprite2D] = []


## Shows the imported level's own background, ground and middleground (level
## header kA6 / kA7 / kA25) with the default speeds; called on every start so
## a restart undoes Change triggers. Non-GD levels (id -1) keep the scene art.
func apply_gd_level_art(level: Level) -> void:
	if level.gd_background_id < 0:
		return
	_gd_mg_speed = GD_DEFAULT_MG_SPEED
	_gd_mg_offset = 0.0
	($BackgroundParallax as Parallax2D).scroll_scale = GD_DEFAULT_BG_SPEED
	set_gd_art(0, level.gd_background_id)
	set_gd_art(1, level.gd_ground_id)
	set_gd_art(2, level.gd_middleground_id)


## [param kind] 0 background, 1 ground, 2 middleground; Change triggers
## 3029-3031 (key 533) and the level header.
func set_gd_art(kind: int, id: int) -> void:
	match kind:
		0:
			_set_gd_background(_gd_texture("backgrounds/game_bg_%02d_001" % clampi(maxi(id, 1), 1, GD_BG_COUNT)))
		1:
			var ground := clampi(maxi(id, 1), 1, GD_GROUND_COUNT)
			_set_gd_ground(
					_gd_texture("grounds/groundSquare_%02d_001" % ground),
					_gd_texture("grounds/groundSquare_%02d_2_001" % ground) if ground >= 8 else null,
			)
		2:
			var mg := clampi(id, 0, GD_MG_COUNT)
			_set_gd_middleground(
					_gd_texture("middlegrounds/fg_%02d_001" % mg) if mg > 0 else null,
					_gd_texture("middlegrounds/fg_%02d_2_001" % mg) if mg > 0 else null,
			)


func set_gd_mg_speed(speed: Vector2) -> void:
	_gd_mg_speed = speed
	if _gd_mg_parallax != null:
		_gd_mg_parallax.scroll_scale.x = speed.x


func set_gd_mg_offset(offset_gd: float) -> void:
	_gd_mg_offset = offset_gd


## The HD file; the normal one only if a set ever ships without HD.
func _gd_texture(base: String) -> Texture2D:
	for suffix: String in ["-hd.png", ".png"]:
		var path := GD_ART_DIR + base + suffix
		if ResourceLoader.exists(path):
			var texture := load(path) as Texture2D
			texture.set_meta(&"texel_px", GD_PX_PER_TEXEL * (1.0 if suffix == "-hd.png" else 2.0))
			return texture
	return null


## Tiled horizontally with its bottom edge on the floor; the flipped copy
## mirrors it below.
func _set_gd_background(texture: Texture2D) -> void:
	if texture == null:
		return
	var parallax := $BackgroundParallax as Parallax2D
	var texel: float = texture.get_meta(&"texel_px")
	var size := texture.get_size()
	var height := size.y * texel
	parallax.repeat_size = Vector2(size.x * texel, height * 2.0)
	parallax.repeat_times = maxi(3, ceili(GD_GROUND_SPAN_PX / (size.x * texel)))
	for sprite: Sprite2D in LevelManager.background_sprites:
		sprite.texture = texture
		sprite.scale = Vector2(texel, texel)
		sprite.region_enabled = true
		sprite.region_rect = Rect2(Vector2.ZERO, size)
		sprite.position.y = FLOOR_Y + (height * 0.5 if sprite.flip_v else -height * 0.5)


## The ground art goes on child sprites: the Ground sprites carry the floor
## and ceiling colliders, so their transform must not change. Layer 2 is
## tinted by G2 (1009) and hugs the surface.
func _set_gd_ground(texture: Texture2D, texture_2: Texture2D) -> void:
	if texture == null:
		return
	for layer: Sprite2D in _gd_ground_layers:
		layer.queue_free()
	_gd_ground_layers.clear()
	var texel: float = texture.get_meta(&"texel_px")
	var tile_px := texture.get_width() * texel
	var span_px := tile_px * ceilf(GD_GROUND_SPAN_PX / tile_px)
	for parallax: Parallax2D in [$GroundDownParallax as Parallax2D, $GroundUpParallax as Parallax2D]:
		parallax.repeat_size.x = span_px
	for ground: Sprite2D in [LevelManager.ground_down.get_node(^"Ground"), LevelManager.ground_up.get_node(^"Ground")]:
		var surface_y := ground.region_rect.size.y * 0.5 * (1.0 if ground.flip_v else -1.0)
		# The bundled art stops drawing; the colliders below stay put.
		ground.texture = null
		for layer_texture: Texture2D in [texture, texture_2]:
			if layer_texture == null:
				continue
			var layer := Sprite2D.new()
			layer.name = "GDGround" if layer_texture == texture else "GDGround2"
			layer.texture = layer_texture
			layer.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
			layer.centered = false
			layer.flip_v = ground.flip_v
			var local_scale := texel / ground.scale.x
			layer.scale = Vector2(local_scale, local_scale)
			layer.region_enabled = true
			layer.region_rect = Rect2(0.0, 0.0, span_px / texel, layer_texture.get_height())
			var height_local := layer_texture.get_height() * local_scale
			layer.position = Vector2(
					-span_px * 0.5 / ground.scale.x,
					surface_y - (height_local if ground.flip_v else 0.0),
			)
			if layer_texture == texture:
				layer.use_parent_material = true
				layer.self_modulate = Color(ground.self_modulate, 1.0)
				layer.set_meta(&"tint", -1)
			else:
				layer.z_index = 1
				layer.set_meta(&"tint", 1009)
			ground.add_child(layer)
			_gd_ground_layers.append(layer)


## Middleground layers (MG 1013, MG2 1014) between the background and B5.
func _set_gd_middleground(texture: Texture2D, texture_2: Texture2D) -> void:
	for sprite: Sprite2D in _gd_mg_sprites:
		sprite.queue_free()
	_gd_mg_sprites.clear()
	if texture == null:
		return
	if _gd_mg_parallax == null:
		_gd_mg_parallax = Parallax2D.new()
		_gd_mg_parallax.name = "MiddlegroundParallax"
		_gd_mg_parallax.z_index = -4095
		add_child(_gd_mg_parallax)
	var texel: float = texture.get_meta(&"texel_px")
	var tile := texture.get_width() * texel
	_gd_mg_parallax.scroll_scale = Vector2(_gd_mg_speed.x, 1.0)
	_gd_mg_parallax.repeat_size = Vector2(tile, 0.0)
	_gd_mg_parallax.repeat_times = maxi(3, ceili(GD_GROUND_SPAN_PX / tile))
	for layer: int in 2:
		var layer_texture: Texture2D = texture if layer == 0 else texture_2
		if layer_texture == null:
			continue
		var sprite := Sprite2D.new()
		sprite.texture = layer_texture
		sprite.centered = false
		sprite.offset = Vector2(0.0, -layer_texture.get_height())
		sprite.scale = Vector2(texel, texel)
		sprite.z_index = layer
		sprite.set_meta(&"tint", 1013 + layer)
		_gd_mg_parallax.add_child(sprite)
		_gd_mg_sprites.append(sprite)


func _process(_delta: float) -> void:
	if _gd_ground_layers.is_empty() and _gd_mg_sprites.is_empty():
		return
	var bridge := NativeTriggerBridge.current
	for layer: Sprite2D in _gd_ground_layers:
		var channel: int = layer.get_meta(&"tint")
		if channel < 0:
			layer.self_modulate = Color((layer.get_parent() as Sprite2D).self_modulate, 1.0)
		elif bridge != null:
			layer.self_modulate = bridge.live_channel_color(channel)
	var camera: Camera2D = LevelManager.player_camera
	if _gd_mg_sprites.is_empty() or camera == null:
		return
	# MGPosY = CPosY * (1 - SpeedY) + OffsetY (gd_docs mg_speed.md), GD units
	# with the floor at 0 and CPosY the bottom of the view. HYPOTHESIS: the
	# middleground's bottom edge sits at that height.
	var zoom := camera.get_zoom()
	var bottom_px := camera.get_screen_center_position().y + camera.get_viewport_rect().size.y * 0.5 / maxf(zoom.y, 0.001)
	var px_per_point := GD_PX_PER_TEXEL * 2.0
	var camera_gd := (FLOOR_Y - bottom_px) / px_per_point
	var mg_gd := camera_gd * (1.0 - _gd_mg_speed.y) + _gd_mg_offset
	for sprite: Sprite2D in _gd_mg_sprites:
		sprite.position.y = FLOOR_Y - mg_gd * px_per_point
		if bridge != null:
			sprite.self_modulate = bridge.live_channel_color(int(sprite.get_meta(&"tint")))
