class_name SettingsMenu
extends Container

signal closed


func _ready() -> void:
	Engine.max_fps = int(Config.max_fps)
	DisplayServer.window_set_vsync_mode(Config.vsync)
	AudioServer.set_bus_layout(load("user://default_bus_layout.tres"))
	_on_menu_blur_value_changed(Config.menu_blur)
	_on_blur_strength_value_changed(Config.blur_strength)
	_on_ui_color_value_changed(Config.ui_color)
	_on_texture_filtering_value_changed(Config.texture_filtering)
	_on_touch_screen_mode_value_changed(Config.touch_screen_mode)
	_on_window_mode_value_changed(Config.window_mode)
	_on_anti_aliasing_value_changed(Config.anti_aliasing)
	_on_render_scale_value_changed(int(Config.render_scale * 100.0))
	%"Render Scale".set_value_no_signal(int(Config.render_scale * 100.0))
	RenderingServer.global_shader_parameter_set(&"icon_hue_shift_speed", Config.icon_hue_shift_speed)
	var label = %"File Associations".get_node("VBoxContainer/Label")
	if OS.get_name() != "Linux":
		label.text = "File associations aren't currently available on %s" % OS.get_name()
		label.modulate.a = 0.5
		for child in %"File Associations".get_node("VBoxContainer/HBoxContainer").get_children():
			child.disabled = true
	elif OS.is_debug_build():
		label.text += "\nRegistering from the editor may cause unintended behavior"


func _on_menu_blur_value_changed(value: bool) -> void:
	RenderingServer.global_shader_parameter_set("menu_blur", value)


func _on_blur_strength_value_changed(value: float) -> void:
	RenderingServer.global_shader_parameter_set("blur_strength", value)


func _on_ui_color_value_changed(value: Color) -> void:
	RenderingServer.global_shader_parameter_set("ui_color", value)


func _on_touch_screen_mode_value_changed(value: int) -> void:
	match value:
		Config.TouchScreenMode.FOLLOW_DEVICE:
			Config.is_touch_screen = DisplayServer.is_touchscreen_available()
		Config.TouchScreenMode.FORCE_ENABLED:
			Config.is_touch_screen = true
		Config.TouchScreenMode.FORCE_DISABLED:
			Config.is_touch_screen = false


func _on_max_fps_value_changed(value: float) -> void:
	Engine.max_fps = int(value)


func _on_vsync_value_changed(id: int) -> void:
	DisplayServer.window_set_vsync_mode(id)


func _on_window_mode_value_changed(window_mode: Config.WindowMode) -> void:
	if not %"Window Mode".is_node_ready():
		return
	var display_server_window_mode: DisplayServer.WindowMode
	match window_mode:
		Config.WindowMode.WINDOWED:
			display_server_window_mode = DisplayServer.WindowMode.WINDOW_MODE_WINDOWED
			DisplayServer.window_set_flag(DisplayServer.WindowFlags.WINDOW_FLAG_BORDERLESS, false)
		Config.WindowMode.FULLSCREEN:
			display_server_window_mode = DisplayServer.WindowMode.WINDOW_MODE_FULLSCREEN
		Config.WindowMode.EXCLUSIVE_FULLSCREEN:
			display_server_window_mode = DisplayServer.WindowMode.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	DisplayServer.window_set_mode(display_server_window_mode)


func _on_anti_aliasing_value_changed(anti_aliasing_mode: Viewport.MSAA) -> void:
	var viewport: Viewport = get_viewport()
	if not viewport:
		return
	viewport.msaa_2d = anti_aliasing_mode


func _on_render_scale_value_changed(value: int) -> void:
	var window: Window = get_tree().root
	if not window:
		return
	window.content_scale_factor = value / 100.0
	Config.render_scale = value / 100.0


