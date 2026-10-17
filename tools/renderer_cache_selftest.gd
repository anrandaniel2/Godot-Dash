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


func _test_texture_readback() -> void:
	# CPU-only compressed-block fixtures: no renderer readback or encoder needed.
	var blocks: Array[PackedByteArray] = [
		PackedByteArray([0, 248, 0, 0, 0, 0, 0, 0]),
		PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
	]
	var formats: Array[Image.Format] = [Image.FORMAT_DXT1, Image.FORMAT_ETC2_RGBA8]
	for index: int in formats.size():
		var image: Image = Image.create_from_data(4, 4, false, formats[index], blocks[index])
		var decoded: Image = TextureReadback.prepare(image)
		_check(decoded != null and not decoded.is_compressed(), "compressed CPU image decoded")
		if decoded != null:
			_check(decoded.get_format() == Image.FORMAT_RGBA8, "readback blend format")
			_check(
				decoded.get_region(Rect2i(0, 0, 2, 2)).get_size() == Vector2i(2, 2), "decoded crop"
			)
			if index == 0:
				_check(decoded.get_pixel(0, 0).r > 0.99, "DXT1 red block decoded")


func _ready() -> void:
	_test_texture_readback()
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
	_owner.material = load("res://resources/FadeEnterEffect.tres")
	_viewport.add_child(_owner)
	var image: Image = Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	_texture = ImageTexture.create_from_image(image)
	await _test_record_updates()
	_test_spin_reconfiguration()
	_test_channel_tint_updates()
	var probe: RID = RenderingServer.canvas_item_create()
	if probe.is_valid():
		RenderingServer.free_rid(probe)
		_test_compact_spatial_reconfigure()
		_test_draw_submission()
		_test_gpu_renderer_backends()
		_test_ordered_rect_submissions()
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
	var main_route_rebuilds: int = int(_canvas.call(&"route_rebuild_count", 0))
	var plain_route_rebuilds: int = int(_canvas.call(&"route_rebuild_count", 1))
	var add_route_rebuilds: int = int(_canvas.call(&"route_rebuild_count", 2))
	_canvas.call(&"apply_channel_color", PackedInt32Array([0, 1]), Color.GREEN)
	_canvas.call(&"flush_commands")
	_check(_canvas.call(&"get_item_color", 0) == Color.GREEN, "live color updated")
	_check(
		int(_canvas.call(&"command_rebuild_count")) == commands + 1, "changed color rebuilds once"
	)
	_check(
		int(_canvas.call(&"route_rebuild_count", 0)) == main_route_rebuilds + 1
		and int(_canvas.call(&"route_rebuild_count", 1)) == plain_route_rebuilds
		and int(_canvas.call(&"route_rebuild_count", 2)) == add_route_rebuilds,
		"color edit rebuilds only its current blend route",
	)
	_check(
		int(_canvas.call(&"selection_rebuild_count")) == selections,
		"color redraw reuses ordered IDs"
	)
	main_route_rebuilds = int(_canvas.call(&"route_rebuild_count", 0))
	plain_route_rebuilds = int(_canvas.call(&"route_rebuild_count", 1))
	add_route_rebuilds = int(_canvas.call(&"route_rebuild_count", 2))
	_canvas.call(&"set_channel_blending", PackedInt32Array([0]), true)
	_canvas.call(&"flush_commands")
	_check(int(_canvas.call(&"get_item_blend", 0)) == 1, "blend override still applied")
	_check(
		int(_canvas.call(&"route_rebuild_count", 0)) == main_route_rebuilds + 1
		and int(_canvas.call(&"route_rebuild_count", 1)) == plain_route_rebuilds
		and int(_canvas.call(&"route_rebuild_count", 2)) == add_route_rebuilds + 1,
		"blend change rebuilds only the old and new routes",
	)
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


