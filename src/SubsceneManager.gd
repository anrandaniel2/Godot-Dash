class_name SubsceneManager
extends Node

enum SubScene {
	TITLE_SCREEN,
	LEVEL_SELECTOR,
	ICON_GARAGE,
	COMMUNITY_MENU,
	SETTINGS_MENU,
}

static var editor_scene: PackedScene
static var is_first_load: bool = true

@export var camera: Camera2D
@export var fade_screen: FadeScreen
@export var menu_loop: AudioStreamPlayer
@export var splash: Control

@export_group("Subscenes")
@export var level_selector: TitleScreenPanel
@export var community_menu: TitleScreenPanel
@export var icon_garage: TitleScreenPanel
@export var settings_panel: TitleScreenPanel
@export var settings_menu: TabContainer

@export_group("Title Screen Components")
@export var title_screen_layer: CanvasLayer
@export var title_screen_background: Parallax2D
@export var title_screen_ground: Parallax2D
@export var title_screen_player: TitleScreenPlayer
@export var title_screen_player_killer: TitleScreenPlayerKiller

@onready var _base_background_color: Color = title_screen_background.get_node("Background").modulate

var _current_subscene: SubScene = SubScene.TITLE_SCREEN
var _camera_tween: Tween


func _enter_tree() -> void:
	SceneManager.set_current_scene(SceneManager.Scene.TITLE_SCREEN)


func _ready() -> void:
	if OS.get_cmdline_user_args().size() >= 1 and is_first_load:
		var path: Variant = Array(OS.get_cmdline_user_args()).filter(
			func(arg: String) -> bool: return not arg.begins_with("-")
		)
		if path.size() >= 1:
			path = path[0]
		_launch_from_file(path)
	Engine.time_scale = 1.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	community_menu.hide()
	level_selector.hide()
	settings_panel.hide()
	if SceneManager.from_editor() or SceneManager.from_level():
		community_menu.anchor_left = community_menu.initial_anchor_left
		community_menu.anchor_right = community_menu.initial_anchor_right
		community_menu.target_visible = true
		community_menu.show()
	if not SceneManager.from_title_screen():
		# HACK: Manual animation because PhantomCamera gets in the way
		fade_screen.fade_out()
		_camera_tween = create_tween()
		zoom_out_title_screen_layer()
	if Config.transition_duration > 0.0 and is_first_load:
		splash.show()
		var splash_tween: Tween = create_tween()
		(
				splash_tween \
						.tween_property(splash, ^"modulate:a", 0.0, Config.transition_duration) \
						.set_ease(Tween.EASE_IN_OUT) \
						.set_trans(Tween.TRANS_SINE)
		)
		splash_tween.tween_callback(splash.hide)
	if DiscordRPCManager.available:
		DiscordRPCHandler.set_details("Title Screen")
		DiscordRPCHandler.refresh()
	await ready
	is_first_load = false


## Opens a `.gmd` or `.gmd2` file the game was launched with (file association
## or drag and drop), importing it into the local level directory first.
func _launch_from_file(path: String):
	if not LevelOperationsHandler.file_is_gmd(path):
		Toasts.error("Only .%s and .%s levels can be opened with Godot Dash." % [
			Constants.GMD_FILE_EXTENSION, Constants.GMD2_FILE_EXTENSION,
		], 5.0)
		return

	var extras := GMD.Gmd2Extras.new()
	# Content sniffed rather than trusting the extension.
	var document: GMD.Document = GMD.read_any_file(path, extras)
	if document == null or document.level_string.is_empty():
		Toasts.error("This .%s file is corrupted and can't be opened." % path.get_extension().to_lower(), 5.0)
		return

	var level_name: String = document.get_string(GMD.Key.NAME, path.get_file().get_basename()).validate_filename()
	if level_name.is_empty():
		level_name = path.get_file().get_basename()

	var report := GMDConverter.ImportReport.new()
	var level_data: Dictionary = GMDConverter.import_level_string(document.level_string, level_name, report)
	level_data.creator = document.get_string(GMD.Key.CREATOR, Config.username)

	# A .gmd2 can bundle the song; unpack it so the level plays with audio.
	if not extras.song_bytes.is_empty():
		if not DirAccess.dir_exists_absolute(Constants.SONG_DIR):
			DirAccess.make_dir_recursive_absolute(Constants.SONG_DIR)
		var song_file := FileAccess.open(Constants.SONG_DIR + extras.song_file, FileAccess.WRITE)
		if song_file:
			song_file.store_buffer(extras.song_bytes)
			song_file.close()
			level_data.song_path = extras.song_file

	if not DirAccess.dir_exists_absolute(Constants.LEVEL_DIR):
		DirAccess.make_dir_recursive_absolute(Constants.LEVEL_DIR)
	var level_path: String = Constants.LEVEL_DIR + level_name + "." + Constants.LEVEL_FILE_EXTENSION
	var file_error := LevelOperationsHandler.write_level_and_meta(level_path, level_data)
	if file_error != OK:
		Toasts.error("Couldn't import %s (error %d)" % [path.get_file(), file_error], 5.0)
		return

	if report.skipped > 0:
		Toasts.warning("Imported %s — %s" % [level_name, report.summary()], 6.0)

	if DiscordRPCManager.available:
		DiscordRPCHandler.set_details("Playing a level")
		DiscordRPCHandler.refresh()
	LevelManager.current_level_path = level_path
	is_first_load = false
	get_tree().change_scene_to_packed(AssetManager.game_scene_packed)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not (_camera_tween and _camera_tween.is_running()):
		if _current_subscene == SubScene.TITLE_SCREEN:
			_on_quit_game_pressed()
		else:
			_return_to_title_screen()


