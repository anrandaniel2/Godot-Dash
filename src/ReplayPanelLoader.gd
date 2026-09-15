extends VBoxContainer

@export var import_dialog: FileDialog
@export var save_dialog: FileDialog
@export var replay_already_exists_dialog: ConfirmationDialog
@export var sort_by: OptionButton
@export var order: OptionButton
@export var save: Button
@export var stop: Button

var replays: Dictionary[String, Control]

signal replay_started


func _ready() -> void:
	sort_by.item_selected.connect(reorder.unbind(1))
	order.item_selected.connect(reorder.unbind(1))
	refresh()


func _process(_delta: float) -> void:
	if not visible:
		return
	if not LevelManager.level_playing or LevelManager.player.in_replay:
		save.hide()
	else:
		save.show()
	if LevelManager.player.in_replay:
		stop.show()
	else:
		stop.hide()


func refresh() -> void:
	replays.clear()
	for child in get_children():
		child.queue_free()

	if not DirAccess.dir_exists_absolute(Constants.REPLAYS_DIR):
		DirAccess.make_dir_recursive_absolute(Constants.REPLAYS_DIR)

	_migrate_legacy_replays()

	var dir := DirAccess.open(Constants.REPLAYS_DIR)
	var replay_files := PackedStringArray()
	for file_name: String in dir.get_files():
		if file_name.get_extension() == "gdr":
			replay_files.append(file_name)
	if replay_files.is_empty():
		_add_no_replays_label()
		return

	var scene: PackedScene = load("res://scenes/components/game_components/ReplayPanel.tscn")
	for file_name: String in replay_files:
		var replay_name: String = file_name.get_basename()
		var panel: ReplayPanel = scene.instantiate()
		panel.title.text = replay_name
		panel.start_button.pressed.connect(_start_replay.bind(file_name))
		panel.remove_button.pressed.connect(_remove_level.bind(file_name))
		replays[file_name] = panel
		add_child(panel)

	await get_tree().process_frame
	reorder()


func reorder() -> void:
	var children: Array[Node] = get_children().duplicate()
	# Alphabetical
	children.sort_custom(func(a: ReplayPanel, b: ReplayPanel): return a.title.text.to_lower() > b.title.text.to_lower())

	for child in children:
		move_child(child, 0)

	# Flip order
	if order.selected == 1:
		for child in get_children():
			move_child(child, 0)


func _start_replay(path: String) -> void:
	var should_use_practice_snapshot: bool = not LevelManager.practice_level_snapshots.is_empty()
	if Editor.in_editor and not should_use_practice_snapshot:
		return
	if not LevelManager.level_playing:
		return
	# Load before flipping any state so a broken file cannot leave the game
	# half-restarted.
	var result: Dictionary = GDRFormat.load(Constants.REPLAYS_DIR.path_join(path))
	if not result.ok:
		Toasts.error("Could not load replay: %s." % result.error)
		return
	LevelManager.practice_mode = false
	LevelManager.practice_level_snapshots.clear()
	LevelManager.player.in_replay = true
	await LevelManager.game_scene.restart_level()
	LevelManager.player.replay = result.replay
	Toasts.new_toast("Started Replay: %s" % path.get_basename())
	replay_started.emit()
	LevelManager.game_scene.pause_menu.update_buttons_visibility()


func _stop_replay() -> void:
	LevelManager.player.in_replay = false
	LevelManager.player.replay = Replay.new()
	Toasts.new_toast("Stopped Replay")
	LevelManager.game_scene.pause_menu.update_buttons_visibility()


func _remove_level(replay_name: String) -> void:
	OS.move_to_trash(ProjectSettings.globalize_path(Constants.REPLAYS_DIR + replay_name))
	replays[replay_name].queue_free()
	replays.erase(replay_name)
	# Node is freed the next frame
	if get_child_count() <= 1:
		_add_no_replays_label()


func _add_no_replays_label() -> void:
	var label: Label = Label.new()
	label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = "No replays found."
	add_child(label)


## Replays used to be stored as engine .res resources; convert them once, in
## place, to the shareable GDR format so they keep working.
func _migrate_legacy_replays() -> void:
	var dir := DirAccess.open(Constants.REPLAYS_DIR)
	if dir == null:
		return
	for file_name: String in dir.get_files():
		if file_name.get_extension() != "res":
			continue
		var legacy: Variant = load(Constants.REPLAYS_DIR.path_join(file_name))
		if legacy is Replay:
			_normalize_legacy_replay(legacy)
			if GDRFormat.save(legacy, Constants.REPLAYS_DIR.path_join(file_name.get_basename() + GDRFormat.FILE_EXTENSION)) == OK:
				DirAccess.remove_absolute(Constants.REPLAYS_DIR.path_join(file_name))


