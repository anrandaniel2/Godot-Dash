class_name PauseMenu
extends CanvasLayer

enum Leave {
	CONTINUE,
	CANCEL,
}

signal paused
signal unpaused
signal practice_mode_toggled(toggled_on: bool)

@export var level_name_label: Label
@export var restart_button: Button
@export var practice_button: Button
@export var edit_button: Button
@export var play_button: Button
@export var replay_button: Button

var tween: Tween
var settings_were_open: bool
var replays_were_open: bool
var leave_callback: Callable


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	LevelManager.pause_menu = self
	$Settings.get_node(^"MarginContainer/SettingsMenu").closed.connect(_on_settings_pressed)
	$Replays.get_node(^"MarginContainer/ReplaysMenu/SmoothScrollContainer/ReplayPanelLoader").replay_started.connect(toggle_pause_menu)
	update_buttons_visibility.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if LevelManager.level_playing and event.is_action_pressed(&"restart_level"):
		_on_restart_pressed()
	if event.is_action_pressed(&"pause_level") and Editor.shortcut_blocker == null and not SceneManager.is_transitioning:
		toggle_pause_menu()
	if event.is_action_pressed(&"hide_pause_menu") and get_tree().paused:
		if visible:
			hide_tween()
			settings_were_open = $Settings.visible
			replays_were_open = $Settings.visible
			$Settings.hide_tween()
			$Replays.hide_tween()
		else:
			show_tween()
			if settings_were_open:
				$Settings.show_tween()
			if replays_were_open:
				$Replays.show_tween()


func _notification(what: int) -> void:
	if not is_inside_tree():
		return
	if LevelManager.level_playing and not get_tree().paused and what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		toggle_pause_menu()


func update_buttons_visibility() -> void:
	restart_button.visible = not Editor.in_editor
	practice_button.visible = not Editor.in_editor and not (LevelManager.player and LevelManager.player.in_replay)
	edit_button.visible = not Editor.in_editor and LevelManager.current_level and LevelManager.current_level.is_editable
	play_button.visible = Editor.in_editor
	replay_button.visible = not Editor.in_editor


func show_tween() -> void:
	show()
	if tween:
		tween.stop()
	tween = create_tween().set_ignore_time_scale(true)
	tween.tween_property($Menu, ^"position:x", 0, Config.transition_duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT).from(-$Menu.size.x)
	await tween.finished


func hide_tween() -> void:
	if tween:
		tween.stop()
	tween = create_tween().set_ignore_time_scale(true)
	tween.tween_property($Menu, ^"position:x", -$Menu.size.x, Config.transition_duration).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUINT)
	await tween.finished
	hide()


func toggle_pause_menu() -> void:
	level_name_label.text = LevelManager.current_level_path.get_file().get_basename() if not LevelManager.current_level_path.is_empty() else Constants.DEFAULT_LEVEL_NAME
	get_tree().paused = not get_tree().paused
	if get_tree().paused:
		paused.emit()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if LevelManager.player:
			LevelManager.player.get_node("Icon").process_mode = Node.PROCESS_MODE_PAUSABLE
		if settings_were_open:
			$Settings.show_tween()
		if replays_were_open:
			$Replays.show_tween()
		show_tween()
	else:
		unpaused.emit()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Editor.in_editor else Input.MOUSE_MODE_CONFINED_HIDDEN
		if LevelManager.player:
			LevelManager.player.get_node("Icon").process_mode = Node.PROCESS_MODE_ALWAYS
		settings_were_open = $Settings.target_visible
		replays_were_open = $Replays.target_visible
		if $Settings.target_visible:
			$Settings.hide_tween()
		if $Replays.target_visible:
			$Replays.hide_tween()
		hide_tween()


