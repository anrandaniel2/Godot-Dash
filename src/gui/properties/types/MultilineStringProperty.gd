@tool
class_name MultilineStringProperty
extends Property

signal value_changed(value: String)
signal interaction_ended(value: String, previous: String)

@export var default: String
@export var placeholder: String
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var input: TextEdit
var _previous_text: String


func _ready() -> void:
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	input = NodeUtils.get_node_or_add(self, "Input", TextEdit, NodeUtils.INTERNAL)
	input.text_changed.connect(func(): value_changed.emit(input.get_text()))
	input.focus_entered.connect(
		func():
			Editor.shortcut_blocker = input
			_previous_text = input.get_text()
	)
	input.focus_exited.connect(
		func():
			Editor.shortcut_blocker = null
			_value = input.get_text()
			interaction_ended.emit(input.get_text(), _previous_text)
	)
	renamed.connect(refresh)
	refresh()
	(
		NodeUtils \
		.get_node_or_add(self, "PropertyReset", PropertyReset, NodeUtils.INTERNAL) \
		.set_input(input)
	)


func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel") and Editor.shortcut_blocker == input:
		input.release_focus.call_deferred()


func set_value(new_value: String) -> void:
	var previous: String = _value if _value is String else ""
	set_value_no_signal(new_value)
	value_changed.emit(new_value)
	interaction_ended.emit(new_value, previous)


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
	input.scroll_smooth = true
	input.scroll_fit_content_height = true
	input.custom_minimum_size.y = 3 * input.get_line_height() + 2 * input.get_theme_constant(&"line_spacing")
	if Engine.is_editor_hint():
		reset()


func set_input_state(enabled: bool) -> void:
	input.editable = enabled
