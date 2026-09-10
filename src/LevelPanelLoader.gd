extends VBoxContainer

enum SortBy {
	ALPHABETICALLY,
	RATING,
	CREATOR,
	CREATION_DATE,
}

enum Order {
	FIRST_LAST,
	LAST_FIRST,
}

@export var rating_colors: Gradient
@export var subscene_manager: SubsceneManager
@export var import_dialog: FileDialog
@export var level_already_exists_dialog: ConfirmationDialog
@export var corrupted_level_dialog: AcceptDialog
@export var version_error_dialog: ConfirmationDialog
@export var sort_by: OptionButton
@export var order: OptionButton
@export var fade_screen: FadeScreen
@export var refresh_button: Button
@export var online_search: SearchBarNode
@export var local_mode_button: Button
@export var online_mode_button: Button
@export var online_category: OptionButton
@export var previous_page_button: Button
@export var page_status: Label
@export var next_page_button: Button
@export var search_timer: Timer

@onready var mutex: Mutex = Mutex.new()

var online_mode := false
var online_page := 0
var online_pages := 0
var online_busy := false
var online_refresh_queued := false
var online_client: RobTopLevels

var levels: Dictionary[String, Control]
var loaded_level_data: Dictionary
var scene: PackedScene = load("res://scenes/components/game_components/LevelPanel.tscn")
var file_names: PackedStringArray
var stopping: bool = false


func _ready() -> void:
	sort_by.item_selected.connect(reorder.unbind(1))
	order.item_selected.connect(reorder.unbind(1))
	_setup_online_controls()
	refresh.call_deferred()


func _setup_online_controls() -> void:
	# Every visible control is authored in TitleScreen.tscn. Do not construct
	# this toolbar dynamically: scene-authored nodes are reliably laid out on
	# Android and are visible even if the networking client fails to initialize.
	online_client = RobTopLevels.new()
	get_parent().add_child(online_client)
	online_search.text_submitted.connect(_online_search_submitted)
	online_search.text_changed.connect(_online_search_changed)
	online_category.set_item_metadata(0, 4)
	online_category.set_item_metadata(1, 3)
	online_category.set_item_metadata(2, 1)
	online_category.set_item_metadata(3, 2)
	online_category.set_item_metadata(4, 6)
	online_category.set_item_metadata(5, 11)
	online_category.item_selected.connect(_online_category_changed)
	previous_page_button.pressed.connect(_change_online_page.bind(-1))
	next_page_button.pressed.connect(_change_online_page.bind(1))
	search_timer.timeout.connect(_restart_online_search)


func refresh() -> void:
	if online_mode:
		await _refresh_online()
		return
	refresh_button.disabled = true
	levels.clear()
	file_names.clear()
	loaded_level_data.clear()

	for child in get_children():
		child.queue_free()

	var dir := DirAccess.open(Constants.LEVEL_DIR)
	var all_file_names = dir.get_files()
	for file_name: String in all_file_names:
		if file_name.get_extension() == Constants.LEVEL_FILE_EXTENSION:
			file_names.append(file_name)
	if file_names.size() == 0:
		var label: Label = Label.new()
		label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.text = "No levels found."
		add_child(label)
		refresh_button.disabled = false
		return

	# Phase 1 - read every level's cheap metadata sidecar in parallel. This
	# never deserializes a level, so it is safe no matter how many - or how
	# large - the levels are.
	var task_id = WorkerThreadPool.add_group_task(_load_meta_threaded, file_names.size())
	while not WorkerThreadPool.is_group_task_completed(task_id):
		if stopping:
			WorkerThreadPool.wait_for_group_task_completion(task_id)
			return
		await get_tree().process_frame
	WorkerThreadPool.wait_for_group_task_completion(task_id)
	# The user can switch to Online while a large local metadata scan is in
	# progress. Never let that stale local result overwrite the online loading
	# state or server cards.
	if online_mode:
		refresh_button.disabled = false
		return

	# Phase 2 - older levels have no sidecar yet. The list must never decode a
	# level just to show it: decoding a large level is many tens of megabytes
	# and on a phone can kill the app outright. Such files get a placeholder
	# panel (name only); the moment the level is actually opened - play or
	# edit - the decode that is unavoidable anyway writes its sidecar, so the
	# next refresh shows full metadata.
	for file_name: String in file_names:
		if not loaded_level_data.has(file_name):
			loaded_level_data[file_name] = _placeholder_meta(file_name)

	for file_name: String in loaded_level_data:
		var panel: LevelPanel = scene.instantiate()
		var level_data: Dictionary = loaded_level_data[file_name]
		var level_name: String = file_name.get_basename()
		panel.title.text = level_name
		panel.creator.text = level_data.creator
		panel.description.text = level_data.description
		# Levels whose sidecar does not exist yet have no version to show, and
		# no version warning can be judged until the level is opened once.
		var version_warning: String = ""
		if str(level_data.game_version).is_empty():
			panel.version.hide()
		else:
			panel.version.text = "v" + level_data.game_version
			var level_version: Version = Version.new(level_data.game_version)
			version_warning = Level.generate_version_warning(level_version)
			if not version_warning.is_empty():
				panel.version.modulate = Color.RED
				panel.version.text += " – %s" % version_warning

		panel.rating.text = str(int(level_data.rating)) if level_data.rating != -1 else "?"
		panel.rating_outline.modulate = rating_colors.get_color(level_data.rating + 1)
		if not level_data.flashing_lights:
			panel.flashing_lights.hide()
		panel.play_button.pressed.connect(_play_level.bind(file_name, version_warning))
		panel.edit_button.pressed.connect(_edit_level.bind(file_name, version_warning))
		panel.remove_button.pressed.connect(_remove_level.bind(file_name))
		panel.creation_date = int(level_data.creation_date)
		levels[file_name] = panel
		add_child(panel)
	loaded_level_data.clear()
	reorder()
	refresh_button.disabled = false


