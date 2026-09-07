class_name LevelOperationsHandler
extends Node

signal level_loaded(level: Level)
signal level_saved

enum Operation {
	NEW,
	OPEN,
	IMPORT,
	SAVE,
	SAVE_AS,
	EXPORT,
}

@export var edit_handler: EditHandler
@export var level_settings: LevelSettings
@export var open_dialog: FileDialog
@export var import_dialog: FileDialog
@export var save_as_dialog: FileDialog
@export var export_dialog: FileDialog
@export var save_changes_before_opening_dialog: ConfirmationDialog
@export var corrupted_level_dialog: AcceptDialog
@export var level_already_exists_dialog: ConfirmationDialog
@export var version_error_dialog: ConfirmationDialog

@onready var editor: EditorScene = get_parent()

var autosave_toast: Toast


func _ready() -> void:
	save_changes_before_opening_dialog.add_button("Don't Save", false, "dontsave")
	save_as_dialog.root_subfolder = OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	export_dialog.root_subfolder = OS.get_system_dir(OS.SYSTEM_DIR_DESKTOP)
	NodeUtils.connect_once($AutosaveTimer.timeout, save_level)


func _process(_delta: float) -> void:
	if not LevelManager.level_playing and $AutosaveTimer.get_time_left() < 5.0 and not $AutosaveTimer.is_stopped():
		var autosave_message := "Autosaving in " + str(snappedf($AutosaveTimer.get_time_left(), 0.1)) + "s"
		if autosave_toast:
			autosave_toast.update_text(autosave_message)
		else:
			autosave_toast = Toasts.new_toast(autosave_message, $AutosaveTimer.get_time_left(), Toasts.PAUSABLE)
	if autosave_toast and LevelManager.level_playing:
		autosave_toast.dismiss()


func _unhandled_input(event: InputEvent) -> void:
	if LevelManager.level_playing:
		return
	if event.is_action_pressed(&"editor_new_level", false, true):
		_on_level_index_pressed(Operation.NEW)
	if event.is_action_pressed(&"editor_open_level", false, true):
		_on_level_index_pressed(Operation.OPEN)
	if event.is_action_pressed(&"editor_import_level", false, true):
		_on_level_index_pressed(Operation.IMPORT)
	if event.is_action_pressed(&"editor_save", false, true):
		_on_level_index_pressed(Operation.SAVE)
	if event.is_action_pressed(&"editor_save_as", false, true):
		_on_level_index_pressed(Operation.SAVE_AS)
	if event.is_action_pressed(&"editor_export_level", false, true):
		_on_level_index_pressed(Operation.EXPORT)


func pause_autosave() -> void:
	$AutosaveTimer.paused = true


func unpause_autosave() -> void:
	$AutosaveTimer.paused = false


func _on_level_index_pressed(index: int) -> void:
	var operation := index as Operation
	match operation:
		Operation.NEW:
			_new_level()
		Operation.OPEN:
			open_dialog.show()
		Operation.IMPORT:
			import_dialog.show()
		Operation.SAVE:
			save_level()
		Operation.SAVE_AS:
			save_as_dialog.show()
			if await Signals.first(
				save_as_dialog.canceled,
				save_as_dialog.file_selected,
			) == save_as_dialog.file_selected:
				save_level()
		Operation.EXPORT:
			if not LevelManager.current_level_path.is_empty():
				export_dialog.set_current_file(
						LevelManager.current_level_path.get_file().get_basename()
						+ "." + Constants.GMD_FILE_EXTENSION
				)
			export_dialog.show()


