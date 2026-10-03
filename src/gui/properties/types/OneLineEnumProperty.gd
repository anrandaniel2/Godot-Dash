@tool
class_name OneLineEnumProperty
extends Property

signal value_changed(value: int)
signal interaction_ended(value: int, previous: int)

@export var default: int
@export var fields: PackedStringArray
@export var icons: Array[Texture2D]
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var input: EnumButton


func _ready() -> void:
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	input = NodeUtils.get_node_or_add(self, "Input", EnumButton, NodeUtils.INTERNAL)
	input.value_changed.connect(value_changed.emit)
	input.interaction_ended.connect(interaction_ended.emit)
	renamed.connect(refresh)
	refresh()
	NodeUtils \
			.get_node_or_add(self, "PropertyReset", PropertyReset, NodeUtils.INTERNAL) \
			.set_input(input)


func set_value(new_value: int) -> void:
	assert(new_value < fields.size(), "IndexError: variant index is out of range")
	input.set_value_no_signal(new_value)
	value_changed.emit(new_value)


func set_value_no_signal(new_value: int) -> void:
	assert(new_value < fields.size(), "IndexError: variant index is out of range")
	input.set_value_no_signal(new_value)


func get_value() -> int:
	return input.get_value()


func reset() -> void:
	set_value(default)


func refresh() -> void:
	label.text = name
	input.set_block_signals(true)
	input.custom_minimum_size.y = MIN_HEIGHT
	input.variants = fields
	input.icons = icons
	input.default = default
	input.update()
	input.set_block_signals(false)
	if Engine.is_editor_hint():
		reset()


func set_input_state(enabled: bool) -> void:
	input.set_input_state(enabled)