func _on_local_levels_pressed() -> void:
	_set_browse_mode(false)


func _on_online_levels_pressed() -> void:
	_set_browse_mode(true)


func _set_browse_mode(use_online: bool) -> void:
	# These buttons are tabs, not disabled actions. A disabled tab looked like
	# an unavailable feature and also made touch-state diagnosis ambiguous.
	local_mode_button.button_pressed = not use_online
	online_mode_button.button_pressed = use_online
	if online_mode == use_online:
		return
	online_mode = use_online
	if online_mode and not is_instance_valid(online_client):
		online_client = RobTopLevels.new()
		get_parent().add_child(online_client)
	online_page = 0
	sort_by.visible = not online_mode
	order.visible = not online_mode
	online_category.visible = online_mode and online_search.text.strip_edges().is_empty()
	previous_page_button.visible = online_mode
	page_status.visible = online_mode
	next_page_button.visible = online_mode
	online_search.placeholder_text = "Search RobTop levels by name or ID…" if online_mode else "Search…"
	# Start the selected source on the next frame. Calling refresh() indirectly
	# from a button signal proved unreliable on Android when the local metadata
	# load was still unwinding; the explicit deferred route also updates the UI
	# before networking begins.
	if online_mode:
		page_status.text = "Loading…"
		_show_list_message("Connecting to RobTop…")
		_refresh_online.call_deferred()
	else:
		refresh.call_deferred()


func _online_category_changed(_index: int) -> void:
	if online_mode:
		online_page = 0
		_refresh_online()


func _online_search_submitted(_text: String) -> void:
	if online_mode:
		search_timer.stop()
		_restart_online_search()


func _online_search_changed(_text: String) -> void:
	if online_mode:
		search_timer.start()


func _restart_online_search() -> void:
	online_page = 0
	online_category.visible = online_search.text.strip_edges().is_empty()
	_refresh_online()


func _change_online_page(direction: int) -> void:
	if online_busy:
		return
	var destination := online_page + direction
	if destination < 0 or destination >= online_pages:
		return
	online_page = destination
	_refresh_online()