func _new_level() -> void:
	if editor.level_was_modified():
		save_changes_before_opening_dialog.show()
		var canceled: Signal = save_changes_before_opening_dialog.canceled
		var saved: Signal = save_changes_before_opening_dialog.confirmed
		var didnt_save: Signal = save_changes_before_opening_dialog.custom_action
		match await Signals.first(canceled, didnt_save, saved):
			canceled:
				return
			didnt_save:
				save_changes_before_opening_dialog.hide()
			saved:
				var save_result: Error = await save_level()
				if save_result != OK:
					return
	LevelManager.game_scene.free_current_level()
	var color_channel_editor: ColorChannelEditor = editor.get_node(^"%ColorChannelEditor")
	color_channel_editor.clear_item_list()
	edit_handler.clear_selection()
	LevelManager.current_level_path = ""
	var new_level := Level.new()
	new_level.name = Constants.DEFAULT_LEVEL_NAME
	editor.level = LevelManager.game_scene.add_loaded_level(new_level)
	Editor.clear_data()
	Editor.root.reset()
	LevelManager.player.clear_debug_trail()
	level_settings.refresh_saveloads(new_level)
	new_level.default_background_color = Constants.DEFAULT_BACKGROUND_COLOR
	new_level.default_ground_color = Constants.DEFAULT_GROUND_COLOR
	new_level.default_line_color = Constants.DEFAULT_LINE_COLOR
	LevelManager.current_level_path = ""
	# Reset player
	LevelManager.player.position = Constants.DEFAULT_PLAYER_POSITION
	for group in LevelManager.player.get_groups():
		LevelManager.player.remove_from_group(group)
	LevelManager.player.get_node(^"HSVWatcher").reset_color()
	LevelManager.player.z_index = 0

	level_loaded.emit(new_level)
	# Reset camera to default position
	editor.editor_camera.offset = Vector2(1280.0, 669.0)
	editor.editor_camera.zoom_factor = 1.25
	editor.editor_camera.zoom = Vector2.ONE * 0.8
	$AutosaveTimer.stop()


func _open_level(path: String) -> void:
	if editor.level_was_modified():
		save_changes_before_opening_dialog.show()
		var canceled: Signal = save_changes_before_opening_dialog.canceled
		var saved: Signal = save_changes_before_opening_dialog.confirmed
		var didnt_save: Signal = save_changes_before_opening_dialog.custom_action
		match await Signals.first(canceled, didnt_save, saved):
			canceled:
				return
			didnt_save:
				save_changes_before_opening_dialog.hide()
			saved:
				var save_result: Error = await save_level()
				if save_result != OK:
					return
	if LevelManager.level_playing:
		await editor.stop_playtest()
		return
	# Load level
	var level: Level = await _load_level(path)
	if not level:
		# Avoid clearing the existing level if the new level failed to load
		return
	LevelManager.game_scene.free_current_level()
	LevelManager.game_scene.pause_menu.play_button.show()
	# Avoid name conflicts
	editor.level.name = str(hash(editor.level))
	Editor.clear_data()
	LevelManager.player.clear_debug_trail()

	level_settings.refresh_saveloads(level)
	# Load song
	var song_file_path: String
	if level.song_path.begins_with("uid"):
		song_file_path = ResourceUID.get_id_path(ResourceUID.text_to_id(level.song_path)).get_file()
	else:
		song_file_path = level.song_path.get_file()
	level.song_path = "" if song_file_path.is_empty() else Constants.SONG_DIR + song_file_path
	level.set_meta(&"packed_file_path", path)
	# Remove current editor level
	var color_channel_editor: ColorChannelEditor = editor.get_node(^"%ColorChannelEditor")
	edit_handler.clear_selection()
	color_channel_editor.clear_item_list()
	# Add new level
	LevelManager.current_level_path = path
	await get_tree().process_frame
	editor.level = LevelManager.game_scene.add_loaded_level(level)
	level_loaded.emit(level)
	Toasts.new_toast("Opened level " + path.get_file().get_basename())
	color_channel_editor.populate_item_list()
	Editor.root.reset()
	# Reset camera to default position
	editor.editor_camera.offset = Vector2(1280.0, 669.0)
	editor.editor_camera.zoom_factor = 1.25
	editor.editor_camera.zoom = PlayerCamera.DEFAULT_ZOOM
	$AutosaveTimer.stop()
	$AutosaveTimer.start(Config.autosave_delay * 60)


func _import_and_open_level(path: String) -> void:
	var keep_original: bool = import_dialog.get_selected_options()["Keep original level file"]
	var level_path: String = await import_level(path, keep_original, corrupted_level_dialog, level_already_exists_dialog)
	if level_path.is_empty():
		return
	_open_level(level_path)


