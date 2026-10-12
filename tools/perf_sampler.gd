extends Node
## Frame-time census of a real level run. Added to the root by
## tools/level_probe.gd when GDASH_PROBE_PERF=1, so it only ever runs under the
## probe. While the level is playing it samples the same Performance monitors
## the in-game overlay shows, once per process frame. After skip_frames it also
## counts every node in the tree by type and by script, and how many of
## each have _process or _physics_process enabled: those are the per-frame
## callbacks the engine makes. Prints lines starting with "PERF", then quits.

var frame_limit: int = 1500
## Frames to skip after the level starts playing (deferred loading lands there).
var skip_frames: int = 120
## Script file names whose nodes get process callbacks switched off at the
## census, to measure what that class costs (GDASH_PERF_DISABLE).
var disable_scripts: PackedStringArray = PackedStringArray()
var _skipped: int = 0
var _spikes: Array = []
var _emitters: Array = []
var _emitting_sum: float = 0.0
var _x_min: float = INF
var _x_max: float = -INF
var _process_ms: PackedFloat64Array = PackedFloat64Array()
var _physics_ms: PackedFloat64Array = PackedFloat64Array()
var _census_done: bool = false
var _reported: bool = false

## Fill attribution inside one run: GDASH_PERF_TOGGLE lists categories. The run
## alternates blocks where nothing is hidden with blocks where one category is
## hidden, so drift in the runner cancels out of the comparison. Visibility is
## only changed during measurement; nothing ships.
var toggle_categories: PackedStringArray = PackedStringArray()
var _toggle_nodes: Dictionary = {}
var _toggle_original: Dictionary = {}
var _schedule: PackedStringArray = PackedStringArray()
var _state: String = "none"
var _render_state: PackedStringArray = PackedStringArray()
const TOGGLE_BLOCK: int = 30


var _draw_calls: PackedFloat64Array = PackedFloat64Array()
var _render_cpu_ms: PackedFloat64Array = PackedFloat64Array()
var _render_gpu_ms: PackedFloat64Array = PackedFloat64Array()
var _viewport: RID


func _ready() -> void:
	# Render timing comes from the RenderingServer; it needs a real renderer
	# (CI runs the probe under a virtual display, not --headless).
	_viewport = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport, true)


func _process(_delta: float) -> void:
	if _reported:
		return
	if LevelManager.player == null or not LevelManager.level_playing:
		return
	if _skipped < skip_frames:
		_skipped += 1
		return
	var process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	_process_ms.append(process_ms)
	var emitting_now := 0
	for emitter: GPUParticles2D in _emitters:
		if is_instance_valid(emitter) and emitter.emitting:
			emitting_now += 1
	_emitting_sum += emitting_now
	var x_now := LevelManager.player.global_position.x * 30.0 / 128.0
	_x_min = minf(_x_min, x_now)
	_x_max = maxf(_x_max, x_now)
	if process_ms > 1000.0 / 60.0:
		# Where in the level the slow frame happened, in GD units (30 px per 128 px cell).
		var gd_x := LevelManager.player.global_position.x * 30.0 / 128.0
		_spikes.append([process_ms, gd_x])
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_draw_calls.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_render_cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(_viewport))
	_render_gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(_viewport))
	# The render timings just read belong to the frame drawn under _state.
	_render_state.append(_state)
	if not _census_done:
		_census_done = true
		_census()
		if not toggle_categories.is_empty():
			_build_toggle()
	if not _schedule.is_empty():
		var next := _schedule[(_process_ms.size() / TOGGLE_BLOCK) % _schedule.size()]
		if next != _state:
			_state = next
			_apply_toggle(_state)
	if _process_ms.size() >= frame_limit:
		_report()
		get_tree().quit(0)


func _exit_tree() -> void:
	if not _reported and _process_ms.size() > 0:
		_report()


func _report() -> void:
	_reported = true
	var process_sorted: PackedFloat64Array = _process_ms.duplicate()
	process_sorted.sort()
	var physics_sorted: PackedFloat64Array = _physics_ms.duplicate()
	physics_sorted.sort()
	var over_frame := 0
	for ms: float in _process_ms:
		if ms > 1000.0 / 60.0:
			over_frame += 1
	print("PERF frames=%d process_ms avg=%.2f median=%.2f p95=%.2f max=%.2f" % [
		process_sorted.size(), _mean(process_sorted), _pick(process_sorted, 0.5),
		_pick(process_sorted, 0.95), process_sorted[process_sorted.size() - 1]])
	print("PERF physics_ms avg=%.2f median=%.2f p95=%.2f max=%.2f" % [
		_mean(physics_sorted), _pick(physics_sorted, 0.5), _pick(physics_sorted, 0.95),
		physics_sorted[physics_sorted.size() - 1]])
	print("PERF frames over 16.7 ms of process: %d of %d" % [over_frame, process_sorted.size()])
	_print_stats("draw_calls", _draw_calls)
	_print_stats("render_cpu_ms", _render_cpu_ms)
	_print_stats("render_gpu_ms", _render_gpu_ms)
	_report_toggle()
	var level: Level = LevelManager.current_level
	print("PERF GPU particle emitters emitting on average: %.1f" % (_emitting_sum / maxf(process_sorted.size(), 1)))
	print("PERF player GD x covered %.0f to %.0f (level end %.0f)" % [
		_x_min, _x_max, level.gd_level_end_x if level != null else -1.0])
	_print_spikes()


