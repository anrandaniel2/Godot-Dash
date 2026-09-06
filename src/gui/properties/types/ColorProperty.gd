@tool
class_name ColorProperty
extends Property

signal value_changed(color: Color)
signal interaction_ended(color: Color, previous: Color)

@export var default: Color
@export var edit_alpha: bool = true
@export var edit_intensity: bool = true
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var input: ColorPickerButton
var _previous_color: Color


func _ready() -> void:
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	input = NodeUtils.get_node_or_add(self, "Input", ColorPickerButton, NodeUtils.INTERNAL)
	input.color_changed.connect(value_changed.emit)
	input.pressed.connect(func(): _previous_color = input.get_pick_color())
	input.popup_closed.connect(func(): interaction_ended.emit(input.get_pick_color(), _previous_color))
	renamed.connect(refresh)
	refresh()
	NodeUtils \
			.get_node_or_add(self, "PropertyReset", PropertyReset, NodeUtils.INTERNAL) \
			.set_input(input)


func set_value(new_value: Color) -> void:
	_value = new_value
	input.set_pick_color(new_value)
	value_changed.emit(new_value)


func set_value_no_signal(new_value: Color) -> void:
	_value = new_value
	input.set_pick_color(new_value)


func get_value() -> Color:
	return input.get_pick_color()


func reset() -> void:
	set_value(default)
	interaction_ended.emit(default, input.get_pick_color())


func refresh() -> void:
	label.text = name
	input.custom_minimum_size.y = MIN_HEIGHT
	input.edit_alpha = edit_alpha
	input.edit_intensity = edit_intensity
	if Engine.is_editor_hint():
		reset()


func set_input_state(enabled: bool) -> void:
	input.modulate.a = 1.0 if enabled else 0.1
	input.disabled = not enabled
