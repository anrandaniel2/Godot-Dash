@tool
class_name FlagsProperty
extends Property

signal value_changed(value: int)
signal interaction_ended(value: int, previous: int)

@export var default: int
@export var flags: PackedStringArray:
	set(value):
		flags = value
		notify_property_list_changed()
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var input_container: Container
var inputs: Array[CheckBox]


func _ready() -> void:
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	renamed.connect(refresh)
	refresh()
	if _value == null:
		_value = 0
	NodeUtils \
			.get_node_or_add(self, "PropertyReset", PropertyReset, NodeUtils.INTERNAL) \
			.set_input(input_container)


func _validate_property(property: Dictionary) -> void:
	if property.name == "default":
		property.hint = PROPERTY_HINT_FLAGS
		property.hint_string = ",".join(flags)


func set_value(new_value: int) -> void:
	var previous: int = _value
	set_value_no_signal(new_value)
	value_changed.emit(new_value)
	interaction_ended.emit(new_value, previous)


func set_value_no_signal(new_value: int) -> void:
	_value = new_value
	for i in flags.size():
		inputs[i].set_pressed_no_signal((_value >> i) & 1)


func get_value() -> int:
	return _value


func reset() -> void:
	set_value(default)


func refresh() -> void:
	label.text = name
	if input_container:
		input_container.queue_free()
		await get_tree().process_frame
		inputs.clear()
	input_container = NodeUtils.get_node_or_add(self, "InputContainer", VBoxContainer, NodeUtils.INTERNAL)
	for i in flags.size():
		var flag_input: CheckBox = NodeUtils.get_node_or_add(input_container, flags[i], CheckBox, NodeUtils.INTERNAL)
		flag_input.text = flags[i]
		flag_input.toggled.connect(
			func(pressed: bool):
				var old_value: int = _value
				if pressed:
					_value |= 1 << i
				else:
					_value &= ~(1 << i)
				value_changed.emit(_value)
				interaction_ended.emit(_value, old_value)
		)
		inputs.append(flag_input)
	if Engine.is_editor_hint():
		reset()


func set_input_state(enabled: bool) -> void:
	for input in inputs:
		input.disabled = not enabled