func _test_gpu_renderer_backends() -> void:
	# Construction/state checks exercise real RenderingServer mesh and instance
	# resources; they are not rendered-pixel, GPU-time, or parity evidence.
	for backend: int in [1, 2]:
		_canvas.call(&"set_render_backend", backend)
		_configure(Color.WHITE, false)
		_canvas.call(&"flush_commands")
		_check(int(_canvas.call(&"last_drawn_count")) == 2, "GPU backend submits every record")
		var expected_batches: int = 1
		_check(
			int(_canvas.call(&"draw_commands_last_rebuild")) == expected_batches,
			"both GPU backends batch same-texture atlas regions",
		)
		var route_before: int = int(_canvas.call(&"route_rebuild_count", 0))
		var commands_before: int = int(_canvas.call(&"command_rebuild_count"))
		_canvas.call(&"set_item_color", 0, Color.GREEN)
		_canvas.call(&"flush_commands")
		_check(int(_canvas.call(&"command_rebuild_count")) == commands_before + 1, "GPU record update flushes")
		_check(int(_canvas.call(&"route_rebuild_count", 0)) == route_before, "GPU attribute update retains route batch")
		_canvas.call(&"set_item_transform", 0, Transform2D(0.1, Vector2(12, 12)))
		_canvas.call(&"flush_commands")
		_canvas.call(&"set_group_pulse", Color.RED, 0.5)
		_canvas.call(&"flush_commands")
		_canvas.call(&"set_group_pulse", Color.WHITE, 0.0)
		_canvas.call(&"flush_commands")
		_canvas.call(&"set_channel_blending", PackedInt32Array([0]), true)
		_canvas.call(&"flush_commands")
		_check(int(_canvas.call(&"last_drawn_count")) == 2, "GPU blend re-route preserves item count")
	_canvas.call(&"set_render_backend", 0)
	_configure(Color.WHITE, false)
	_canvas.call(&"flush_commands")


