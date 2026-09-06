extends PopupMenu

func _on_index_pressed(index: int) -> void:
	match index:
		0: # Manual
			OS.shell_open("https://godot-dash.codeberg.page/editor/")
