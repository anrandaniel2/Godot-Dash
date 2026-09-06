extends PopupMenu

@export var game_scene: GameScene
@export var side_panel: Container
@export var bottom_panel: Container

## MOBILE ONLY


func _ready() -> void:
	if not Config.is_touch_screen:
		queue_free()


func _on_index_pressed(index: int) -> void:
	match index:
		0: # Menu
			game_scene.pause_menu.toggle_pause_menu()
	set_item_checked(index, not is_item_checked(index))
