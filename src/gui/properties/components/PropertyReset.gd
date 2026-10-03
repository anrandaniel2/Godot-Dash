class_name PropertyReset
extends Node

var input: Control

@onready var parent := get_parent() as Property


func _unhandled_input(event: InputEvent) -> void:
	if (
			input.visible
			and event.is_action_pressed(&"gui_input_reset_default")
			and input.get_rect().has_point(parent.get_local_mouse_position())
	):
		parent.reset()


func set_input(value: Control) -> PropertyReset:
	input = value
	return self
