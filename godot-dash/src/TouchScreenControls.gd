class_name TouchScreenControls
extends CanvasLayer

func _ready() -> void:
	LevelManager.touchscreen_controls = self
	visible = Config.is_touch_screen


func _pause() -> void:
	LevelManager.pause_menu.toggle_pause_menu()


func enable_platformer(wave: bool = false) -> void:
	if not Config.is_touch_screen:
		return
	$LeftRight.show()
	$Down.visible = wave


func disable_platformer() -> void:
	$LeftRight.hide()
	$Down.hide()
