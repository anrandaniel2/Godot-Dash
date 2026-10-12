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
var _process_ms: PackedFloat64Array = PackedFloat64Array()
var _physics_ms: PackedFloat64Array = PackedFloat64Array()
var _census_done: bool = false
var _reported: bool = false


func _process(_delta: float) -> void:
	if _reported:
		return
	if LevelManager.player == null or not LevelManager.level_playing:
		return
	if _skipped < skip_frames:
		_skipped += 1
		return
	_process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	if not _census_done:
		_census_done = true
		_census()
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
		if node.is_processing():
			processing[key] = processing.get(key, 0) + 1
		if node.is_physics_processing():
			physics[key] = physics.get(key, 0) + 1
		stack.append_array(node.get_children(true))
	print("PERF census nodes=%d (engine monitor %d) disabled=%d %s" % [
		total, int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), disabled, str(disable_scripts)])
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