## Old recordings stored the jump state (-1 for the wave descend) and the
## direction (-1/0/1) as raw PackedByteArray elements, which are unsigned
## bytes: the negatives wrapped to 255 and could never be read back (the
## wave descend and platformer-left inputs were lost in playback). Shift
## them into the range the current representation uses.
func _normalize_legacy_replay(legacy: Replay) -> void:
	for tick in legacy.data.size():
		var state: int = legacy.data[tick][0]
		if state == 255:
			state = 2
		var direction: int = legacy.data[tick][1]
		if direction == 255:
			direction = 0
		elif direction == 0:
			direction = 1
		else:
			direction = 2
		legacy.data[tick] = PackedByteArray([state, direction])


func _open_importer() -> void:
	# On Android the FileDialog control can never open the OS file manager:
	# its "Keep original replay file" option makes the engine fall back to
	# Godot's built-in dialog, which is confined to the app-private user://
	# folder and can't see shared storage. Ask the OS file manager (Storage
	# Access Framework) directly instead - it needs no storage permission.
	if OS.has_feature("android"):
		DisplayServer.file_dialog_show(
			"Import replay",
			"", # Ignored on Android; the picker offers its own locations.
			"",
			false,
			DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
			PackedStringArray(["*/*"]), # .gdr has no MIME type, so show every file.
			_import_replay_from_android_picker,
		)
		return
	import_dialog.show()


func _import_replay_from_android_picker(status: bool, selected_paths: PackedStringArray, _selected_filter_index: int) -> void:
	if not status or selected_paths.is_empty():
		return
	# The SAF picker returns a content:// URI, which GDRFormat reads through
	# FileAccess directly; the import content-sniffs the document, so the
	# URI having no real filesystem extension doesn't matter. The picker
	# can't show the "Keep original replay file" checkbox, so the file is
	# always kept - which is also the dialog's desktop default.
	_import_replay_from(selected_paths[0], true)


func _import_replay(path: String) -> void:
	var keep_original: bool = import_dialog.get_selected_options().get("Keep original replay file", true)
	_import_replay_from(path, keep_original)


func _import_replay_from(path: String, keep_original: bool) -> void:
	var result: Dictionary = GDRFormat.load(path)
	if not result.ok:
		Toasts.error("This replay isn't a valid GDR file: %s." % result.error)
		return
	var replay_name := _replay_name_from(path)
	var replay_path: String = Constants.REPLAYS_DIR.path_join(replay_name + GDRFormat.FILE_EXTENSION)
	if FileAccess.file_exists(replay_path):
		replay_already_exists_dialog.show()
		var canceled: Signal = replay_already_exists_dialog.canceled
		var confirmed: Signal = replay_already_exists_dialog.confirmed
		match await Signals.first(canceled, confirmed):
			canceled:
				return
			confirmed:
				pass
		DirAccess.remove_absolute(replay_path)
	if GDRFormat.save(result.replay, replay_path) == OK:
		Toasts.new_toast("Imported replay: %s!" % replay_name)
	else:
		Toasts.error("Could not write the imported replay.")
	refresh()
	# content:// URIs (the Android picker) cannot go to the OS trash.
	if not keep_original and not path.begins_with("content://"):
		OS.move_to_trash(ProjectSettings.globalize_path(path))


## A friendly file name for an imported replay: desktop paths and Android
## content:// URIs both end in the picked document's name.
func _replay_name_from(path: String) -> String:
	var file_name: String = path.get_file().get_basename()
	return file_name if not file_name.is_empty() else "Imported replay"


func _save() -> void:
	save_dialog.show()
	await save_dialog.file_selected
	var replay_name: String = save_dialog.current_file.get_basename()
	if replay_name.is_empty():
		Toasts.error("Could not save replay: no name given.")
		return
	var error: Error = GDRFormat.save(LevelManager.player.replay, Constants.REPLAYS_DIR.path_join(replay_name + GDRFormat.FILE_EXTENSION))
	match error:
		Error.OK:
			Toasts.new_toast("Replay saved!")
			refresh()
		_:
			Toasts.error("Could not save replay: Error %s." % error)