func save_level() -> Error:
	if LevelManager.current_level_path.is_empty():
		save_as_dialog.show()
		if await Signals.first(
			save_as_dialog.canceled,
			save_as_dialog.file_selected,
		) != save_as_dialog.file_selected:
			return ERR_FILE_CANT_OPEN
	LevelManager.game_scene.pause_menu.play_button.show()
	var file_name: String = LevelManager.current_level_path.get_file().get_basename() + "." + Constants.LEVEL_FILE_EXTENSION
	editor.level.name = file_name.get_basename()
	var level_data: Dictionary = editor.level.to_data()
	if not LevelManager.level_playing:
		# The level is saved before starting playtest, but here the creator isn't playtesting.
		Editor.level_data_snapshot = level_data
	$AutosaveTimer.stop()
	$AutosaveTimer.start(Config.autosave_delay * 60)
	var file_error := write_level_and_meta(Constants.LEVEL_DIR + file_name, level_data)
	if file_error != OK:
		Toasts.error("Couldn't save level (error %d)" % file_error, 5.0)
		return file_error
	Toasts.new_toast("Saved level " + editor.level.name)
	Editor.level_history_version = Editor.version_history.get_version()
	level_saved.emit()
	return OK


func _on_save_level_as_dialog_file_selected(path: String) -> void:
	LevelManager.current_level_path = path.get_basename() + "." + Constants.LEVEL_FILE_EXTENSION
	editor.level.name = path.get_file().get_basename()


## Exports the current level as a `.gmd` or `.gmd2` file readable by the GDShare
## mod. The extension the creator typed decides the format: `.gmd2` is a ZIP and
## can carry the level's song, `.gmd` is a single plist and cannot.
func _on_export_level_dialog_file_selected(path: String) -> Error:
	var extension: String = path.get_extension().to_lower()
	if extension not in [Constants.GMD_FILE_EXTENSION, Constants.GMD2_FILE_EXTENSION]:
		extension = Constants.GMD_FILE_EXTENSION
		path = path.get_basename() + "." + extension

	var level_data: Dictionary = editor.level.to_data()
	if not LevelManager.level_playing:
		# The level is saved before starting playtest, but here the creator isn't playtesting.
		edit_handler.selection.for_each(EditHandler.remove_selection_highlight)
		Editor.level_data_snapshot = level_data
		edit_handler.selection.for_each(EditHandler.add_selection_highlight)

	var report := GMDConverter.ImportReport.new()
	var level_string: String = GMDConverter.export_level_string(level_data, report)
	var level_name: String = path.get_file().get_basename()

	var entries: Dictionary = {
		GMD.Key.NAME: level_name,
		GMD.Key.CREATOR: editor.level.creator,
		GMD.Key.DESCRIPTION: Marshalls.utf8_to_base64(editor.level.description),
		GMD.Key.VERSION: 35,
		GMD.Key.REVISION: 0,
		"k13": true, # local level
		"k21": 2, # level type: created
	}

	var error: Error
	var song_included: bool = false
	if extension == Constants.GMD2_FILE_EXTENSION:
		var song_path: String = ""
		if not editor.level.song_path.is_empty():
			song_path = Constants.SONG_DIR + editor.level.song_path.get_file()
			song_included = FileAccess.file_exists(song_path)
		error = GMD.write_gmd2_file(path, entries, level_string, song_path)
	else:
		error = GMD.write_file(path, entries, level_string)

	if error != OK:
		Toasts.error("Couldn't write %s (error %d)" % [path.get_file(), error], 5.0)
		return error

	var message: String = "Exported %s — %s" % [level_name, report.summary()]
	if song_included:
		message += ", song included"
	elif extension == Constants.GMD_FILE_EXTENSION and not editor.level.song_path.is_empty():
		message += " (export as .gmd2 to include the song)"
	if report.skipped > 0:
		Toasts.warning(message, 5.0)
	else:
		Toasts.new_toast(message, 2.0)
	return OK


func _load_level(path: String) -> Level:
	var level_data: Dictionary = load_level_data_from_path(path)
	if not Level.generate_version_warning(Version.new(level_data.game_version)).is_empty():
		version_error_dialog.show()
		match await Signals.first(version_error_dialog.canceled, version_error_dialog.confirmed):
			version_error_dialog.canceled:
				return null
			version_error_dialog.confirmed:
				pass
	# The decode above is unavoidable; write the metadata sidecar for the
	# community list, which reads only sidecars and never decodes a level.
	write_level_meta(path, level_data)
	var level: Level = Level.from_data(level_data)
	LevelManager.current_level_path = path.get_file()
	return level


