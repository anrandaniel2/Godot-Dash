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

@onready var mutex: Mutex = Mutex.new()

var levels: Dictionary[String, Control]
var loaded_level_data: Dictionary
var scene: PackedScene = load("res://scenes/components/game_components/LevelPanel.tscn")
var file_names: PackedStringArray
var stopping: bool = false


func _ready() -> void:
	sort_by.item_selected.connect(reorder.unbind(1))
	order.item_selected.connect(reorder.unbind(1))
	refresh.call_deferred()


func refresh() -> void:
	refresh_button.disabled = true
	levels.clear()
	file_names.clear()

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

	var task_id = WorkerThreadPool.add_group_task(_load_data_threaded, file_names.size())
	while not WorkerThreadPool.is_group_task_completed(task_id):
		if stopping:
			WorkerThreadPool.wait_for_group_task_completion(task_id)
			return
		await get_tree().process_frame
	WorkerThreadPool.wait_for_group_task_completion(task_id)
	for file_name: String in loaded_level_data:
		var panel: LevelPanel = scene.instantiate()
		var level_data: Dictionary = loaded_level_data[file_name]
		var level_name: String = file_name.get_basename()
		panel.title.text = level_name
		panel.creator.text = level_data.creator
		panel.description.text = level_data.description
		panel.version.text = "v" + level_data.game_version

		# Version warnings
		var level_version: Version = Version.new(level_data.game_version)
		var version_warning: String = Level.generate_version_warning(level_version)

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
		panel.creation_date = level_data.creation_date
		levels[file_name] = panel
		add_child(panel)
	loaded_level_data.clear()
	reorder()
	refresh_button.disabled = false


func _load_data_threaded(index: int) -> void:
	var file_name: String = file_names[index]
	# Prevent crash when file deleted during refresh
	if not FileAccess.file_exists(Constants.LEVEL_DIR + file_name):
		return
	var level_data: Dictionary = LevelOperationsHandler.load_level_data_from_path(Constants.LEVEL_DIR + file_name)
	if stopping:
		return
	mutex.lock()
	loaded_level_data[file_name] = level_data
	mutex.unlock()


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
	Editor.level_data_snapshot = LevelOperationsHandler.load_level_data_from_path(LevelManager.current_level_path)
	subscene_manager._on_editor_pressed()


func _remove_level(file_name: String) -> void:
	OS.move_to_trash(ProjectSettings.globalize_path(Constants.LEVEL_DIR + file_name))
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
	import_dialog.show()


func _import_level(path: String) -> void:
	var keep_original = import_dialog.get_selected_options()["Keep original level file"]
	LevelOperationsHandler.import_level(path, keep_original, corrupted_level_dialog, level_already_exists_dialog)
