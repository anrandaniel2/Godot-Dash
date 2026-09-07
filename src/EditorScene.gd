class_name EditorScene
extends Control

enum EditorAction {
	SWIPE = 1 << 0,
	ROTATE = 1 << 1,
	FREE_MOVE = 1 << 2,
	SNAP = 1 << 3,
}

@export var edit_handler: EditHandler
@export var level_operations_handler: LevelOperationsHandler
@export var block_palette_button_group: ButtonGroup
@export var editor_camera: MapCamera2D
@export var view_menu: MenuBarView
@export var inspector_tree: InspectorTree
@export var inspector_manager: InspectorManager

var level: Level:
	set(value):
		level = value
		$EditHandler.level = value
var editor_actions: int
var just_stopped_playtest: bool

@onready var placed_objects_collider := $PlacedObjectsCollider as Area2D


func _enter_tree() -> void:
	$SaveChangesBeforeLeaving.add_button("Don't Save", false, "dontsave")
	$SaveChangesBeforeQuitting.add_button("Don't Save", false, "dontsave")
	SceneManager.set_current_scene(SceneManager.Scene.EDITOR)


func _ready() -> void:
	Editor.root = self
	Editor.viewport = %Viewport

	if not Config.has_seen_navigation_help:
		Config.has_seen_navigation_help = true
	else:
		$NavigationHelpDialog.queue_free()

	if SceneManager.from_title_screen() or SceneManager.from_level():
		_fade_enter()

	if not Editor.level_data_snapshot.is_empty():
		level = Level.from_data(Editor.level_data_snapshot)
		$GameScene.add_loaded_level(level)
	else:
		level = Level.new()
		level.name = Constants.DEFAULT_LEVEL_NAME
		LevelManager.game_scene.add_loaded_level(level)

	Editor.version_history = UndoRedo.new()
	Editor.clipboard = Selection.new()
	inspector_tree.refresh(Selection.EMPTY())
	inspector_tree.set_active_layer(0, 0)
	LevelManager.game_scene.pause_menu.leave_callback = _on_leave_pressed
	reset()


func _physics_process(_delta: float) -> void:
	if LevelManager.level_playing:
		return
	placed_objects_collider.global_position = get_local_mouse_position()

	get_tree().auto_accept_quit = not level_was_modified()

	if (
			%Modes.current_tab == Editor.EditorMode.PLACE
			and not Editor.is_picking_node
			and (
					Input.is_action_just_pressed(&"editor_add", true) or Input.is_action_just_pressed(&"editor_remove", true)
					or Input.is_action_pressed(&"editor_add_swipe", true) or Input.is_action_pressed(&"editor_remove_swipe", true)
			)
	):
		$PlaceHandler.handle_place(block_palette_button_group, placed_objects_collider, level)


func _unhandled_input(event: InputEvent) -> void:
	if not edit_handler.any_gizmo_is_open():
		if event.is_action_pressed(&"ui_redo", true):
			Editor.version_history.redo()
		elif event.is_action_pressed(&"ui_undo", true):
			Editor.version_history.undo()
	if event.is_action_pressed(&"editor_hide_panels"):
		%View.toggle_maximize_viewport()
	if not any_dialog_is_open() and not $EditHandler.any_gizmo_is_open():
		if event.is_action_pressed(&"editor_place_mode"):
			%Modes.current_tab = 0
		elif event.is_action_pressed(&"editor_edit_mode"):
			%Modes.current_tab = 1
		elif event.is_action_pressed(&"editor_selection_filters_mode"):
			%Modes.current_tab = 2
		elif event.is_action_pressed(&"editor_toggle_playtest"):
			_on_playtest_pressed()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and level_was_modified():
		var scene_tree: SceneTree = get_tree()
		$SaveChangesBeforeQuitting.show()
		var canceled: Signal = $SaveChangesBeforeQuitting.canceled
		var didnt_save: Signal = $SaveChangesBeforeQuitting.custom_action
		var saved: Signal = $LevelOperationsHandler.level_saved
		match await Signals.first(canceled, didnt_save, saved):
			canceled:
				return
			didnt_save, saved:
				$SaveChangesBeforeLeaving.hide()
				scene_tree.quit()


