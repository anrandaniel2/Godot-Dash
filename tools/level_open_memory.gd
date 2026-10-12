extends Node
## Peak memory of opening a downloaded level, two ways:
##   GDASH_MEM_MODE=game    GameScene (paced LevelBuildJob, as players open a level)
##   GDASH_MEM_MODE=editor  EditorScene (Level.from_data in one step, as the editor opens it)
## Both start from the same saved level data (GDASH_MEM_LEVEL, a .gmd file).
## Grep "LEVEL_OPEN" in the log.

const _SAVE_PATH := "user://level_open_memory.gmd"


func _ready() -> void:
	var path := OS.get_environment("GDASH_MEM_LEVEL")
	var mode := OS.get_environment("GDASH_MEM_MODE")
	var document: GMD.Document = GMD.read_any_file(path)
	if document == null or document.level_string.is_empty():
		print("LEVEL_OPEN error: could not read %s" % path)
		get_tree().quit(1)
		return
	var report := GMDConverter.ImportReport.new()
	var data := GMDConverter.import_online_level_string(document.level_string, "MemProbe", report)
	document = null
	_report(mode, "imported")

	LevelOperationsHandler.write_level_and_meta(_SAVE_PATH, data)
	data = { }
	var loaded := LevelOperationsHandler.load_level_data_from_path(_SAVE_PATH)
	_report(mode, "saved and loaded")

	if mode == "editor":
		Editor.level_data_snapshot = loaded
		var editor_scene: Node = (load("res://scenes/EditorScene.tscn") as PackedScene).instantiate()
		add_child(editor_scene)
	else:
		LevelManager.current_level_path = _SAVE_PATH
		var game_scene: Node = (load("res://scenes/GameScene.tscn") as PackedScene).instantiate()
		add_child(game_scene)
	_report(mode, "scene added")

	for frame in 60:
		await get_tree().process_frame
	_report(mode, "60 frames later")
	get_tree().quit(0)


func _report(mode: String, stage: String) -> void:
	var hwm := ""
	var status := FileAccess.open("/proc/self/status", FileAccess.READ)
	if status != null:
		while not status.eof_reached():
			var line := status.get_line()
			if line.begins_with("VmHWM") or line.begins_with("VmRSS"):
				hwm += line.strip_edges() + " "
		status.close()
	print("LEVEL_OPEN mode=%s stage=\"%s\" static_peak=%.1f MB static_now=%.1f MB %s" % [
		mode, stage,
		OS.get_static_memory_peak_usage() / 1048576.0,
		OS.get_static_memory_usage() / 1048576.0,
		hwm])
