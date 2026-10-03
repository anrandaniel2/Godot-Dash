class_name MenuBarView
extends PopupMenu

enum {
	GRID,
	SIDE_PANEL,
	BOTTOM_PANEL,
	TOGGLE_MAXIMIZE_VIEWPORT,
}

@export var game_scene: Node2D
@export var side_panel: Container
@export var bottom_panel: Container

var is_viewport_maximized: bool = false


func reset() -> void:
	set_item_disabled(SIDE_PANEL, false)
	set_item_disabled(BOTTOM_PANEL, false)


func toggle_maximize_viewport() -> void:
	is_viewport_maximized = not is_viewport_maximized
	set_item_disabled(SIDE_PANEL, is_viewport_maximized)
	set_item_disabled(BOTTOM_PANEL, is_viewport_maximized)
	var panels: Array = [side_panel, bottom_panel]
	for i in panels.size():
		var panel: Control = panels[i]
		if is_item_checked(get_item_index(i + 1)):
			panel.visible = not panel.visible


func _on_index_pressed(index: int) -> void:
	set_item_checked(index, not is_item_checked(index))
	match index:
		GRID:
			game_scene.get_node("EditorGridParallax/EditorGrid").visible = is_item_checked(GRID)
		SIDE_PANEL:
			side_panel.visible = is_item_checked(SIDE_PANEL) and not is_viewport_maximized
		BOTTOM_PANEL:
			bottom_panel.visible = is_item_checked(BOTTOM_PANEL) and not is_viewport_maximized
		TOGGLE_MAXIMIZE_VIEWPORT:
			toggle_maximize_viewport()
