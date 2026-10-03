@tool
class_name StringProperty
extends Property

signal value_changed(value: String)
signal interaction_ended(value: String, previous: String)

@export var default: String
@export var placeholder: String
@export var select_all_on_focus: bool
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var input: LineEdit
var _previous_text: String


func _ready() -> void:
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	input = NodeUtils.get_node_or_add(self, "Input", LineEdit, NodeUtils.INTERNAL)
	input.text_changed.connect(func(new_value: String): value_changed.emit(new_value))
	input.text_submitted.connect(func(new_value: String): interaction_ended.emit(new_value, _previous_text))
	input.text_submitted.connect(submitted_release_focus)
	input.editing_toggled.connect(unedit_release_focus)
	input.editing_toggled.connect(
		func(toggled_on: bool):
			if toggled_on:
				_previous_text = input.text
	)
	renamed.connect(refresh)
	refresh()
	NodeUtils \
			.get_node_or_add(self, "PropertyReset", PropertyReset, NodeUtils.INTERNAL) \
			.set_input(input)


func set_value(new_value: String) -> void:
	set_value_no_signal(new_value)
	value_changed.emit(new_value)


func set_value_no_signal(new_value: String) -> void:
	_value = new_value
	input.set_text(new_value)


func get_value() -> String:
	return input.get_text()


func reset() -> void:
	set_value(default)


func refresh() -> void:
	label.text = name
	input.focus_mode = Control.FOCUS_CLICK
	input.placeholder_text = placeholder
	input.select_all_on_focus = select_all_on_focus
	if Engine.is_editor_hint():
		reset()


func set_input_state(enabled: bool) -> void:
	input.editable = enabled