func _configure(color: Color, cull_records: bool = true, spin: float = 0.0) -> void:
	var hsv: PackedFloat32Array = PackedFloat32Array()
	hsv.resize(10)
	hsv.fill(-1.0)
	_canvas.call(
		&"configure",
		_owner,
		[_texture, _texture],
		[Rect2(0, 0, 4, 8), Rect2(4, 0, 4, 8)],
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


func _spin_reference(t: Transform2D, pivot: Vector2, degrees: float, delta: float) -> Transform2D:
	if degrees == 0.0 or delta <= 0.0:
		return t
	# Match the native import's two float roundings, then its double angle.
	var factor: float = PackedFloat32Array([0.01745329251994329577])[0]
	var radians: float = PackedFloat32Array([degrees * factor])[0]
	var c: float = cos(radians * delta)
	var sn: float = sin(radians * delta)
	var dx: float = float(t.origin.x) - float(pivot.x)
	var dy: float = float(t.origin.y) - float(pivot.y)
	return Transform2D(
		Vector2(c * t.x.x - sn * t.x.y, sn * t.x.x + c * t.x.y),
		Vector2(c * t.y.x - sn * t.y.y, sn * t.y.x + c * t.y.y),
		Vector2(pivot.x + c * dx - sn * dy, pivot.y + sn * dx + c * dy)
	)


func _test_spin_reconfiguration() -> void:
	# Same count each time: cached runs -> uncached -> static -> cached pairs.
	# These must rebuild the profile, not reuse state from the previous batch.
	var patterns: Array[PackedFloat32Array] = [
		PackedFloat32Array([90, 90, 90, 90]),
		PackedFloat32Array([90, -90, 90, -90]),
		PackedFloat32Array([0, 0, 0, 0]),
		PackedFloat32Array([45, 45, -90, -90]),
	]
	var pivots: Array[Vector2] = [Vector2(0, 0), Vector2(4, 4), Vector2(-8, 3), Vector2(2, -5)]
	for speeds: PackedFloat32Array in patterns:
		var expected: Array[Transform2D] = [
			Transform2D(Vector2(-2, 0.25), Vector2(0.5, 1.5), Vector2(10, 3)),
			Transform2D(Vector2(1, -0.25), Vector2(0.5, -1.5), Vector2(-10, 4)),
			Transform2D(0.25, Vector2(5, -8)),
			Transform2D(-0.5, Vector2(12, 12)),
		]
		_canvas.call(
			&"configure",
			_owner,
			[_texture, _texture, _texture, _texture],
			[Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8)],
			expected,
			PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE]),
			PackedFloat32Array([10, -10, 5, 12]),
			PackedFloat32Array([1, 1, 1, 1]),
			PackedFloat32Array(),
			speeds,
			PackedFloat32Array([0, 0, 4, 4, -8, 3, 2, -5]),
			true,
			256.0,
			0.0
		)
		for delta: float in [0.0, -1.0, 0.5, 0.01, 0.125]:
			if delta == 0.01:
				expected[1] = Transform2D(-0.75, Vector2(8, -12))
				_canvas.call(&"set_item_transform", 1, expected[1])
			_canvas.call(&"advance_animation", delta)
			for i: int in expected.size():
				expected[i] = _spin_reference(expected[i], pivots[i], speeds[i], delta)
				var actual: Transform2D = _canvas.call(&"get_item_transform", i)
				_check(
					actual.is_equal_approx(expected[i]),
					"spin profile/reconfigure/live transform parity"
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
		_check(
			current - previous <= 1, "range/spin/pulse coalesce to one command rebuild per frame"
		)
		previous = current
	var range_changes: int = int(_canvas.call(&"selection_rebuild_count")) - selections
	_check(previous > started, "coordinator still submits changing animation")
	_check(range_changes >= 2, "coalescing fixture actually exercises changed cell ranges")
	_check(int(_canvas.call(&"last_drawn_count")) == 2, "coalescing retains both visible records")
	print(
		(
			"RENDERER_COALESCE frames=120 rebuilds=%d max_per_frame=%d range_changes=%d"
			% [previous - started, maximum, range_changes]
		)
	)
	_owner.position = Vector2.ZERO
	_canvas.call(&"set_group_pulse", Color.WHITE, 0.0)
	_configure(Color.WHITE)


func _test_hsv_snapshots() -> void:
	var poses: Array = [
		Transform2D.IDENTITY, Transform2D.IDENTITY, Transform2D.IDENTITY, Transform2D.IDENTITY
	]
	var regions: Array = [
		Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8)
	]
	var hsv: PackedFloat32Array = PackedFloat32Array(
		[0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 1, 1, 0.1, 1, 1, 0, 0]
	)
	var color: Color = Color(0.25, 0.5, 0.8, 0.6)
	for pass_index: int in 2:
		_canvas.call(
			&"configure",
			_owner,
			[_texture, _texture, _texture, _texture],
			regions,
			poses,
			PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE]),
			PackedFloat32Array([0, 0, 0, 0]),
			PackedFloat32Array([1, 1, 1, 1]),
			hsv,
			PackedFloat32Array(),
			PackedFloat32Array(),
			false,
			256.0,
			0.0
		)
		_canvas.call(&"apply_channel_color", PackedInt32Array([0, 1, 2, 3]), color)
		for index: int in 3:
			_check(
				_canvas.call(&"get_item_color", index) == color,
				"neutral HSV snapshots preserve exact channel RGB"
			)
		if pass_index == 0:
			var expected: Color = color
			expected.s *= 1.0
			expected.v *= 1.0
			expected.h += 0.1
			var actual: Color = _canvas.call(&"get_item_color", 3)
			_check(actual.is_equal_approx(expected), "non-neutral HSV remains live")
		else:
			_check(
				_canvas.call(&"get_item_color", 3) == color,
				"same-size reconfigure rebuilds HSV classification"
			)
		hsv.fill(0.0)


func _tint_float32(value: float) -> float:
	return PackedFloat32Array([value])[0]


func _channel_tint_reference(
	channel: Color, hsv: PackedFloat32Array, offset: int, base_alpha: float
) -> Color:
	# Frozen previous native math, including per-operation float rounding.
	var result: Color = channel
	var h: float = hsv[offset]
	var s: float = hsv[offset + 1]
	var v: float = hsv[offset + 2]
	var add_s: bool = hsv[offset + 3] > 0.5
	var add_v: bool = hsv[offset + 4] > 0.5
	var neutral: bool = (
		(h == 0.0 and s == 0.0 and v == 0.0)
		or (h == 0.0 and s == (0.0 if add_s else 1.0) and v == (0.0 if add_v else 1.0))
	)
	if hsv[offset + 4] >= 0.0 and not neutral:
		var hue: float = fmod(_tint_float32(channel.h + h), 1.0)
		if hue < 0.0:
			hue = _tint_float32(hue + 1.0)
		var saturation: float = _tint_float32(channel.s + s if add_s else channel.s * s)
		var value: float = _tint_float32(channel.v + v if add_v else channel.v * v)
		result = Color.from_hsv(
			hue, clampf(saturation, 0.0, 1.0), clampf(value, 0.0, 1.0), channel.a
		)
	result.a = channel.a * base_alpha
	return result