func _build_toggle() -> void:
	for category: String in toggle_categories:
		_toggle_nodes[category] = []
	var stack: Array = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		stack.append_array(node.get_children(true))
		if not node is CanvasItem:
			continue
		var attached: Script = node.get_script()
		var file := attached.resource_path.get_file() if attached != null else ""
		for category: String in toggle_categories:
			var match_found := false
			match category:
				"decor":
					match_found = file == "DecorationBatch.gd"
				"blur":
					match_found = file == "BlurBackBuffer.gd"
				"ground":
					match_found = file == "GroundObject.gd"
				"particles":
					match_found = node is GPUParticles2D
				"glow":
					match_found = node.name == &"Glow"
				"background":
					match_found = node.name == &"BackgroundParallax"
			if match_found:
				_toggle_nodes[category].append(node)
	var schedule: PackedStringArray = PackedStringArray()
	for cycle in 3:
		for category: String in toggle_categories:
			schedule.append("none")
			schedule.append(category)
	_schedule = schedule
	for category: String in toggle_categories:
		print("PERF toggle %s: %d nodes" % [category, _toggle_nodes[category].size()])


func _apply_toggle(hidden: String) -> void:
	for category: String in _toggle_nodes:
		for node: CanvasItem in _toggle_nodes[category]:
			if not is_instance_valid(node):
				continue
			var id := node.get_instance_id()
			if not _toggle_original.has(id):
				_toggle_original[id] = node.visible
			node.visible = bool(_toggle_original[id]) and category != hidden


func _report_toggle() -> void:
	if _schedule.is_empty():
		return
	var by_state: Dictionary = {}
	for i in _render_gpu_ms.size():
		var state := _render_state[i] if i < _render_state.size() else "none"
		if not by_state.has(state):
			by_state[state] = PackedFloat64Array()
		by_state[state].append(_render_gpu_ms[i])
	var none: PackedFloat64Array = by_state.get("none", PackedFloat64Array())
	var base := _pick(_sorted(none), 0.5)
	print("PERF toggle baseline (nothing hidden): render_gpu median=%.1f ms n=%d" % [base, none.size()])
	for category: String in toggle_categories:
		var values: PackedFloat64Array = by_state.get(category, PackedFloat64Array())
		var median := _pick(_sorted(values), 0.5)
		print("PERF toggle hide %s: render_gpu median=%.1f ms, saves %.1f ms (%.0f%%) n=%d" % [
			category, median, base - median, 100.0 * (base - median) / maxf(base, 0.001), values.size()])


func _sorted(values: PackedFloat64Array) -> PackedFloat64Array:
	var copy: PackedFloat64Array = values.duplicate()
	copy.sort()
	return copy


func _print_stats(label: String, values: PackedFloat64Array) -> void:
	var sorted: PackedFloat64Array = values.duplicate()
	sorted.sort()
	if sorted.is_empty():
		return
	print("PERF %s avg=%.2f median=%.2f p95=%.2f max=%.2f" % [
		label, _mean(sorted), _pick(sorted, 0.5), _pick(sorted, 0.95), sorted[sorted.size() - 1]])


func _print_spikes() -> void:
	var by_bucket: Dictionary = {}
	for spike: Array in _spikes:
		var bucket := int(spike[1] / 1000.0) * 1000
		by_bucket[bucket] = by_bucket.get(bucket, 0) + 1
	var rows: Array = []
	for bucket: int in by_bucket:
		rows.append([by_bucket[bucket], bucket])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var line := "PERF slow frames by GD x (1000 units):"
	for i in mini(12, rows.size()):
		line += " %d-%d:%d" % [rows[i][1], rows[i][1] + 999, rows[i][0]]
	print(line)
	var worst: Array = _spikes.duplicate()
	worst.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for i in mini(12, worst.size()):
		print("PERF slow frame %6.1f ms at GD x=%.0f" % [worst[i][0], worst[i][1]])


func _census() -> void:
	var total := 0
	var by_type: Dictionary = {}
	var processing: Dictionary = {}
	var physics: Dictionary = {}
	var stack: Array = [get_tree().root]
	var disabled := 0
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		total += 1
		var key: String = node.get_class()
		var script: Script = node.get_script()
		if script != null:
			key += " " + script.resource_path.get_file()
		by_type[key] = by_type.get(key, 0) + 1
		if script != null and disable_scripts.has(script.resource_path.get_file()):
			node.set_process(false)
			node.set_physics_process(false)
			disabled += 1
		if node is GPUParticles2D:
			_emitters.append(node)
		if node.is_processing():
			processing[key] = processing.get(key, 0) + 1
		if node.is_physics_processing():
			physics[key] = physics.get(key, 0) + 1
		stack.append_array(node.get_children(true))
	print("PERF census nodes=%d (engine monitor %d) disabled=%d %s" % [
		total, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), disabled, str(disable_scripts)])
	print("PERF GPU particle emitters in tree: %d" % _emitters.size())
	_print_top("nodes by type", by_type)
	_print_top("nodes with _process enabled (run every frame)", processing)
	_print_top("nodes with _physics_process enabled (run every tick)", physics)


func _print_top(title: String, counts: Dictionary) -> void:
	var rows: Array = []
	var total := 0
	for key: String in counts:
		rows.append([counts[key], key])
		total += counts[key]
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	print("PERF %s: %d total" % [title, total])
	for i in mini(20, rows.size()):
		print("PERF   %7d  %s" % [rows[i][0], rows[i][1]])


func _mean(values: PackedFloat64Array) -> float:
	if values.is_empty():
		return 0.0
	var sum := 0.0
	for v: float in values:
		sum += v
	return sum / values.size()


func _pick(sorted: PackedFloat64Array, fraction: float) -> float:
	if sorted.is_empty():
		return 0.0
	return sorted[int(fraction * (sorted.size() - 1))]