func reset() -> void:
	LevelManager.attempt = 1
	LevelManager.level_playing = false
	$EditorCamera.enabled = true
	%Modes.visible = view_menu.is_item_checked(MenuBarView.BOTTOM_PANEL)
	%Inspector.visible = view_menu.is_item_checked(MenuBarView.SIDE_PANEL)
	%RenderModes.show()
	$GameScene/PercentageLayer.hide()
	$PlaceHandler.placed_object_rotation_degrees = 0.0
	%View.reset()
	LevelManager.player.refresh_debug_trail()
	LevelManager.player_camera.enabled = false
	LevelManager.game_scene.reset()
	if not Editor.level_data_snapshot.is_empty():
		level.use_data(Editor.level_data_snapshot)
	var player: Player = LevelManager.player
	_load_default_player_data_component(player.get_node(^"EditorPlayerSelectionCollider").query(DefaultPlayerDataComponent))
	var editor_grid: EditorGrid = $GameScene/EditorGridParallax/EditorGrid
	editor_grid.visible = view_menu.is_item_checked(MenuBarView.GRID)
	if editor_grid.visible:
		editor_grid.queue_redraw()

	if Editor.is_picking_node:
		Editor.is_picking_node = false
		Editor.shortcut_blocker.cancel_interactive_picker()

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	NodeUtils.connect_once($EditorCamera.zoom_changed, $GameScene/EditorGridParallax/EditorGrid.queue_redraw)
	$EditHandler.placed_objects_collider = placed_objects_collider
	$EditHandler.editor_modes = %Modes
	%MenuBarContainer.show()
	LevelManager.touchscreen_controls.hide()

	if not $EditHandler.selection.is_empty():
		$EditHandler.selection.for_each(EditHandler.add_selection_highlight)
		# HACK: ensure the interactable panel validates the properties
		$EditHandler.selection_changed.emit($EditHandler.selection)


func texture_variation_overlapping(type: EditorSelectionCollider.Type, id: int) -> bool:
	if not placed_objects_collider.has_overlapping_areas():
		return false
	if placed_objects_collider.get_overlapping_areas()[-1].get_parent() is Interactable:
		return true
	if placed_objects_collider.get_overlapping_areas()[-1].type == type:
		return placed_objects_collider.get_overlapping_areas()[-1].id == id
	return false


func level_was_modified() -> bool:
	if not level or not Editor.version_history:
		return false
	return Editor.version_history.get_version() > Editor.level_history_version


func any_dialog_is_open() -> bool:
	var dialogs := NodeUtils.get_children_of_type(self, AcceptDialog)
	for dialog in dialogs:
		if dialog.visible:
			return true
	return false


func start_playtest() -> void:
	edit_handler.remove_gizmo()
	edit_handler.selection.for_each(EditHandler.remove_selection_highlight)
	edit_handler.process_mode = Node.PROCESS_MODE_DISABLED
	%ColorChannelEditor.hide_properties()
	await get_tree().process_frame
	edit_handler.selection_changed.emit(Selection.EMPTY())
	level.start_position = LevelManager.player.position
	Editor.level_data_snapshot = level.to_data()
	Editor.snapshot.pack(self)
	%MenuBarContainer.hide()
	%Modes.hide()
	%Inspector.hide()
	%RenderModes.hide()
	%Viewport.mouse_filter = MOUSE_FILTER_STOP
	$GameScene/EditorGridParallax/EditorGrid.visible = not Config.hide_grid_on_playtest
	$GameScene.pause_menu.practice_button.show()
	LevelManager.touchscreen_controls.visible = Config.is_touch_screen
	$LevelOperationsHandler.pause_autosave()
	$GameScene.start_level()
	LevelManager.player.process_mode = Node.PROCESS_MODE_INHERIT