func _test_channel_tint_updates() -> void:
	var hsv: PackedFloat32Array = PackedFloat32Array(
		[
			0,
			0,
			0,
			0,
			0,
			0.1,
			-0.2,
			0.3,
			1,
			1,
			-0.25,
			0.7,
			1.2,
			0,
			0,
			0,
			0.25,
			-0.2,
			0.5,
			0.75,
		]
	)
	var alphas: PackedFloat32Array = PackedFloat32Array([1, 0.25, 0, 1.5])
	var poses: Array = [
		Transform2D.IDENTITY, Transform2D.IDENTITY, Transform2D.IDENTITY, Transform2D.IDENTITY
	]
	var regions: Array = [
		Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8)
	]
	for _pass_index: int in 2:
		_canvas.call(
			&"configure",
			_owner,
			[_texture, _texture, _texture, _texture],
			regions,
			poses,
			PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE]),
			PackedFloat32Array([0, 0, 0, 0]),
			alphas,
			hsv,
			PackedFloat32Array(),
			PackedFloat32Array(),
			false,
			256.0,
			0.0
		)
		for channel: Color in [
			Color(0.2, 0.7, 0.3, 0.6), Color(2.5, 0.3, 1.2, 0.9), Color.BLACK, Color.WHITE
		]:
			_canvas.call(&"apply_channel_color", PackedInt32Array([-1, 2, 99, 0, 2, 1, 3]), channel)
			for index: int in 4:
				var expected: Color = _channel_tint_reference(
					channel, hsv, index * 5, alphas[index]
				)
				var actual: Color = _canvas.call(&"get_item_color", index)
				_check(
					actual.is_equal_approx(expected),
					"channel tint mixed modes/alpha/duplicate indices"
				)
			# A matching incoming channel must still restore direct color edits.
			_canvas.call(&"set_item_color", 1, Color.MAGENTA)
			_canvas.call(&"apply_channel_color", PackedInt32Array([1]), channel)
			var restored: Color = _canvas.call(&"get_item_color", 1)
			_check(
				restored.is_equal_approx(_channel_tint_reference(channel, hsv, 5, alphas[1])),
				"channel tint reads current record state"
			)
			_canvas.call(&"apply_channel_color", PackedInt32Array(), Color.RED)
			_canvas.call(&"apply_channel_color", PackedInt32Array([-1, 99]), Color.RED)
			_check(
				_canvas.call(&"get_item_color", 1) == restored,
				"empty/invalid tint selection is a no-op"
			)
		hsv.fill(0.0)  # Same-size reconfigure back to all-neutral input.


func _test_compact_spatial_reconfigure() -> void:
	var saved_transform: Transform2D = _owner.transform
	_owner.transform = Transform2D.IDENTITY
	for pass_index: int in 2:
		var first_x: float = 128.0 if pass_index == 0 else 1152.0
		var poses: Array[Transform2D] = [
			Transform2D(0.0, Vector2(first_x, 128)),
			Transform2D(0.0, Vector2(896, 128)),
			Transform2D(0.0, Vector2(128, 896)),
		]
		_canvas.call(
			&"configure",
			_owner,
			[_texture, _texture, _texture],
			[Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8)],
			poses,
			PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE]),
			PackedFloat32Array([first_x, 896, 128]),
			PackedFloat32Array([1, 1, 1]),
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedFloat32Array([first_x, 128, 896, 128, 128, 896]),
			true,
			256.0,
			0.0
		)
		_canvas.call(&"update_camera_range")
		_check(
			int(_canvas.call(&"last_drawn_count")) == (1 if pass_index == 0 else 0),
			"compact index reconfigure replaces spatial cells"
		)
		_canvas.call(&"set_visible_buckets", 3, 3)
		_check(int(_canvas.call(&"last_drawn_count")) == 1, "compact index finds another column")
		_canvas.call(&"set_visible_buckets", 2, 2)
		_check(
			int(_canvas.call(&"last_drawn_count")) == 0,
			"compact empty column submits no stale records"
		)
		_canvas.call(&"set_visible_buckets", 0, 0)
		_check(
			int(_canvas.call(&"last_drawn_count")) == (1 if pass_index == 0 else 0),
			"compact index still filters vertical rows"
		)
		var selections: int = int(_canvas.call(&"selection_rebuild_count"))
		_canvas.call(&"set_item_color", 0, Color.RED)
		_canvas.call(&"flush_commands")
		_check(
			int(_canvas.call(&"selection_rebuild_count")) == selections,
			"color-only redraw reuses compact selection"
		)
	_owner.transform = saved_transform
	_configure(Color.WHITE)