func _refresh_online() -> void:
	if online_busy:
		online_refresh_queued = true
		return
	online_refresh_queued = false
	online_busy = true
	refresh_button.disabled = true
	previous_page_button.disabled = true
	next_page_button.disabled = true
	page_status.text = "Loading…"
	_show_list_message("Connecting to RobTop…")
	var category: int = online_category.get_item_metadata(online_category.selected)
	var requested_page := online_page
	var requested_query := online_search.text.strip_edges()
	var response := await online_client.search(requested_query, requested_page, category)
	online_busy = false
	refresh_button.disabled = false
	if online_refresh_queued:
		online_refresh_queued = false
		_refresh_online.call_deferred()
		return
	if not online_mode or requested_page != online_page or requested_query != online_search.text.strip_edges():
		return
	if not response.ok:
		online_pages = 0
		page_status.text = "Offline"
		previous_page_button.disabled = true
		next_page_button.disabled = true
		_show_list_message("Could not load online levels.\n%s\nCheck your connection and press Refresh." % response.error)
		return

	online_pages = int(response.pages)
	page_status.text = "%d / %d" % [online_page + 1, maxi(1, online_pages)]
	previous_page_button.disabled = online_page <= 0
	next_page_button.disabled = online_page + 1 >= online_pages
	_clear_list_controls()
	if response.levels.is_empty():
		_show_list_message("No online levels found.")
		return
	for summary: Dictionary in response.levels:
		var panel: LevelPanel = scene.instantiate()
		panel.title.text = "%s  ·  #%d" % [summary.name, summary.id]
		panel.creator.text = summary.creator
		var description: String = summary.description
		var statistics := "%s  ·  %s downloads  ·  %s likes" % [summary.difficulty, _compact_number(summary.downloads), _compact_number(summary.likes)]
		panel.description.text = statistics if description.is_empty() else "%s\n%s" % [description, statistics]
		panel.version.text = "%d★" % summary.stars if summary.stars > 0 else summary.difficulty
		panel.rating.text = str(summary.stars) if summary.stars > 0 else "?"
		panel.rating_outline.modulate = rating_colors.get_color(clampf((summary.difficulty_value + 1.0) / 6.0, 0.0, 1.0))
		panel.flashing_lights.hide()
		panel.remove_button.hide()
		panel.play_button.tooltip_text = "Download and play"
		panel.edit_button.tooltip_text = "Download and edit"
		panel.play_button.pressed.connect(_download_online_level.bind(summary, false, panel))
		panel.edit_button.pressed.connect(_download_online_level.bind(summary, true, panel))
		add_child(panel)


func _download_online_level(summary: Dictionary, edit_after: bool, panel: LevelPanel) -> void:
	if online_busy:
		return
	online_busy = true
	panel.play_button.disabled = true
	panel.edit_button.disabled = true
	var old_version := panel.version.text
	panel.version.text = "Downloading…"
	var response := await online_client.download(summary.id, summary)
	online_busy = false
	if not is_instance_valid(panel):
		return
	panel.play_button.disabled = false
	panel.edit_button.disabled = false
	panel.version.text = old_version
	if not response.ok:
		_show_transient_error("Level download failed: %s" % response.error)
		return
	var file_name := "%s [GD-%d].%s" % [str(summary.name).validate_filename(), summary.id, Constants.LEVEL_FILE_EXTENSION]
	var error := LevelOperationsHandler.write_level_and_meta(Constants.LEVEL_DIR + file_name, response.level_data)
	if error != OK:
		_show_transient_error("Could not save the downloaded level (error %d)." % error)
		return
	if edit_after:
		_edit_level(file_name, "")
	else:
		_play_level(file_name, "")


func _show_transient_error(message: String) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Online levels"
	dialog.dialog_text = message
	get_tree().current_scene.add_child(dialog)
	dialog.popup_centered()
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)


func _clear_list_controls() -> void:
	levels.clear()
	for child in get_children():
		if child is Control:
			child.queue_free()


func _show_list_message(message: String) -> void:
	_clear_list_controls()
	var label := Label.new()
	label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = message
	add_child(label)


static func _compact_number(value: int) -> String:
	if value >= 1_000_000:
		return "%.1fM" % (value / 1_000_000.0)
	if value >= 1_000:
		return "%.1fK" % (value / 1_000.0)
	return str(value)


func _load_meta_threaded(index: int) -> void:
	var file_name: String = file_names[index]
	if not FileAccess.file_exists(Constants.LEVEL_DIR + file_name):
		return
	# Browsing only needs the metadata (title, creator, rating, version...);
	# every save/import writes a tiny .meta sidecar, so this never has to
	# decode the level itself.
	var level_data: Dictionary = LevelOperationsHandler.load_level_meta_from_path(Constants.LEVEL_DIR + file_name)
	if level_data.is_empty() or stopping:
		return
	mutex.lock()
	loaded_level_data[file_name] = level_data
	mutex.unlock()


## Metadata shown for a level that has no sidecar yet: the file name is known,
## nothing else. Reading a sidecar is the only cheap way to get metadata - a
## full decode must never happen just to browse (it can exceed a phone's
## memory). Opening the level writes its sidecar.
static func _placeholder_meta(file_name: String) -> Dictionary:
	return {
		"name": file_name.get_basename(),
		"creator": "",
		"description": "",
		"rating": -1,
		"game_version": "",
		"creation_date": 0,
		"flashing_lights": false,
	}


func _exit_tree() -> void:
	stopping = true