## Imports a `.gmd` or `.gmd2` file (GDShare's Geometry Dash level formats) into
## the local level directory and returns the path of the created level file.
##
## `.gmd` is a plain plist document; `.gmd2` is a ZIP that wraps the same
## document as `level.data` and can additionally carry the level's song. Both
## are accepted here and the song, when present, is unpacked into
## [constant Constants.SONG_DIR] and linked to the level.
##
## Objects that Godot Dash has no equivalent for are skipped individually, so a
## level built out of unsupported objects still imports (just with those objects
## missing) instead of freezing or crashing. Returns an empty [String] when the
## file itself couldn't be read.
static func import_level(path: String, keep_original: bool, _corrupted_level_dialog: AcceptDialog, _level_already_exists_dialog: AcceptDialog) -> String:
	if not file_is_gmd(path):
		_corrupted_level_dialog.dialog_text = """This file isn't a Geometry Dash level and can't be imported.
Error:
Expected a .%s or .%s file.""" % [Constants.GMD_FILE_EXTENSION, Constants.GMD2_FILE_EXTENSION]
		_corrupted_level_dialog.popup_centered()
		return ""

	var extras := GMD.Gmd2Extras.new()
	# Decided by content, not extension: GDShare always names its exports
	# `.gmd` even when the payload is a zip, and users rename files freely.
	var document: GMD.Document = GMD.read_any_file(path, extras)
	var extension: String = path.get_extension().to_lower()

	if document == null:
		_corrupted_level_dialog.dialog_text = """This .%s file is corrupted and can't be imported.
Error:
The file isn't a readable level: expected a property list document, or a zip archive containing level.data.""" % extension
		_corrupted_level_dialog.popup_centered()
		return ""
	if document.level_string.is_empty():
		_corrupted_level_dialog.dialog_text = """This .%s file doesn't contain any level data.
Error:
Missing or unreadable level string (k4).""" % extension
		_corrupted_level_dialog.popup_centered()
		return ""

	var level_name: String = document.get_string(GMD.Key.NAME, path.get_file().get_basename())
	# Keep the name usable as a file name.
	level_name = level_name.validate_filename()
	if level_name.is_empty():
		level_name = path.get_file().get_basename()

	var report := GMDConverter.ImportReport.new()
	var level_data: Dictionary = GMDConverter.import_level_string(document.level_string, level_name, report)
	level_data.creator = document.get_string(GMD.Key.CREATOR, Config.username)
	var encoded_description: String = document.get_string(GMD.Key.DESCRIPTION)
	if not encoded_description.is_empty():
		var decoded := Marshalls.base64_to_utf8(encoded_description.replace("-", "+").replace("_", "/"))
		level_data.description = decoded if not decoded.is_empty() else ""

	# A .gmd2 can ship the song with the level. Unpack it next to the other
	# songs and point the level at it; `Level.song_path` is a bare file name
	# resolved against SONG_DIR.
	if not extras.song_bytes.is_empty():
		if not DirAccess.dir_exists_absolute(Constants.SONG_DIR):
			DirAccess.make_dir_recursive_absolute(Constants.SONG_DIR)
		var song_path: String = Constants.SONG_DIR + extras.song_file
		var song_file := FileAccess.open(song_path, FileAccess.WRITE)
		if song_file:
			song_file.store_buffer(extras.song_bytes)
			song_file.close()
			level_data.song_path = extras.song_file
		else:
			push_warning("GMD2: couldn't write song %s (error %d)" % [extras.song_file, FileAccess.get_open_error()])

	if not DirAccess.dir_exists_absolute(Constants.LEVEL_DIR):
		DirAccess.make_dir_recursive_absolute(Constants.LEVEL_DIR)
	var level_path: String = Constants.LEVEL_DIR + level_name + "." + Constants.LEVEL_FILE_EXTENSION

	if FileAccess.file_exists(level_path):
		_level_already_exists_dialog.popup_centered()
		var opened_existing: Signal = _level_already_exists_dialog.canceled
		var overwrote: Signal = _level_already_exists_dialog.confirmed
		match await Signals.first(opened_existing, overwrote):
			opened_existing:
				return level_path
			overwrote:
				pass

	var file_error := write_level_and_meta(level_path, level_data)
	if file_error != OK:
		Toasts.error("Couldn't save the imported level (error %d)" % file_error, 5.0)
		return ""

	if not keep_original:
		OS.move_to_trash(ProjectSettings.globalize_path(path))

	var message: String = "Imported %s — %s" % [level_name, report.summary()]
	if not extras.song_file.is_empty():
		message += ", song included"
	# If decoration was skipped wholesale, say why rather than failing silently.
	if report.decorations == 0 and report.skipped > 0:
		var reason: String = GDDecorationLoader.diagnose()
		if not reason.is_empty():
			message += " - no decoration drawn: " + reason

	if report.skipped > 0 or report.failed > 0:
		Toasts.warning(message, 6.0)
		if not report.skipped_ids.is_empty():
			push_warning("GMD import skipped unsupported objects:\n%s" % report.skipped_breakdown())
	else:
		Toasts.new_toast(message)
	return level_path


