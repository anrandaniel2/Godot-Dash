extends PopupMenu

@export var edit_handler: EditHandler


func _on_index_pressed(index: int) -> void:
	match index:
		0: # Undo
			Editor.version_history.undo()
		1: # Redo
			Editor.version_history.redo()
		# --- Separator ---
		3: # Copy
			edit_handler.copy_selection()
		4: # Paste
			edit_handler.paste_selection()
		5: # Duplicate
			edit_handler.duplicate_selection()
		# --- Separator ---
		7: # Select All
			edit_handler.select_all()
		8: # Deselect All
			edit_handler.clear_selection()
		# --- Separator ---
		10: # Delete Selected
			edit_handler.delete_selection()
