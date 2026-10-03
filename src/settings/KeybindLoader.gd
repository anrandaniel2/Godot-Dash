class_name KeybindLoader
extends VBoxContainer

@export var input_action: String


func _ready() -> void:
	refresh_inputs()


func refresh_inputs():
	for child in get_children():
		child.queue_free()

	for input_event in InputMap.action_get_events(input_action):
		var container := HBoxContainer.new()
		add_child(container)

		var button := Button.new()
		button.text = input_event.as_text()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		container.add_child(button)

		var remove_button := RemoveKeybindButton.new(self, input_event)
		container.add_child(remove_button)

	var add_button := AddKeybindButton.new(self)
	add_child(add_button)
	# HACK: Godot doesn't recalculate the size of the remove button after the custom minimum size is set
	item_rect_changed.emit()