func stop_playtest() -> void:
	edit_handler.process_mode = Node.PROCESS_MODE_INHERIT
	%Playtest.disabled = true
	LevelManager.player.process_mode = Node.PROCESS_MODE_INHERIT
	reset()
	# Static objects share the level's physics bodies while playing (see
	# LevelPhysics); give every object back its own collision for editing.
	LevelPhysics.teardown(LevelManager.current_level)
	# Static placements drew through shared batches while playing; bring every
	# placement's own art back for editing.
	LevelBatching.teardown(LevelManager.current_level)
	LevelManager.practice_mode = false
	LevelManager.practice_level_snapshots.clear()
	just_stopped_playtest = true
	await get_tree().physics_frame
	LevelManager.player.process_mode = Node.PROCESS_MODE_DISABLED
	NodeUtils.free_children($GameScene.checkpoint_parent)
	$GameScene.pause_menu.practice_button.hide()
	$GameScene.pause_menu.practice_button.set_pressed_no_signal(false)
	$GameScene.pause_menu.restart_button.hide()
	$LevelOperationsHandler.unpause_autosave()
	%Playtest.disabled = false
	Editor.viewport.remove_cursor_shape_override()
	LevelManager.touchscreen_controls.disable_platformer()
	await get_tree().process_frame
	just_stopped_playtest = false


func _fade_enter() -> void:
	$GameScene.fade_screen.fade_out()
	create_tween() \
			.tween_property($EditorCamera, ^"zoom", PlayerCamera.DEFAULT_ZOOM, Config.transition_duration) \
			.set_ease(Tween.EASE_OUT) \
			.set_trans(Tween.TRANS_EXPO) \
			.from(PlayerCamera.DEFAULT_ZOOM / 2.0)


func _on_playtest_pressed() -> void:
	$EditorCamera.enabled = not $EditorCamera.enabled
	$GameScene/PlayerCamera.enabled = not $GameScene/PlayerCamera.enabled
	if $GameScene/PlayerCamera.enabled:
		start_playtest()
	else:
		stop_playtest()


func _on_leave_pressed() -> PauseMenu.Leave:
	if level_was_modified():
		$SaveChangesBeforeLeaving.show()
		var canceled: Signal = $SaveChangesBeforeLeaving.canceled
		var didnt_save: Signal = $SaveChangesBeforeLeaving.custom_action
		var saved: Signal = $LevelOperationsHandler.level_saved
		match await Signals.first(canceled, didnt_save, saved):
			canceled:
				return PauseMenu.Leave.CANCEL
			didnt_save, saved:
				$SaveChangesBeforeLeaving.hide()
	Editor.clear_data()
	LevelManager.game_scene.fade_screen.fade_in()
	create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS) \
			.tween_property($EditorCamera, ^"zoom", $EditorCamera.zoom / 2.0, Config.transition_duration) \
			.set_ease(Tween.EASE_IN) \
			.set_trans(Tween.TRANS_EXPO)
	if DiscordRPCManager.available:
		DiscordRPCHandler.set_details("Title Screen")
		DiscordRPCHandler.refresh()
	return PauseMenu.Leave.CONTINUE


func _load_default_player_data_component(component: DefaultPlayerDataComponent) -> void:
	component.platformer = level.platformer
	component.reverse = level.start_reverse
	if level.start_speed_preset == EasedSpeedChangerComponent.SpeedPreset.CUSTOM:
		component.manual_speed = level.start_speed
	component.speed = level.start_speed
	component.speed_preset = level.start_speed_preset
	component.gameplay_rotation = level.start_gameplay_rotation_degrees
	component.gravity_multiplier = level.start_gravity_multiplier
	component.flipped_gravity = level.start_gravity_flip < 0
	component.internal = level.start_internal_gamemode
	component.displayed = level.start_displayed_gamemode
	component.freefly = level.start_freefly
