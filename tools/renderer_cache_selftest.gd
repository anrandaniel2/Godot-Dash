extends Node
## Headless integration with the actual native renderer, not a model of it.
## Checks mutable drawing state and rebuild counts. This is NOT pixel/GPU proof.

var _checks: int = 0
var _failed: int = 0
var _canvas: Object
var _viewport: SubViewport
var _owner: Node2D
var _texture: ImageTexture


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failed += 1
		print("RENDERER_CACHE_FAIL %s" % message)


func _ready() -> void:
	if not ClassDB.class_exists(&"NativeDecorationRenderer"):
		print("RENDERER_CACHE_SELFTEST checks=1 failed=1 missing native renderer")
		get_tree().quit(1)
		return
	_canvas = ClassDB.instantiate(&"NativeDecorationRenderer")
	var coordinator: Node = ClassDB.instantiate(&"NativeLevelRuntime") as Node
	add_child(coordinator)
	# An isolated viewport avoids startup root-window resize/stretch changes.
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(512, 512)
	_viewport.disable_3d = true
	add_child(_viewport)
	_owner = Node2D.new()
	_viewport.add_child(_owner)
	var image: Image = Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	_texture = ImageTexture.create_from_image(image)
	await _test_record_updates()
	var probe: RID = RenderingServer.canvas_item_create()
	if probe.is_valid():
		RenderingServer.free_rid(probe)
		_test_draw_submission()
		_test_hsv_snapshots()
		print("RENDERER_CACHE_NOTE retained-command counters checked; no pixel/GPU validation")
	else:
		print(
			"RENDERER_CACHE_NOTE no canvas RIDs: state tests only; ordered selection tested separately in C++"
		)
	await _test_coalesced_commands()
	await _test_batch_processing()
	# Exit coordinator first: drain worker jobs before releasing the renderer.
	coordinator.free()
	_canvas = null
	_viewport.free()
	print("RENDERER_CACHE_SELFTEST checks=%d failed=%d" % [_checks, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


func _test_draw_submission() -> void:
	_canvas.call(&"set_group_pulse", Color.WHITE, 0.0)
	_configure(Color.WHITE)
	# Keep these assertions synchronous: exercise the production flush method,
	# not asynchronous startup viewport changes or cull-worker scheduling.
	_canvas.call(&"update_camera_range")
	_canvas.call(&"flush_commands")
	_check(int(_canvas.call(&"last_drawn_count")) == 2, "initial records submitted")
	var commands: int = int(_canvas.call(&"command_rebuild_count"))
	var selections: int = int(_canvas.call(&"selection_rebuild_count"))
	_canvas.call(&"apply_channel_color", PackedInt32Array([0, 1]), Color.WHITE)
	_canvas.call(&"set_item_transform", 0, Transform2D.IDENTITY)
	_canvas.call(&"set_item_color", 0, Color.WHITE)
	_canvas.call(&"flush_commands")
	_check(
		int(_canvas.call(&"command_rebuild_count")) == commands, "identical updates do not rebuild"
	)
	_canvas.call(&"apply_channel_color", PackedInt32Array([0, 1]), Color.GREEN)
	_canvas.call(&"flush_commands")
	_check(_canvas.call(&"get_item_color", 0) == Color.GREEN, "live color updated")
	_check(
		int(_canvas.call(&"command_rebuild_count")) == commands + 1, "changed color rebuilds once"
	)
	_check(
		int(_canvas.call(&"selection_rebuild_count")) == selections,
		"color redraw reuses ordered IDs"
	)
	_canvas.call(&"set_channel_blending", PackedInt32Array([0]), true)
	_canvas.call(&"flush_commands")
	_check(int(_canvas.call(&"get_item_blend", 0)) == 1, "blend override still applied")
	commands = int(_canvas.call(&"command_rebuild_count"))
	_canvas.call(&"set_channel_blending", PackedInt32Array([0]), true)
	_canvas.call(&"flush_commands")
	_check(int(_canvas.call(&"command_rebuild_count")) == commands, "repeated blend is a no-op")
	var moved: Transform2D = Transform2D(0.1, Vector2(16, 16))
	_canvas.call(&"set_item_transform", 0, moved)
	_canvas.call(&"flush_commands")
	_check(_canvas.call(&"get_item_transform", 0) == moved, "latest transform preserved")
	_check(
		int(_canvas.call(&"selection_rebuild_count")) == selections,
		"transform redraw reads live record"
	)
	commands = int(_canvas.call(&"command_rebuild_count"))
	_canvas.call(&"set_group_pulse", Color.RED, 0.5)
	_canvas.call(&"flush_commands")
	_check(int(_canvas.call(&"command_rebuild_count")) == commands + 1, "group pulse redraws")
	_check(
		int(_canvas.call(&"selection_rebuild_count")) == selections, "pulse keeps cached IDs only"
	)
	_canvas.call(&"set_group_pulse", Color.WHITE, 0.0)
	_canvas.call(&"set_item_color", 0, Color.GREEN)
	_canvas.call(&"flush_commands")
	_check(
		int(_canvas.call(&"command_rebuild_count")) == commands + 2,
		"no-op keeps earlier pulse dirty"
	)
	# Same record count and viewport, new records: cannot reuse old selection.
	_configure(Color.BLUE)
	_canvas.call(&"update_camera_range")
	_canvas.call(&"flush_commands")
	_check(
		int(_canvas.call(&"selection_rebuild_count")) > selections,
		"reconfigure invalidates selection"
	)
	_check(_canvas.call(&"get_item_color", 0) == Color.BLUE, "reconfigure replaces record data")


func _configure(color: Color, cull_records: bool = true, spin: float = 0.0) -> void:
	var hsv: PackedFloat32Array = PackedFloat32Array()
	hsv.resize(10)
	hsv.fill(-1.0)
	_canvas.call(
		&"configure",
		_owner,
		[_texture, _texture],
		[Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8)],
		[Transform2D.IDENTITY, Transform2D(0.0, Vector2(4, 4))],
		PackedColorArray([color, color]),
		PackedFloat32Array([0, 4]),
		PackedFloat32Array([1, 1]),
		hsv,
		PackedFloat32Array([spin, spin]),
		PackedFloat32Array([0, 0, 4, 4]),
		cull_records,
		256.0,
		0.0
	)


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame


func _test_batch_processing() -> void:
	var spinner: DecorationBatch = DecorationBatch.new()
	var item: DecorationBatch.Item = DecorationBatch.Item.new()
	item.texture = _texture
	item.region = Rect2(0, 0, 8, 8)
	item.spin = 90.0
	spinner.add_item(item)
	spinner.build()
	add_child(spinner)
	_check(not spinner.is_processing(), "native spinning batch has no redundant script callback")
	var native: Object = spinner.get("_native_canvas")
	native.call(&"advance_animation", 0.5)
	var spun: Transform2D = native.call(&"get_item_transform", 0)
	_check(is_equal_approx(spun.get_rotation(), PI / 4.0), "native spin remains active")
	spinner.free()
	native = null

	var animated: DecorationBatch = DecorationBatch.new()
	var monster: DecorationBatch.Monster = DecorationBatch.Monster.new()
	monster.name = "GJBeast01"
	monster.animation = "bite"
	animated.monsters.append(monster)
	animated.build()
	add_child(animated)
	_check(animated.is_processing(), "monster without spin still processes after ready")
	animated.build()
	_check(animated.is_processing(), "in-tree rebuild preserves monster processing")
	var clip: Dictionary = MonsterAnimations.monster(monster.name).get("animations", {}).get(
		"bite", {}
	)
	var delay: float = maxf(float(clip.get("delay", 0.05)), 0.001)
	animated.call(&"_process", delay * 1.5)
	_check(
		monster.frame == 1 and is_equal_approx(monster.elapsed, delay * 0.5),
		"monster clip keeps its original clock"
	)
	animated.free()

	# An ordinary item-backed batch must also remain disabled after READY.
	var ordinary: DecorationBatch = DecorationBatch.new()
	var still: DecorationBatch.Item = DecorationBatch.Item.new()
	still.texture = _texture
	still.region = Rect2(0, 0, 8, 8)
	ordinary.add_item(still)
	ordinary.build()
	add_child(ordinary)
	_check(not ordinary.is_processing(), "static item-backed batch stays disabled after ready")
	ordinary.free()

	# Reproduce the large native-adoption population without artwork allocations.
	# These are real production DecorationBatch nodes, not a callback model.
	var batches: Array[DecorationBatch] = []
	for index: int in 2000:
		var batch: DecorationBatch = DecorationBatch.new()
		batch.adopt_native_canvas(null, {})
		add_child(batch)
		_check(not batch.is_processing(), "native adoption stays disabled after ready")
		batches.append(batch)
	var baseline: Array[float] = []
	var optimized: Array[float] = []
	for trial: int in 3:
		if trial % 2 == 0:
			baseline.append(await _measure_callbacks(batches, true))
			optimized.append(await _measure_callbacks(batches, false))
		else:
			optimized.append(await _measure_callbacks(batches, false))
			baseline.append(await _measure_callbacks(batches, true))
	baseline.sort()
	optimized.sort()
	print(
		(
			"BATCH_CALLBACK_BENCH nodes=2000 frames=100 baseline_ms=%.3f optimized_ms=%.3f"
			% [baseline[1], optimized[1]]
		)
	)
	for batch: DecorationBatch in batches:
		batch.free()


func _measure_callbacks(batches: Array[DecorationBatch], enabled: bool) -> float:
	# Baseline explicitly restores Godot's previous ready-time auto-enable.
	# Mode switches and two settling frames are excluded from timing.
	for batch: DecorationBatch in batches:
		batch.set_process(enabled)
	await _settle()
	var start: int = Time.get_ticks_usec()
	for frame: int in 100:
		await get_tree().process_frame
	return float(Time.get_ticks_usec() - start) / 1000.0


func _test_record_updates() -> void:
	_configure(Color.WHITE, false)
	await _settle()
	_check(int(_canvas.call(&"item_count")) == 2, "native records configured")
	_check(not _canvas.call(&"has_pending_redraw"), "initial command state clean")
	_canvas.call(&"apply_channel_color", PackedInt32Array([0, 1]), Color.WHITE)
	_canvas.call(&"set_item_transform", 0, Transform2D.IDENTITY)
	_canvas.call(&"set_item_color", 0, Color.WHITE)
	_check(
		not _canvas.call(&"has_pending_redraw"), "identical updates do not dirty native commands"
	)
	_canvas.call(&"apply_channel_color", PackedInt32Array([0, 1]), Color.GREEN)
	_check(_canvas.call(&"get_item_color", 0) == Color.GREEN, "native color updated")
	_check(_canvas.call(&"has_pending_redraw"), "changed color requests redraw")
	_canvas.call(&"set_item_color", 0, Color.GREEN)
	_check(_canvas.call(&"has_pending_redraw"), "no-op preserves earlier dirty state")
	await _settle()
	_check(not _canvas.call(&"has_pending_redraw"), "coordinator consumes dirty commands")
	_canvas.call(&"set_channel_blending", PackedInt32Array([0]), true)
	_check(_canvas.call(&"has_pending_redraw"), "changed blend requests redraw")
	_check(int(_canvas.call(&"get_item_blend", 0)) == 1, "native blend override applied")
	await _settle()
	_canvas.call(&"set_channel_blending", PackedInt32Array([0]), true)
	_check(not _canvas.call(&"has_pending_redraw"), "identical blend does not dirty commands")
	var moved: Transform2D = Transform2D(0.1, Vector2(16, 16))
	_canvas.call(&"set_item_transform", 0, moved)
	_check(_canvas.call(&"get_item_transform", 0) == moved, "native transform updated")
	_check(_canvas.call(&"has_pending_redraw"), "changed transform requests redraw")
	await _settle()
	_canvas.call(&"set_group_pulse", Color.RED, 0.5)
	_check(_canvas.call(&"has_pending_redraw"), "pulse requests redraw")
	await _settle()
	_canvas.call(&"set_group_pulse", Color.RED, 0.5)
	_check(not _canvas.call(&"has_pending_redraw"), "identical pulse keeps command state clean")
	_configure(Color.BLUE, false)
	_check(_canvas.call(&"get_item_color", 0) == Color.BLUE, "same-size reconfigure replaces data")


func _test_coalesced_commands() -> void:
	_configure(Color.WHITE, true, 90.0)
	await _settle()
	var previous: int = int(_canvas.call(&"command_rebuild_count"))
	var started: int = previous
	var selections: int = int(_canvas.call(&"selection_rebuild_count"))
	var maximum: int = 0
	for frame: int in 120:
		# Both records remain visible, but cell bounds change repeatedly while
		# real coordinator spin and channel pulses also dirty the same canvas.
		_owner.position.x = 256.0 if (frame / 4) % 2 == 0 else 0.0
		_canvas.call(&"set_group_pulse", Color(float(frame) / 120.0, 0.5, 1.0), 0.5)
		await get_tree().process_frame
		var current: int = int(_canvas.call(&"command_rebuild_count"))
		maximum = maxi(maximum, current - previous)
		_check(current - previous <= 1, "range/spin/pulse coalesce to one command rebuild per frame")
		previous = current
	var range_changes: int = int(_canvas.call(&"selection_rebuild_count")) - selections
	_check(previous > started, "coordinator still submits changing animation")
	_check(range_changes >= 2, "coalescing fixture actually exercises changed cell ranges")
	_check(int(_canvas.call(&"last_drawn_count")) == 2, "coalescing retains both visible records")
	print("RENDERER_COALESCE frames=120 rebuilds=%d max_per_frame=%d range_changes=%d" % [previous - started, maximum, range_changes])
	_owner.position = Vector2.ZERO
	_canvas.call(&"set_group_pulse", Color.WHITE, 0.0)
	_configure(Color.WHITE)


func _test_hsv_snapshots() -> void:
	var poses: Array = [Transform2D.IDENTITY, Transform2D.IDENTITY, Transform2D.IDENTITY, Transform2D.IDENTITY]
	var regions: Array = [Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8)]
	var hsv: PackedFloat32Array = PackedFloat32Array([0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 1, 1, 0.1, 1, 1, 0, 0])
	var color: Color = Color(0.25, 0.5, 0.8, 0.6)
	for pass_index: int in 2:
		_canvas.call(&"configure", _owner, [_texture, _texture, _texture, _texture], regions, poses,
			PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE]), PackedFloat32Array([0, 0, 0, 0]),
			PackedFloat32Array([1, 1, 1, 1]), hsv, PackedFloat32Array(), PackedFloat32Array(), false, 256.0, 0.0)
		_canvas.call(&"apply_channel_color", PackedInt32Array([0, 1, 2, 3]), color)
		for index: int in 3:
			_check(_canvas.call(&"get_item_color", index) == color, "neutral HSV snapshots preserve exact channel RGB")
		if pass_index == 0:
			var expected: Color = color
			expected.s *= 1.0
			expected.v *= 1.0
			expected.h += 0.1
			var actual: Color = _canvas.call(&"get_item_color", 3)
			_check(actual.is_equal_approx(expected), "non-neutral HSV remains live")
		else:
			_check(_canvas.call(&"get_item_color", 3) == color, "same-size reconfigure rebuilds HSV classification")
		hsv.fill(0.0)