func _test_ordered_rect_submissions() -> void:
	var repeated: Transform2D = Transform2D(0.25, Vector2(12, 16))
	var distinct: Transform2D = Transform2D(0.5, Vector2(12, 16))
	(
		_canvas
		. call(
			&"configure",
			_owner,
			[_texture, _texture, _texture, _texture],
			[Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8)],
			[repeated, repeated, distinct, repeated],
			PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE, Color.WHITE]),
			PackedFloat32Array([0, 0, 0, 0]),
			PackedFloat32Array([1, 1, 1, 1]),
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedFloat32Array(),
			false,
			256.0,
			0.0,
		)
	)
	_check(int(_canvas.call(&"last_drawn_count")) == 4, "ordered rect path keeps every sprite")
	_check(
		int(_canvas.call(&"draw_commands_last_rebuild")) == 4,
		"each sprite retains its clipped texture-rect command",
	)
	_check(
		int(_canvas.call(&"transform_commands_last_rebuild")) == 3,
		"exact adjacent transforms reuse canvas state without changing draw order",
	)
	print("RENDERER_TRANSFORM_STATE draws=4 transforms=3 exact_repeat_savings=1")
	var almost_same: Transform2D = repeated
	almost_same.origin.x += 0.0001
	_canvas.call(&"set_item_transform", 1, almost_same)
	_canvas.call(&"flush_commands")
	_check(
		int(_canvas.call(&"draw_commands_last_rebuild")) == 4,
		"transform edits preserve one ordered rect command per sprite",
	)
	_check(
		int(_canvas.call(&"transform_commands_last_rebuild")) == 4,
		"near-equal transforms are not coalesced",
	)

	var textures: Array[Texture2D] = []
	var regions: Array[Rect2] = []
	var transforms: Array[Transform2D] = []
	var colors := PackedColorArray()
	var origins := PackedFloat32Array()
	var alphas := PackedFloat32Array()
	for index in 256:
		textures.append(_texture)
		regions.append(Rect2(0, 0, 8, 8))
		transforms.append(Transform2D(float(index % 11) * 0.01, Vector2(index, index % 17)))
		colors.append(Color.WHITE)
		origins.append(0.0)
		alphas.append(1.0)
	_canvas.call(
		&"configure",
		_owner,
		textures,
		regions,
		transforms,
		colors,
		origins,
		alphas,
		PackedFloat32Array(),
		PackedFloat32Array(),
		PackedFloat32Array(),
		false,
		256.0,
		0.0
	)
	_check(int(_canvas.call(&"last_drawn_count")) == 256, "256-item batch retains all sprites")
	_check(
		int(_canvas.call(&"draw_commands_last_rebuild")) == 256,
		"256 sprites keep their exact texture-rect submissions",
	)
	_check(
		int(_canvas.call(&"transform_commands_last_rebuild")) == 256,
		"distinct per-sprite transforms retain their state commands",
	)
	print("RENDERER_RECT_COMMANDS sprites=256 submissions=256 backend_batching_unmeasured")

	(
		_canvas
		. call(
			&"configure",
			_owner,
			[_texture, _texture, _texture],
			[Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8)],
			[repeated, repeated, repeated],
			PackedColorArray([Color.WHITE, Color.WHITE, Color.WHITE]),
			PackedFloat32Array([0, 0, 0]),
			PackedFloat32Array([1, 1, 1]),
			PackedFloat32Array(),
			PackedFloat32Array(),
			PackedFloat32Array(),
			false,
			256.0,
			0.0,
		)
	)
	_canvas.call(&"set_channel_blending", PackedInt32Array([1]), true)
	_canvas.call(&"flush_commands")
	_check(int(_canvas.call(&"last_drawn_count")) == 3, "blend routing keeps every sprite")
	_check(
		int(_canvas.call(&"draw_commands_last_rebuild")) == 3,
		"blend routing preserves one ordered rect command per sprite",
	)
	_check(
		int(_canvas.call(&"transform_commands_last_rebuild")) == 2,
		"blend-specific canvas items retain independent transform state",
	)
