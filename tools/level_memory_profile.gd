extends Node
## Measures memory and time for every stage of opening a downloaded level,
## following the game's own path: decode -> import -> save -> load -> build.
##
## Run by .github/workflows/level-profile.yml against a real level file (for
## example ORBIT, 310k objects). Reads the GDHistory download from the path in
## GDASH_PROFILE_LEVEL. Grep "LEVEL_PROFILE" in the log.

const _SAVE_PATH := "user://level_memory_profile.bin"

var _started_ms: int = 0


func _ready() -> void:
	var path := OS.get_environment("GDASH_PROFILE_LEVEL")
	_mark("start (native %s)" % ("yes" if NativeCore.available() else "no"))
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		print("LEVEL_PROFILE error: could not read %s" % path)
		get_tree().quit(1)
		return
	_mark("read download (%d chars)" % text.length())

	var encoded := RobTopLevels._extract_k4(text)
	text = ""
	var level_string := GMD.decode_level_string(encoded)
	encoded = ""
	_mark("decoded level string (%d chars)" % level_string.length())

	var report := GMDConverter.ImportReport.new()
	var level_data := GMDConverter.import_online_level_string(level_string, "Profile", report)
	level_string = ""
	var objects: Array = level_data.layers[0].objects
	var decorations := 0
	for object_data: Variant in objects:
		if object_data is Dictionary and object_data.get("decoration", false):
			decorations += 1
	_mark("imported (%d objects, %d decorations, %d packed) %s" % [
		objects.size(), decorations, _packed_count(level_data), report.summary()])

	var bytes := var_to_bytes(level_data)
	_mark("var_to_bytes (%d bytes)" % bytes.size())
	bytes = PackedByteArray()

	LevelOperationsHandler.write_level_and_meta(_SAVE_PATH, level_data)
	level_data = { }
	objects = []
	_mark("saved and released import")

	var loaded := LevelOperationsHandler.load_level_data_from_path(_SAVE_PATH)
	_mark("loaded from disk")

	var job := LevelBuildJob.new(loaded)
	while not job.finished:
		job.step(0x7fffffff)
	var level: Level = job.level
	var batches := 0
	var items := 0
	var nodes := 0
	for layer: Node in level.layers:
		for child: Node in layer.get_children():
			nodes += 1
			if child is DecorationBatch:
				batches += 1
				items += (child as DecorationBatch).items.size()
	_mark("built (%d layer children, %d batches, %d sprites)" % [nodes, batches, items])

	add_child(level)
	await get_tree().process_frame
	await get_tree().process_frame
	_mark("in tree, two frames drawn")
	print("LEVEL_PROFILE done peak=%.1f MB" % (OS.get_static_memory_peak_usage() / 1048576.0))
	get_tree().quit(0)


func _packed_count(level_data: Dictionary) -> int:
	var packed: Dictionary = level_data.get("packed_decorations", { })
	var ids: PackedInt32Array = packed.get("gd_id", PackedInt32Array())
	return ids.size()


func _mark(stage: String) -> void:
	var now := Time.get_ticks_msec()
	if _started_ms == 0:
		_started_ms = now
	print("LEVEL_PROFILE %7.1fs  mem=%7.1f MB  peak=%7.1f MB  %s" % [
		(now - _started_ms) / 1000.0,
		OS.get_static_memory_usage() / 1048576.0,
		OS.get_static_memory_peak_usage() / 1048576.0,
		stage,
	])
