extends Node
## Exact portable before/after comparison and native parity using real watchers.
## Synchronous timings exclude viewport pacing, not a whole-level FPS benchmark.

const LEGACY = preload("res://tools/reference/LegacyColorChannelWatcher.gd")
var _checks: int = 0
var _failed: int = 0


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failed += 1
		print("COLOR_REFRESH_FAIL %s" % message)


func _ready() -> void:
	_test_probe_boundaries()
	var level: Level = Level.new()
	LevelManager.current_level = level
	var source: ColorChannelData = ColorChannelData.new()
	source.associated_group = "c_42"
	var middle: ColorChannelData = ColorChannelData.new()
	middle.associated_group = "c_43"
	middle.copied_channel_id = 42
	middle.copy_opacity = true
	var data: ColorChannelData = ColorChannelData.new()
	data.associated_group = "c_44"
	level.color_channels.assign([source, middle, data])
	var legacy: ColorChannelWatcher = LEGACY.new(data)
	var current: ColorChannelWatcher = ColorChannelWatcher.new(data)
	var native: Object = ClassDB.instantiate(&"NativeColorChannelIndex")
	var watchers: Array[HSVWatcher] = _make_watchers(48)
	native.call(&"configure", watchers)
	for sample: int in 40:
		data.color = Color(0.2 + sample * 0.031, 0.7, 0.14, 0.8)
		source.color = Color(0.9, sample * 0.027, 0.3, 0.6)
		source.alpha = 0.2 + sample * 0.01
		data.hsv_shift.assign([sample * 0.005, -0.1, 0.2])
		data.alpha = 0.35
		data.intensity = 0.5 + sample * 0.04
		data.copied_channel_id = 43 if sample % 2 == 0 else 0
		data.copy_opacity = sample % 3 == 0
		source.copied_channel_id = 43 if sample % 7 == 0 else 0 # cycle budget
		legacy.refresh_objects_color(watchers)
		var expected: Array[Color] = []
		for watcher: HSVWatcher in watchers:
			expected.append(watcher.modulate)
			expected.append(watcher.parent.modulate)
		current.refresh_objects_color(watchers)
		for index: int in watchers.size():
			_check(watchers[index].modulate == expected[index * 2], "portable channel result is bit-exact")
			_check(watchers[index].parent.modulate == expected[index * 2 + 1], "portable object result is bit-exact")
		_apply_native(native, current, data)
		for index: int in watchers.size():
			# Existing native float intensity grouping can differ by rounding.
			_check(watchers[index].modulate.is_equal_approx(expected[index * 2]), "native channel parity")
			_check(watchers[index].parent.modulate.is_equal_approx(expected[index * 2 + 1]), "native object parity")
			_check(watchers[index].base_alpha == current._effective_alpha(data), "native base alpha mirrored")
			_check(watchers[index].base_intensity == data.intensity, "native base intensity mirrored")
	# Editor-only highlights must remain untouched by the portable optimization.
	watchers[0].selection_highlight = HSVWatcher.SelectionHighlight.NORMAL
	watchers[1].selection_highlight = HSVWatcher.SelectionHighlight.DUPLICATE
	current.refresh_objects_color(watchers)
	_check(watchers[0].parent.modulate == Color.GREEN, "selection highlight preserved")
	_check(watchers[1].parent.modulate == Color.CYAN, "duplicate highlight preserved")
	# Reconfiguration invalidates the mirrored base-value cache too.
	watchers[0].selection_highlight = HSVWatcher.SelectionHighlight.NONE
	watchers[1].selection_highlight = HSVWatcher.SelectionHighlight.NONE
	watchers[0].base_alpha = -1.0
	watchers[0].use_data({"hsv_shift": [0.0, 0.0, 0.0], "intensity": 0.7, "alpha": 0.3})
	native.call(&"configure", watchers)
	_apply_native(native, current, data)
	_check(watchers[0].base_alpha == current._effective_alpha(data), "reconfigure reapplies unchanged channel base values")
	native.call(&"clear")
	_apply_native(native, current, data)
	_check(int(native.call(&"item_count")) == 0, "empty channel remains valid")
	_free_watchers(watchers)

	watchers = _make_watchers(2000)
	native.call(&"configure", watchers)
	data.copied_channel_id = 43
	data.copy_opacity = true
	source.copied_channel_id = 0
	var samples: Array[Array] = [[], [], []]
	# Warm all paths; rotate their timed order to reduce cache/frequency bias.
	for algorithm: int in 3:
		_measure(algorithm, legacy, current, native, data, watchers)
	for trial: int in 3:
		for slot: int in 3:
			var algorithm: int = (trial + slot) % 3
			samples[algorithm].append(_measure(algorithm, legacy, current, native, data, watchers))
	for timings: Array in samples:
		timings.sort()
	print("COLOR_REFRESH_BENCH watchers=2000 updates=60 legacy_gd_ms=%.3f current_gd_ms=%.3f current_native_ms=%.3f" % [samples[0][1], samples[1][1], samples[2][1]])
	_free_watchers(watchers)
	native = null
	data.watcher = null
	legacy.free()
	current.free()
	LevelManager.current_level = null
	ColorChannelWatcher._channel_cache.clear()
	ColorChannelWatcher._channel_cache_level = null
	level.free()
	print("COLOR_REFRESH_SELFTEST checks=%d failed=%d" % [_checks, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


func _make_watchers(count: int) -> Array[HSVWatcher]:
	var result: Array[HSVWatcher] = []
	for index: int in count:
		var target: Node2D = Node2D.new()
		add_child(target)
		var watcher: HSVWatcher = HSVWatcher.new()
		watcher.hsv_shift.assign([0.0, 0.0, 0.0] if index % 4 == 0 else [0.15, 0.1, 0.2])
		watcher.saturation_multiplies = index % 2 == 0
		watcher.value_multiplies = index % 3 == 0
		watcher.intensity = 0.6 + (index % 5) * 0.2
		watcher.alpha = 0.3 + (index % 4) * 0.1
		target.add_child(watcher)
		result.append(watcher)
	return result


func _free_watchers(watchers: Array[HSVWatcher]) -> void:
	for watcher: HSVWatcher in watchers:
		watcher.parent.free()
	watchers.clear()


func _apply_native(native: Object, channel: ColorChannelWatcher, data: ColorChannelData) -> void:
	native.call(&"apply", channel._channel_color(data), data.hsv_shift[0], data.hsv_shift[1], data.hsv_shift[2], data.intensity, channel._effective_alpha(data))


func _measure(algorithm: int, legacy: ColorChannelWatcher, current: ColorChannelWatcher, native: Object, data: ColorChannelData, watchers: Array[HSVWatcher]) -> float:
	var started: int = Time.get_ticks_usec()
	for update: int in 60:
		data.hsv_shift[0] = update * 0.002
		match algorithm:
			0:
				legacy.refresh_objects_color(watchers)
			1:
				current.refresh_objects_color(watchers)
			2:
				_apply_native(native, current, data)
	return (Time.get_ticks_usec() - started) / 1000.0


func _test_probe_boundaries() -> void:
	# Exercise the same collector as Android's script-load gate. Ignoring an
	# isolated project is not permission to skip real runtime/reference scripts.
	var probe: Node = preload("res://tools/gdscript_probe.gd").new()
	var paths: PackedStringArray = []
	probe._collect("res://tools/benchmarks/channel_index", paths)
	_check(paths.is_empty(), "probe respects standalone project's .gdignore")
	probe._collect("res://tools/reference", paths)
	_check(paths.has("res://tools/reference/LegacyColorChannelWatcher.gd"), "probe still includes ordinary test scripts")
	probe._collect("res://src", paths)
	_check(paths.has("res://src/ColorChannelWatcher.gd"), "probe still includes actual runtime scripts")
	probe.free()