func _on_leave_pressed() -> void:
	var scene_tree: SceneTree = get_tree()
	if Editor.in_editor:
		scene_tree.paused = false
		await Editor.root.stop_playtest()
		scene_tree.paused = true
	var can_continue: Leave = Leave.CONTINUE
	if leave_callback and leave_callback.is_valid():
		can_continue = await leave_callback.call()
	$Settings.hide_tween()
	hide_tween()
	if can_continue == Leave.CANCEL:
		return
	LevelManager.platformer = false
	LevelManager.practice_mode = false
	LevelManager.practice_level_snapshots.clear()
	LevelManager.level_playing = false
	LevelManager.current_level_path = ""
	AssetManager.unload_all()
	SFXManager.cancel_all_sfx()
	SFXManager.play_sfx("res://assets/sounds/sfx/game_sfx/LevelQuit.ogg")
	SceneManager.is_transitioning = true
	AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Music"), true)
	LevelManager.current_level.process_mode = Node.PROCESS_MODE_DISABLED
	await LevelManager.game_scene.fade_screen.fade_finished
	scene_tree.paused = false
	LevelManager.game_scene = null
	if Editor.clipboard:
		Editor.clipboard.clear()
	SceneManager.is_transitioning = false
	scene_tree.change_scene_to_packed(AssetManager.title_screen_packed)
	AudioServer.set_bus_mute.call_deferred(AudioServer.get_bus_index(&"Music"), false)


func _on_restart_pressed() -> void:
	get_tree().paused = false
	unpaused.emit()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Editor.in_editor else Input.MOUSE_MODE_CONFINED_HIDDEN
	hide()
	var should_use_practice_snapshot: bool = not LevelManager.practice_level_snapshots.is_empty()
	if Editor.in_editor and not should_use_practice_snapshot:
		Editor.root.stop_playtest()
	else:
		LevelManager.game_scene.restart_level()


func _on_edit_pressed() -> void:
	Editor.level_data_snapshot = LevelOperationsHandler.load_level_data_from_path(LevelManager.current_level_path)
	if DiscordRPCManager.available:
		DiscordRPCHandler.set_details("Creating a level")
		DiscordRPCHandler.refresh()
	SceneManager.is_transitioning = true
	AudioServer.set_bus_mute(AudioServer.get_bus_index(&"Music"), true)
	LevelManager.current_level.process_mode = Node.PROCESS_MODE_DISABLED
	var fade_screen: FadeScreen = LevelManager.game_scene.fade_screen
	get_tree().paused = false
	LevelManager.level_playing = false
	fade_screen.fade_in()
	await fade_screen.fade_finished
	SceneManager.is_transitioning = false
	get_tree().change_scene_to_packed(AssetManager.editor_packed)
	AudioServer.set_bus_mute.call_deferred(AudioServer.get_bus_index(&"Music"), false)


func _on_settings_pressed() -> void:
	if $Settings.target_visible:
		$Settings.hide_tween()
		return
	$Settings.show_tween()
	if $Replays.target_visible:
		$Replays.hide_tween()


func _on_bug_pressed() -> void:
	OS.shell_open("https://codeberg.org/godot-dash/godot-dash/issues/new/choose")


func _on_practice_toggled(toggled_on: bool) -> void:
	LevelManager.practice_mode = toggled_on
	# Forward the signal to toggle the visibility of the touchscreen practice UI in GameScene
	practice_mode_toggled.emit(toggled_on)
	if not toggled_on:
		LevelManager.practice_level_snapshots.clear()
		var should_use_practice_snapshot: bool = not LevelManager.practice_level_snapshots.is_empty()
		if Editor.in_editor and not should_use_practice_snapshot:
			Editor.root.stop_playtest()
		else:
			LevelManager.game_scene.restart_level()
	elif LevelManager.player:
		var player: Player = LevelManager.player
		player.last_automatic_checkpoint_position = Vector2.INF
	if Editor.in_editor:
		restart_button.visible = toggled_on
	toggle_pause_menu()


func _on_replays_pressed() -> void:
	if $Replays.target_visible:
		$Replays.hide_tween()
		return
	$Replays.show_tween()
	if $Settings.target_visible:
		$Settings.hide_tween()


func _on_save_and_play_pressed() -> void:
	Editor.root.stop_playtest()
	var save_result: Error = await Editor.root.level_operations_handler.save_level()
	if save_result != OK:
		return
	toggle_pause_menu()
	var fade_screen: FadeScreen = LevelManager.game_scene.fade_screen
	fade_screen.fade_in()
	await fade_screen.fade_finished
	if DiscordRPCManager.available:
		DiscordRPCHandler.set_details("Playing a level")
		DiscordRPCHandler.refresh()
	LevelManager.attempt = 0
	SceneManager.set_current_scene(SceneManager.Scene.LEVEL)
	get_tree().change_scene_to_packed(AssetManager.game_scene_packed)
