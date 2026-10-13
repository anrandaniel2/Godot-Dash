extends Node
## Standalone tests use copies of the production scripts, not game autoloads.
## No user stats or graphics hardware are required.

var _checks: int = 0
var _failed: int = 0


func _ready() -> void:
	_test_frame_pacing()
	_test_timing_requests()
	_test_selection()
	_benchmark_selection()
	print("RUNTIME_SAFETY_SUMMARY checks=%d failed=%d" % [_checks, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failed += 1
		print("RUNTIME_SAFETY_FAIL %s" % message)


func _test_frame_pacing() -> void:
	var physics_rate: int = Engine.physics_ticks_per_second
	for refresh: float in [-1.0, 60.0, 144.0, 239.76]:
		var fresh: ConfigFile = ConfigFile.new()
		_check(FramePacingPolicy.load_cap(fresh, refresh) == 0, "fresh cap must be unlimited")
		for vsync: int in [0, 1, 2, 3]:
			var legacy: ConfigFile = ConfigFile.new()
			legacy.set_value("Graphics", "vsync", vsync)
			legacy.set_value("Graphics", "max_fps", maxi(0, roundi(refresh)))
			_check(FramePacingPolicy.load_cap(legacy, refresh) == 0, "migrate old display cap")
			legacy.set_value("Graphics", "max_fps", 60)
			_check(
				FramePacingPolicy.load_cap(legacy, refresh) == 60,
				"explicit post-migration 60 survives"
			)
			_check(int(legacy.get_value("Graphics", "vsync")) == vsync, "migration preserves VSync")
	var custom: ConfigFile = ConfigFile.new()
	custom.set_value("Graphics", "max_fps", 165)
	_check(FramePacingPolicy.load_cap(custom, 240.0) == 165, "preserve unrelated custom cap")
	var old_default: ConfigFile = ConfigFile.new()
	old_default.set_value("Graphics", "max_fps", 60)
	_check(FramePacingPolicy.load_cap(old_default, 240.0) == 0, "migrate legacy 60 default")
	_check(Engine.physics_ticks_per_second == physics_rate, "frame policy cannot change physics")


func _test_timing_requests() -> void:
	var viewport: RID = RenderingServer.viewport_create()
	var first: RefCounted = RefCounted.new()
	var second: RefCounted = RefCounted.new()
	_check(not RenderTimingRequests.is_requested(viewport), "no GPU timing on ordinary launch")
	RenderTimingRequests.set_requested(viewport, first, false)
	_check(not RenderTimingRequests.is_requested(viewport), "unowned release is harmless")
	RenderTimingRequests.set_requested(viewport, first, true)
	RenderTimingRequests.set_requested(viewport, first, true)
	RenderTimingRequests.set_requested(viewport, second, true)
	RenderTimingRequests.set_requested(viewport, first, false)
	_check(RenderTimingRequests.is_requested(viewport), "hiding HUD preserves capture ownership")
	RenderTimingRequests.set_requested(viewport, second, false)
	_check(not RenderTimingRequests.is_requested(viewport), "last release disables timing")
	RenderingServer.free_rid(viewport)


func _test_selection() -> void:
	var pool: Array[Node2D] = []
	for i: int in 32:
		pool.append(Node2D.new())
	pool.append(null)
	var selection: Selection = Selection.new()
	var reference: Array[Node2D] = []
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 20261013
	for step: int in 1000:
		var object: Node2D = pool[rng.randi_range(0, pool.size() - 1)]
		match rng.randi_range(0, 3):
			0, 1:
				selection.insert(object)
				if not reference.has(object):
					reference.append(object)
			2:
				var expected: bool = reference.has(object)
				_check(selection.remove(object) == expected, "remove reports membership")
				reference.erase(object)
			3:
				_check(
					selection.contains(object) == reference.has(object), "membership matches array"
				)
		_check(selection.to_array() == reference, "random mutation preserves order and uniqueness")
	selection.clear()
	_check(selection.is_empty() and not selection.contains(pool[0]), "clear resets both stores")
	var a: Selection = Selection.new([pool[3], pool[1], pool[3], pool[0]])
	var b: Selection = Selection.new([pool[0], pool[2], pool[1]])
	_check(a.to_array() == [pool[3], pool[1], pool[0]], "constructor insertion order")
	_check(a.union(b).to_array() == [pool[3], pool[1], pool[0], pool[2]], "union order")
	_check(a.intersection(b).to_array() == [pool[1], pool[0]], "intersection order")
	_check(a.difference(b).to_array() == [pool[3]], "difference order")
	var copy: Selection = a.clone()
	copy.remove(pool[1])
	_check(a.contains(pool[1]) and not copy.contains(pool[1]), "clone is independent")
	var array: Array[Node2D] = a.to_array()
	array.clear()
	_check(a.size() == 3, "to_array does not expose internal storage")
	_check(a.is_identical(Selection.new([pool[0], pool[1], pool[3]])), "identity ignores order")
	_check(a.is_superset(copy) and copy.is_subset(a), "subset/superset")
	var visited: Array[Node2D] = []
	a.for_each(
		func(object: Node2D) -> void:
			visited.append(object)
			a.remove(object)
	)
	_check(
		visited == [pool[3], pool[1], pool[0]] and a.is_empty(), "callback mutations use a snapshot"
	)
	b.for_each(func(object: Node2D) -> void: visited.append(object), true)
	_check(visited.slice(3) == [pool[1], pool[2], pool[0]], "reverse callback order")
	selection.clear()
	copy.clear()
	b.clear()
	for object: Node2D in pool:
		if object != null:
			object.free()


func _benchmark_selection() -> void:
	var nodes: Array[Node2D] = []
	for i: int in 20000:
		nodes.append(Node2D.new())
	var before: int = OS.get_static_memory_usage()
	var started: int = Time.get_ticks_usec()
	var old: Array[Node2D] = []
	for node: Node2D in nodes:
		if not old.has(node):
			old.append(node)
	var old_us: int = Time.get_ticks_usec() - started
	var old_bytes: int = OS.get_static_memory_usage() - before
	before = OS.get_static_memory_usage()
	started = Time.get_ticks_usec()
	var indexed: Selection = Selection.new(nodes)
	var new_us: int = Time.get_ticks_usec() - started
	var new_bytes: int = OS.get_static_memory_usage() - before
	_check(indexed.to_array() == old, "bulk benchmark parity")
	print(
		(
			"SELECTION_BENCH count=%d old_ms=%.3f indexed_ms=%.3f old_retained_bytes=%d indexed_retained_bytes=%d"
			% [
				nodes.size(),
				old_us / 1000.0,
				new_us / 1000.0,
				old_bytes,
				new_bytes,
			]
		)
	)
	indexed.clear()
	old.clear()
	for node: Node2D in nodes:
		node.free()