func reorder() -> void:
	var children: Array = get_children().duplicate()
	var compare_title := func(a: LevelPanel, b: LevelPanel): return _use_order(a.title.text.to_lower() > b.title.text.to_lower())
	var compare_rating := func(a: LevelPanel, b: LevelPanel): return _use_order(a.rating.text < b.rating.text)
	var compare_creator := func(a: LevelPanel, b: LevelPanel): return _use_order(a.creator.text.to_lower() > b.creator.text.to_lower())
	var compare_creation_date := func(a: LevelPanel, b: LevelPanel): return _use_order(a.creation_date < b.creation_date)
	# Always sort alphabetically for consistency.
	children.sort_custom(compare_title)
	match sort_by.selected:
		SortBy.ALPHABETICALLY:
			pass
		SortBy.RATING:
			children.sort_custom(compare_rating)
		SortBy.CREATOR:
			children.sort_custom(compare_creator)
		SortBy.CREATION_DATE:
			children.sort_custom(compare_creation_date)

	for child in children:
		move_child(child, 0)


func _play_level(file_name: String, version_warning: String) -> void:
	if not version_warning.is_empty():
		version_error_dialog.show()
		match await Signals.first(version_error_dialog.canceled, version_error_dialog.confirmed):
			version_error_dialog.canceled:
				return
			version_error_dialog.confirmed:
				pass
	AudioServer.set_bus_mute(AudioServer.get_bus_index("Music"), true)
	SFXManager.play_sfx("res://assets/sounds/sfx/game_sfx/LevelPlay.ogg")
	fade_screen.fade_in()
	subscene_manager.zoom_in_title_screen_layer()
	await get_tree().create_timer(0.5).timeout
	LevelManager.attempt = 0
	LevelManager.current_level_path = Constants.LEVEL_DIR + file_name
	if DiscordRPCManager.available:
		DiscordRPCHandler.set_details("Playing a level")
		DiscordRPCHandler.refresh()
	get_tree().change_scene_to_packed(AssetManager.game_scene_packed)


func _edit_level(file_name: String, version_warning: String) -> void:
	if not version_warning.is_empty():
		version_error_dialog.show()
		match await Signals.first(version_error_dialog.canceled, version_error_dialog.confirmed):
			version_error_dialog.canceled:
				return
			version_error_dialog.confirmed:
				pass
	LevelManager.current_level_path = Constants.LEVEL_DIR + file_name
	var level_data: Dictionary = LevelOperationsHandler.load_level_data_from_path(LevelManager.current_level_path)
	LevelOperationsHandler.write_level_meta(LevelManager.current_level_path, level_data)
	Editor.level_data_snapshot = level_data
	subscene_manager._on_editor_pressed()


func _remove_level(file_name: String) -> void:
	OS.move_to_trash(ProjectSettings.globalize_path(Constants.LEVEL_DIR + file_name))
	var meta_path: String = Constants.LEVEL_DIR + file_name + LevelOperationsHandler.LEVEL_META_EXTENSION
	if FileAccess.file_exists(meta_path):
		OS.move_to_trash(ProjectSettings.globalize_path(meta_path))
	levels[file_name].queue_free()
	levels.erase(file_name)
	# Node is freed the next frame
	if get_child_count() <= 1:
		var label: Label = Label.new()
		label.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.text = "No levels found."
		add_child(label)


func _use_order(comparison: bool) -> bool:
	match order.selected:
		Order.FIRST_LAST:
			return comparison
		Order.LAST_FIRST:
			return not comparison
		_:
			return comparison


func _open_importer() -> void:
	# On Android the FileDialog control can never open the OS file manager: its
	# "Keep original level file" option makes the engine fall back to Godot's
	# built-in dialog, which is confined to the app-private user:// folder and
	# can't see shared storage. Ask the OS file manager (Storage Access
	# Framework) directly instead - it needs no storage permission.
	if OS.has_feature("android"):
		DisplayServer.file_dialog_show(
			"Import and open",
			"", # Ignored on Android; the picker offers its own locations.
			"",
			false,
			DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
			PackedStringArray(["*/*"]), # .gmd/.gmd2/.lvl have no MIME type, so show every file.
			_import_level_from_android_picker,
		)
		return
	import_dialog.show()


func _import_level(path: String) -> void:
	var keep_original = import_dialog.get_selected_options().get("Keep original level file", true)
	_do_import_level(path, keep_original)


func _import_level_from_android_picker(status: bool, selected_paths: PackedStringArray, _selected_filter_index: int) -> void:
	if not status or selected_paths.is_empty():
		return
	# The SAF picker returns a content:// URI; FileAccess reads it directly on
	# Android 4.6+ and the import path content-sniffs, so the URI having no
	# real filesystem extension doesn't matter. The picker can't show the
	# "Keep original level file" checkbox, so the file is always kept - which
	# is also the dialog's desktop default.
	_do_import_level(selected_paths[0], true)


func _do_import_level(path: String, keep_original: bool) -> void:
	LevelOperationsHandler.import_level(path, keep_original, corrupted_level_dialog, level_already_exists_dialog)

