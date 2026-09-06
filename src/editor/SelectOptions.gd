extends MarginContainer

func _ready() -> void:
	if not Config.is_touch_screen:
		queue_free()

func _on_swipe_toggled(toggled_on: bool) -> void:
	Editor.swipe = toggled_on


func _on_delete_toggled(toggled_on: bool) -> void:
	Editor.delete = toggled_on
