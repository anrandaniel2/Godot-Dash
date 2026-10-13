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
	await _census(mode, loaded)
	get_tree().quit(0)


## Attribution: node counts, decoration placements in the data, and the
## static memory each group releases when freed (a measurement only).
func _census(mode: String, data: Dictionary) -> void:
	var counts := { }
	var objects: Array[Node] = []
	var selectors: Array[Node] = []
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		var cls := node.get_class()
		counts[cls] = counts.get(cls, 0) + 1
		if node is GDObject:
			objects.append(node)
		if node.name == &"EditorSelectionCollider":
			selectors.append(node)
		stack.append_array(node.get_children())
	var decorations := 0
	var placements := 0
	for layer in data.get("layers", []):
		for object in layer.get("objects", []):
			placements += 1
			if object.get("decoration", false):
				decorations += 1
	var top: Array = []
	for cls: String in counts:
		top.append([counts[cls], cls])
	top.sort_custom(func(a, b): return a[0] > b[0])
	var names := []
	for entry in top.slice(0, 10):
		names.append("%s=%d" % [entry[1], entry[0]])
	print("LEVEL_OPEN census mode=%s placements=%d decorations=%d GDObject=%d selectors=%d nodes=%s" % [
		mode, placements, decorations, objects.size(), selectors.size(), " ".join(names)])
	var labels: Array[Node] = []
	var controls: Array[Node] = []
	stack.clear()
	stack.append(get_tree().root)
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Label or node is BaseButton:
			labels.append(node)
		elif node is Control:
			controls.append(node)
		stack.append_array(node.get_children())
	for label in labels.slice(0, 4):
		print("LEVEL_OPEN census mode=%s label_path=%s" % [mode, str(label.get_path())])
	for control in controls.slice(0, 4):
		print("LEVEL_OPEN census mode=%s control_path=%s class=%s" % [mode, str(control.get_path()), control.get_class()])
	var mark := OS.get_static_memory_usage()
	data.clear()
	Editor.level_data_snapshot.clear()
	for frame in 2:
		await get_tree().process_frame
	mark = _phase(mode, "data dictionaries", mark)
	for label in labels:
		label.queue_free()
	for frame in 2:
		await get_tree().process_frame
	mark = _phase(mode, "labels and buttons (%d)" % labels.size(), mark)
	for selector in selectors:
		selector.queue_free()
	for frame in 2:
		await get_tree().process_frame
	mark = _phase(mode, "selectors (%d)" % selectors.size(), mark)
	for object in objects:
		object.queue_free()
	for frame in 2:
		await get_tree().process_frame
	mark = _phase(mode, "GDObject trees (%d)" % objects.size(), mark)
	print("LEVEL_OPEN census mode=%s remaining_static=%.1f MB" % [mode, mark / 1048576.0])


func _phase(mode: String, label: String, mark: int) -> int:
	var now := OS.get_static_memory_usage()
	print("LEVEL_OPEN census mode=%s freed %s: %.1f MB" % [mode, label, (mark - now) / 1048576.0])
	return now
