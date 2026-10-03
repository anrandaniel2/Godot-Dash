@tool
class_name BoolProperty
extends Property

signal value_changed(value: bool)
signal interaction_ended(value: bool, previous: bool)

@export var default: bool
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var input: CheckBox


func _ready() -> void:
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	input = NodeUtils.get_node_or_add(self, "Input", CheckBox, NodeUtils.INTERNAL) as CheckBox
	input.toggled.connect(func(new_value: bool): value_changed.emit(new_value))
	input.toggled.connect(func(new_value: bool): interaction_ended.emit(new_value, not new_value))
	input.text = "Enabled"
	input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	input.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	input.flat = true
	renamed.connect(refresh)
	refresh()
	NodeUtils \
			.get_node_or_add(self, "PropertyReset", PropertyReset, NodeUtils.INTERNAL) \
			.set_input(input)


func set_value(new_value: bool) -> void:
	_value = new_value
	input.set_pressed_no_signal(new_value)
	value_changed.emit(new_value)


func set_value_no_signal(new_value: bool) -> void:
	_value = new_value
	input.set_pressed_no_signal(new_value)


func get_value() -> bool:
	return input.is_pressed()


func reset() -> void:
	set_value(default)


func refresh() -> void:
	label.text = name
	if Engine.is_editor_hint():
		reset()


func set_input_state(enabled: bool) -> void:
	input.disabled = not enabled