static func load_level_data_from_path(file_path: String) -> Dictionary:
	var file := FileAccess.open_compressed(file_path, FileAccess.READ, Constants.LEVEL_COMPRESSION_MODE)
	if file == null:
		return { }
	var buffer_length: int = file.get_length()
	var data: Dictionary = bytes_to_var(file.get_buffer(buffer_length))
	file.close()
	return data


## Writes a level's `.bin` file and, next to it, a tiny metadata sidecar
## ([code]<file>.meta[/code]). The community level list reads only the sidecar
## (see [method load_level_meta_from_path]) so browsing does not deserialize
## every level - large levels are tens of megabytes of objects and decoding
## each one just to show a title/rating is what made the list crash.
static func write_level_and_meta(level_path: String, level_data: Dictionary) -> Error:
	var file := FileAccess.open_compressed(level_path, FileAccess.WRITE, Constants.LEVEL_COMPRESSION_MODE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(var_to_bytes(level_data))
	file.close()
	write_level_meta(level_path, level_data)
	return OK


## Sidecar file holding the metadata the level list shows.
const LEVEL_META_EXTENSION: String = ".meta"


## Writes the metadata sidecar for a saved level. The level's own data carries
## these keys at its top level (see Level.to_data), so the sidecar is just a
## trimmed copy.
static func write_level_meta(level_path: String, level_data: Dictionary) -> void:
	var meta := {
		"name": str(level_data.get("name", level_path.get_file().get_basename())),
		"creator": str(level_data.get("creator", "")),
		"description": str(level_data.get("description", "")),
		"rating": int(level_data.get("rating", -1)),
		"game_version": str(level_data.get("game_version", "")),
		"creation_date": int(level_data.get("creation_date", 0)),
		"flashing_lights": bool(level_data.get("flashing_lights", false)),
	}
	var file := FileAccess.open(level_path + LEVEL_META_EXTENSION, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(meta))
	file.close()


## Reads a level's metadata sidecar, or an empty [Dictionary] when there is
## none (older levels saved before the sidecar existed).
static func load_level_meta_from_path(file_path: String) -> Dictionary:
	var meta_path: String = file_path + LEVEL_META_EXTENSION
	if not FileAccess.file_exists(meta_path):
		return { }
	var file := FileAccess.open(meta_path, FileAccess.READ)
	if file == null:
		return { }
	var meta: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return meta if meta is Dictionary else { }


static func file_is_level(file_path: String) -> bool:
	return file_path.get_extension() == Constants.LEVEL_FILE_EXTENSION


## [code]true[/code] for either GDShare level format, `.gmd` or `.gmd2`.
static func file_is_gmd(file_path: String) -> bool:
	return file_path.get_extension().to_lower() in [
		Constants.GMD_FILE_EXTENSION,
		Constants.GMD2_FILE_EXTENSION,
		"lvl", # obsolete GDShare format, still readable
	]


## [code]true[/code] only for the zipped `.gmd2` variant.
static func file_is_gmd2(file_path: String) -> bool:
	return file_path.get_extension().to_lower() == Constants.GMD2_FILE_EXTENSION


static func file_is_song(file_path: String) -> bool:
	return file_path.get_extension() in ["mp3", "wav", "ogg"]


static func file_is_font(file_path: String) -> bool:
	return file_path.get_extension() in ["ttf", "ttc", "otf"]
