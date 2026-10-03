class_name LevelSettings
extends Control

@export var song_path: FileProperty
@export var song_start_offset: FloatProperty
@export var preview_button: Button
@export var font_preview: Label

var saveloads: Array[PropertySaveLoad]
var is_previewing: bool = false


func _ready() -> void:
	saveloads.assign(NodeUtils.get_children_of_type(self, PropertySaveLoad, true))
	await get_tree().process_frame
	refresh_saveloads(LevelManager.current_level)


func refresh_saveloads(level: Level) -> void:
	var _refresh_saveloads := func(saveload: PropertySaveLoad):
		saveload.property_owner = level
		saveload.load_value()
	saveloads.map.call_deferred(_refresh_saveloads)
	_on_default_font_value_changed(level.default_font)


func stop_song_preview() -> void:
	preview_button.icon = load("res://assets/textures/icons/godot/Play.svg")
	LevelManager.song_player.stop()
	LevelManager.song_player.stream = AssetManager.load_song_threaded_get(Constants.SONG_DIR + LevelManager.current_level.song_path)


func _on_preview_pressed() -> void:
	if song_path.get_value().is_empty():
		is_previewing = false
		stop_song_preview()
		return

	is_previewing = not is_previewing
	if is_previewing:
		preview_button.icon = load("res://assets/textures/icons/godot/Stop.svg")
		LevelManager.song_player.stream = AssetManager.load_song(Constants.SONG_DIR + song_path.get_value().get_file())
		LevelManager.song_player.play(song_start_offset.get_value())
	else:
		stop_song_preview()


func _on_default_font_value_changed(value: String) -> void:
	font_preview.label_settings.set_font_path(value)


func _on_hidden() -> void:
	stop_song_preview()
