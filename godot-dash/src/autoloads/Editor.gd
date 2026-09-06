extends Node

enum EditorMode {
	PLACE,
	EDIT,
	SELECTION_FILTERS,
}

var root: EditorScene
var in_editor: bool:
	get():
		return root != null
var clipboard: Selection
var snapshot := PackedScene.new()
var level_data_snapshot: Dictionary
var level_history_version: int = 1
var shortcut_blocker: Node
var viewport: EditorViewport
var version_history: UndoRedo
var render_mode_manager: RenderMode
var is_picking_node: bool

# MOBILE CONTROLS
var swipe: bool = false
var delete: bool = false


func is_text_input_focused() -> bool:
	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	return focus_owner is LineEdit or focus_owner is TextEdit


func clear_data() -> void:
	snapshot = PackedScene.new()
	level_data_snapshot.clear()
	level_history_version = 1
	version_history = UndoRedo.new()
	root.edit_handler.selection = Selection.EMPTY()
	clipboard = Selection.EMPTY()
