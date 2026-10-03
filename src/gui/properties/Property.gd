@abstract
@icon("res://addons/at-icons/control/sliders.svg")
class_name Property
extends BoxContainer

const MIN_HEIGHT: float = 28.0

# Used to serialize the value
@warning_ignore("unused_private_class_variable")
var _value: Variant
var label: Label:
	set(value):
		label = value
		label.theme_type_variation = &"PropertyLabel"


func _init() -> void:
	custom_minimum_size.y = 32.0
	vertical = true


@abstract func reset() -> void


@abstract func refresh() -> void


@abstract func set_input_state(enabled: bool) -> void


func submitted_release_focus(_new_value):
	get_viewport().gui_release_focus()


func unedit_release_focus(toggled_on):
	if not toggled_on:
		get_viewport().gui_release_focus()