func _on_texture_filtering_value_changed(texture_filtering_mode: Config.TextureFilteringMode) -> void:
	match texture_filtering_mode:
		Config.TextureFilteringMode.NEAREST_NEIGHBOR:
			get_viewport().canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
		Config.TextureFilteringMode.LINEAR:
			get_viewport().canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
		Config.TextureFilteringMode.LINEAR_WITH_MIPMAPS:
			get_viewport().canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR_WITH_MIPMAPS


func _on_game_volume_value_changed(value: float) -> void:
	var master_bus: int = AudioServer.get_bus_index(&"Master")
	var mute_state: bool = AudioServer.is_bus_mute(master_bus)
	AudioServer.set_bus_volume_linear(master_bus, value / 100.0)
	AudioServer.set_bus_mute(master_bus, false)
	ResourceSaver.save(AudioServer.generate_bus_layout(), "user://default_bus_layout.tres")
	AudioServer.set_bus_mute(master_bus, mute_state)


func _on_music_volume_value_changed(value: float) -> void:
	AudioServer.set_bus_volume_linear(AudioServer.get_bus_index(&"Music"), value / 100.0)
	ResourceSaver.save(AudioServer.generate_bus_layout(), "user://default_bus_layout.tres")


func _on_game_sfx_volume_value_changed(value: float) -> void:
	AudioServer.set_bus_volume_linear(AudioServer.get_bus_index(&"Game SFX"), value / 100.0)
	ResourceSaver.save(AudioServer.generate_bus_layout(), "user://default_bus_layout.tres")


func _on_in_level_sfx_volume_value_changed(value: float) -> void:
	AudioServer.set_bus_volume_linear(AudioServer.get_bus_index(&"In Level SFX"), value / 100.0)
	ResourceSaver.save(AudioServer.generate_bus_layout(), "user://default_bus_layout.tres")


func _on_close_pressed() -> void:
	closed.emit()


func _on_apply_pressed() -> void:
	get_tree().paused = false
	if DiscordRPCManager.available:
		if Config.discord_rich_presence == false:
			DiscordRPCHandler.clear()
		else:
			DiscordRPCHandler.unclear()
	if LevelManager.current_level and Editor.in_editor:
		var edit_handler: EditHandler = Editor.root.edit_handler
		edit_handler.selection.for_each(EditHandler.remove_selection_highlight)
		edit_handler.selection.clear()
		if LevelManager.level_playing:
			LevelManager.practice_level_snapshots.clear()
		else:
			Editor.level_data_snapshot = Editor.root.level.to_data()
	if get_tree().reload_current_scene() != OK and Editor.in_editor:
		get_tree().change_scene_to_packed(Editor.snapshot)


func _on_register_pressed() -> void:
	var source: String = "res://dist/%s" % OS.get_name().to_lower()
	var dest: String = "user://tmp/file_associations"
	var dir: DirAccess = DirAccess.open(source)
	if not DirAccess.dir_exists_absolute(dest):
		DirAccess.make_dir_recursive_absolute(dest)
	for file in dir.get_files():
		if file.contains(".import"):
			continue
		dir.copy(source.path_join(file), dest.path_join(file))
	match OS.get_name():
		"Linux":
			OS.execute("bash", PackedStringArray([ProjectSettings.globalize_path(dest.path_join("install.sh")), OS.get_executable_path()]))
		_:
			pass
	dir = DirAccess.open(dest)
	for file in dir.get_files():
		dir.remove(file)
	dir.remove(dest)


func _on_unregister_pressed() -> void:
	var source: String = "res://dist/%s" % OS.get_name().to_lower()
	var dest: String = "user://tmp"
	var file: String
	match OS.get_name():
		"Linux":
			file = "uninstall.sh"
	var dir: DirAccess = DirAccess.open(source)
	if not DirAccess.dir_exists_absolute(dest):
		DirAccess.make_dir_recursive_absolute(dest)
	dir.copy(source.path_join(file), dest.path_join(file))
	match OS.get_name():
		"Linux":
			OS.execute("bash", PackedStringArray([ProjectSettings.globalize_path(dest.path_join(file))]))
		_:
			pass
	dir = DirAccess.open(dest)
	dir.remove(dest.path_join(file))