func zoom_in_title_screen_layer() -> void:
	var tween: Tween = create_tween().set_parallel().set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_EXPO)
	tween.tween_property(camera, ^"zoom", Vector2.ONE * 4.0, Config.transition_duration)
	tween.tween_property(title_screen_layer, ^"scale", Vector2.ONE * 4.0, Config.transition_duration)
	tween.tween_property(title_screen_layer, ^"offset", -camera.get_viewport_rect().size * sqrt(2.0), Config.transition_duration)


func zoom_out_title_screen_layer() -> void:
	var tween: Tween = create_tween().set_parallel().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_EXPO)
	tween.tween_property(camera, ^"zoom", PlayerCamera.DEFAULT_ZOOM, Config.transition_duration).from(Vector2.ONE * 2.0)
	tween.tween_property(title_screen_layer, ^"scale", Vector2.ONE, Config.transition_duration).from(Vector2.ONE * 2.0)
	tween.tween_property(title_screen_layer, ^"offset", Vector2.ZERO, Config.transition_duration).from(-camera.get_viewport_rect().size / 2.0)


func _return_to_title_screen() -> void:
	_toggle_background_sprites_autoscroll(true)
	_current_subscene = SubScene.TITLE_SCREEN
	_change_background_color(_base_background_color)
	for object in [level_selector, community_menu, settings_panel, icon_garage]:
		if object.target_visible:
			object.hide_tween()


func _toggle_background_sprites_autoscroll(enabled: bool) -> void:
	if Config.enable_title_screen_icons:
		title_screen_player.visible = enabled
		title_screen_player_killer.process_mode = Node.PROCESS_MODE_INHERIT if enabled else Node.PROCESS_MODE_DISABLED
	# HACK: autoscroll can't be interpolated
	if enabled:
		title_screen_background.autoscroll.x = -300
		title_screen_ground.autoscroll.x = -800
	else:
		title_screen_background.autoscroll.x = 0
		title_screen_ground.autoscroll.x = 0


func _change_background_color(new_color: Color) -> void:
	create_tween() \
			.tween_property(title_screen_background.get_node("Background"), "modulate", new_color, 1.0) \
			.set_ease(Tween.EASE_OUT) \
			.set_trans(Tween.TRANS_EXPO)


func _on_go_to_level_selector_pressed() -> void:
	if level_selector.target_visible:
		_return_to_title_screen()
		return
	_return_to_title_screen()
	level_selector.show_tween()
	_current_subscene = SubScene.LEVEL_SELECTOR


func _on_go_to_community_menu_pressed() -> void:
	if community_menu.target_visible:
		_return_to_title_screen()
		return
	_return_to_title_screen()
	community_menu.show_tween()
	_current_subscene = SubScene.COMMUNITY_MENU


func _on_go_to_icon_garage_pressed() -> void:
	if icon_garage.target_visible:
		_return_to_title_screen()
		return
	_return_to_title_screen()
	icon_garage.show_tween()
	_current_subscene = SubScene.ICON_GARAGE


func _on_settings_pressed() -> void:
	if settings_panel.target_visible:
		_return_to_title_screen()
		return
	_return_to_title_screen()
	settings_panel.show_tween()
	_current_subscene = SubScene.SETTINGS_MENU


func _on_editor_pressed() -> void:
	if fade_screen.is_fading:
		return
	$"../MenuLoop".playing = false
	SFXManager.play_sfx("res://assets/sounds/sfx/game_sfx/LevelPlay.ogg")
	zoom_in_title_screen_layer()
	fade_screen.fade_in()
	await fade_screen.fade_finished
	if DiscordRPCManager.available:
		DiscordRPCHandler.set_details("Creating a level")
		DiscordRPCHandler.refresh()
	get_tree().change_scene_to_packed(AssetManager.editor_packed)


func _on_bug_pressed() -> void:
	OS.shell_open("https://codeberg.org/godot-dash/godot-dash/issues/new/choose")


func _on_quit_game_pressed() -> void:
	if fade_screen.is_fading:
		return
	fade_screen.fade_in()
	zoom_in_title_screen_layer()
	await fade_screen.fade_finished
	get_tree().quit()


func _on_back_button_pressed() -> void:
	_return_to_title_screen()
