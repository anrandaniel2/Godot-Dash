extends Node
## Production-path, headless regressions. No GPU/pixel/physical-monitor claims.

var _checks := 0
var _failed := 0

class VisibilityLevel extends Node2D:
	func apply_gd_player_visibility(visible: bool) -> void:
		GDLevelOptions.set_players_visible(visible)


func _check(value: bool, message: String) -> void:
	_checks += 1
	if not value:
		_failed += 1
		print("PRESENTATION_FAIL " + message)


func _ready() -> void:
	_test_version()
	_test_visibility()
	_test_death_and_end()
	_test_ui()
	print("PRESENTATION_SELFTEST checks=%d failed=%d" % [_checks, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


func _test_version() -> void:
	var build_key := "application/config/windows_build_number"
	var sha_key := "application/config/windows_build_sha"
	var old_build: Variant = ProjectSettings.get_setting(build_key)
	var old_sha: Variant = ProjectSettings.get_setting(sha_key)
	ProjectSettings.set_setting(build_key, 42)
	ProjectSettings.set_setting(sha_key, "1234567890abcdef")
	_check(UpdateManager.display_version() == "v%s · Build 42 (12345678)" % UpdateManager.version, "installed version and build identity")
	ProjectSettings.set_setting(build_key, 0)
	ProjectSettings.set_setting(sha_key, "")
	_check(UpdateManager.display_version() == "v%s" % UpdateManager.version, "unmanaged build has actual version")
	ProjectSettings.set_setting(build_key, old_build)
	ProjectSettings.set_setting(sha_key, old_sha)
	var button := preload("res://src/UpdateChecker.gd").new()
	var old_status: int = UpdateManager.status
	for status: int in [UpdateManager.Status.UP_TO_DATE, UpdateManager.Status.DISABLED, UpdateManager.Status.FAILED, UpdateManager.Status.OUT_OF_DATE]:
		UpdateManager.status = status
		button.refresh()
		_check(button.text.begins_with(UpdateManager.display_version()), "every update state retains version")
	UpdateManager.status = old_status
	button.free()


func _test_visibility() -> void:
	# Off-tree players exercise real visual state without running physics.
	var primary := Player.new()
	var dual := Player.new()
	dual.dual_index = 1
	LevelManager.player = primary
	LevelManager.player_duals.assign([dual])
	GDLevelOptions.reset()
	var level := VisibilityLevel.new()
	add_child(level)
	var runtime: Node = ClassDB.instantiate(&"NativeLevelRuntime")
	add_child(runtime)
	runtime.call(&"bind_context", level, null, null)
	runtime.call(&"register_packed_trigger", 10.0, 0.0, 0, 0, PackedStringArray(), 1612, {"1": "1612"})
	runtime.call(&"register_packed_trigger", 20.0, 0.0, 0, 1, PackedStringArray(), 1613, {"1": "1613"})
	runtime.call(&"finalize")
	var mask: int = primary.collision_mask
	runtime.call(&"prime_spawn", primary)
	primary.position.x = 15.0
	runtime.call(&"prime_spawn", primary)
	_check(primary.gd_hidden and dual.gd_hidden, "native Hide affects both players")
	_check(primary.modulate.a == 0.0 and dual.modulate.a == 0.0, "native Hide covers player visuals")
	_check(primary.collision_mask == mask, "Hide preserves player collision mask")
	GDLevelOptions.apply({"576": "1"})
	_check(primary.gd_hidden and dual.gd_hidden, "unrelated options cannot undo Hide")
	var late_dual := Player.new()
	late_dual.dual_index = 2
	GDLevelOptions.refresh_player(late_dual)
	_check(late_dual.gd_hidden, "late dual inherits Hide via same helper as Player.ready")
	GDLevelOptions.apply({"162": "-1"})
	_check(not primary.gd_hidden and dual.gd_hidden, "Options may show P1 independently")
	primary.position.x = 25.0
	runtime.call(&"prime_spawn", primary)
	_check(not primary.gd_hidden and not dual.gd_hidden, "native Show affects both players")
	var twin := GameplayTriggerComponent.new()
	twin.kind = GameplayTriggerComponent.Kind.HIDE_PLAYER
	twin._on_interacted(primary)
	_check(primary.gd_hidden and dual.gd_hidden, "component Hide parity")
	twin.kind = GameplayTriggerComponent.Kind.SHOW_PLAYER
	twin._on_interacted(primary)
	_check(not primary.gd_hidden and not dual.gd_hidden, "component Show parity")
	GDLevelOptions.set_players_visible(false)
	GDLevelOptions.reset() # Same reset invoked by GameScene before runtime reset.
	runtime.call(&"reset")
	_check(primary.modulate.a == 1.0 and dual.modulate.a == 1.0, "attempt reset restores visibility")
	for id: int in [1612, 1613]:
		_check("GameplayTriggerComponent" in GMDObjects.MAP[id].components, "import maps visibility component twin")
	twin.free()
	runtime.free()
	level.free()
	LevelManager.player = null
	LevelManager.player_duals.clear()
	primary.free()
	dual.free()
	late_dual.free()


func _register_components(node: Node) -> void:
	# Reproduce component registration off-tree; avoid gameplay/editor hooks.
	for child: Node in node.get_children():
		if child is Component:
			child.parent = node
			node.register_public(child)
		_register_components(child)


func _test_death_and_end() -> void:
	var player: Player = preload("res://scenes/components/game_components/Player.tscn").instantiate()
	player._icon = player.get_node(^"Icon")
	player._death_effect = player.get_node(^"DeathEffect")
	player._death_particles = player.get_node(^"DeathParticles")
	player._dash_particles = player.get_node(^"DashParticles")
	player._ground_particles = player.get_node(^"%GroundParticles")
	player._trail = player.get_node(^"%Trail")
	GDLevelOptions.no_death_sfx = true
	GDLevelOptions.audio_on_death = true
	player._player_death()
	_check(player.dead and not player._icon.visible, "normal death hides icon")
	_check(player._death_effect.is_playing() and player._death_effect.frame == 0, "normal death starts animation")
	_check(not get_tree().paused, "death never pauses tree")
	var animation: Animation = player.get_node(^"DeathAnimator").get_animation(&"DeathAnimation")
	_check(animation.method_track_get_name(0, 0) == &"_player_death", "death track invokes normal effects")
	_check(animation.method_track_get_name(0, 1) == &"_on_death_restart", "death track retains restart callback")
	var frames: SpriteFrames = player._death_effect.sprite_frames
	var effect_duration: float = frames.get_frame_count(&"default") / frames.get_animation_speed(&"default")
	_check(animation.track_get_key_time(0, 1) > effect_duration, "restart follows effect with a short delay")
	GDLevelOptions.reset()

	var level := Level.new()
	var layer := Node2D.new()
	layer.name = GMDConverter.IMPORTED_LAYER_NAME
	level.add_child(layer)
	LevelManager.current_level = level
	var camera := PlayerCamera.new()
	LevelManager.player_camera = camera
	var entry: Dictionary = GMDConverter._level_end_entry(10000.0)
	_check(entry.components.EndLevelComponent.gd_import, "synthetic end is marked imported")
	for mode: int in 3: # New import, saved legacy import, authored trigger.
		var trigger: TriggerInteractable = load(GMDConverter.LEVEL_END_SCENE).instantiate()
		trigger.name = GMDConverter.LEVEL_END_NAME if mode < 2 else "AuthoredEnd"
		trigger.position = Vector2(10000, -4000)
		layer.add_child(trigger)
		_register_components(trigger)
		var end: EndLevelComponent = trigger.query(EndLevelComponent)
		end.gd_import = mode == 0
		trigger.query(TargetObjectComponent).target = level.get_path_to(trigger)
		EndLevelComponent._ended = false
		camera.position = Vector2(100, 600)
		camera.static_factor = Vector2.ZERO
		end.start(player)
		var static_camera: CameraStaticComponent = end.static_trigger.query(CameraStaticComponent)
		_check(static_camera.axis == (Constants.Axis.X if mode < 2 else Constants.Axis.BOTH), "end static axis: mode %d" % mode)
		static_camera.start(player)
		end.static_trigger.query(EasingComponent).weights[player] = 0.5
		static_camera._on_easing_progressed(player, 0.5)
		_check(is_equal_approx(camera.position.y, 600.0 if mode < 2 else -1700.0), "actual end/static easing Y: mode %d" % mode)
		trigger.free()
	EndLevelComponent._ended = false
	LevelManager.current_level = null
	LevelManager.player_camera = null
	level.free()
	camera.free()
	player.free()


func _test_ui() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1920, 1080)
	viewport.disable_3d = true
	add_child(viewport)
	var level := Node2D.new()
	level.position = Vector2(640, 925)
	viewport.add_child(level)
	var guide := Node2D.new()
	guide.position = Vector2(40000, -500)
	level.add_child(guide)
	var batch := DecorationBatch.new()
	level.add_child(batch)
	var image := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var texture := ImageTexture.create_from_image(image)
	var left := Vector2(38987.5, -500)
	var right := Vector2(41012.5, -500)
	var poses: Array = [Transform2D(0, left), Transform2D(0, right), Transform2D(0, left + Vector2(20, 0))]
	var canvas: Object = ClassDB.instantiate(&"NativeDecorationRenderer")
	canvas.call(&"configure", batch, [texture, texture, texture], [Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8)], poses,
		PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE]), PackedFloat32Array([left.x, right.x, left.x]),
		PackedFloat32Array([1, 1, 1]), PackedFloat32Array(), PackedFloat32Array([90, 0, 90]),
		PackedFloat32Array([left.x, left.y, right.x, right.y, left.x, left.y]), true, 256.0, 0.0)
	batch.adopt_native_canvas(canvas, {})
	var runtime: Node = ClassDB.instantiate(&"NativeLevelRuntime")
	viewport.add_child(runtime)
	runtime.call(&"bind_context", level, null, null)
	# NativeLevelRuntime snapshots actual level-scoped scene groups at finalize.
	batch.add_to_group(&"g_1")
	guide.add_to_group(&"g_2")
	runtime.call(&"register_packed_trigger", 0.0, 0.0, 0, 0, PackedStringArray(), 3613,
		{"1": "3613", "51": "1", "71": "2", "385": "2", "387": "1"})
	runtime.call(&"finalize")
	_check(batch.get_parent().name == "UIRoot", "production UI reparents batch")
	# Single-precision transforms at 40k world units need subpixel tolerance;
	# 0.02 px is still far below the old hundreds-of-pixels alignment error.
	for width: int in [1920, 2560, 1920]:
		viewport.size = Vector2i(width, 1080)
		runtime.call(&"apply_ui_triggers")
		canvas.call(&"flush_commands")
		var a: Transform2D = canvas.call(&"get_draw_transform", 0)
		var b: Transform2D = canvas.call(&"get_draw_transform", 1)
		var part: Transform2D = canvas.call(&"get_draw_transform", 2)
		var world: Transform2D = batch.get_global_transform_with_canvas()
		_check((world * a.origin).distance_to(Vector2(0, 540)) < 0.02, "left art reaches screen edge at %d" % width)
		_check((world * b.origin).distance_to(Vector2(width, 540)) < 0.02, "right art reaches screen edge at %d" % width)
		_check((part.origin - a.origin).is_equal_approx(Vector2(20, 0)), "composite parts stay rigid")
		_check(a.x == Vector2.RIGHT and a.y == Vector2.DOWN, "UI never stretches sprite geometry")
		_check(int(canvas.call(&"last_drawn_count")) == 3, "world culling cannot drop UI side art")
		_check(canvas.call(&"get_item_transform", 0) == poses[0], "original placement retained")
	# Resize while a live group scale/move is active, without replaying it.
	batch.transform = Transform2D(0.0, Vector2(2, 2), 0.0, Vector2(100, 50)) * batch.transform
	viewport.size = Vector2i(2560, 1080)
	runtime.call(&"apply_ui_triggers")
	var resized_left: Transform2D = canvas.call(&"get_draw_transform", 0)
	_check((batch.get_global_transform_with_canvas() * resized_left.origin).distance_to(Vector2(-1200, 580)) < 0.02, "resize retains live group scale and move")
	canvas.call(&"advance_animation", 1.0)
	var spun: Transform2D = canvas.call(&"get_draw_transform", 2)
	var base: Transform2D = canvas.call(&"get_draw_transform", 0)
	_check((spun.origin - base.origin).is_equal_approx(Vector2(0, 20)), "multi-part spin uses original object pivot")
	runtime.call(&"restore_ui_objects")
	_check(batch.get_parent() == level and batch.position == Vector2.ZERO, "UI reset restores parent and transform")
	_check(canvas.call(&"get_draw_transform", 2) == canvas.call(&"get_item_transform", 2), "UI reset removes alignment without discarding animation")
	runtime.free()
	canvas = null
	viewport.free()
