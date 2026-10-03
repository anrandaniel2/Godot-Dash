@tool
class_name EnumProperty
extends Property

signal value_changed(value: int)
signal interaction_ended(value: int, previous: int)

@export var default: int
@export var fields: PackedStringArray
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var input: OptionButton
var _previous_variant: int


func _ready() -> void:
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	input = NodeUtils.get_node_or_add(self, "Input", OptionButton, NodeUtils.INTERNAL)
	input.pressed.connect(func(): _previous_variant = get_value())
	input.item_selected.connect(value_changed.emit)
	input.item_selected.connect(func(new_value: int): interaction_ended.emit(new_value, _previous_variant))
	renamed.connect(refresh)
	refresh()
	NodeUtils \
			.get_node_or_add(self, "PropertyReset", PropertyReset, NodeUtils.INTERNAL) \
			.set_input(input)


func set_value(new_value: int) -> void:
	set_value_no_signal(new_value)
	value_changed.emit(new_value)


func set_value_no_signal(new_value: int) -> void:
	_previous_variant = input.selected
	input.selected = new_value


func get_value() -> int:
	return input.selected


func reset() -> void:
	set_value(default)


func refresh() -> void:
	label.text = name
	input.clear()
	input.theme_type_variation = &"TransButton" if fields[0].begins_with("Trans ") and Config.enable_easter_eggs else &""
	input.custom_minimum_size.y = MIN_HEIGHT
	input.search_bar_enabled = not Config.is_touch_screen
	input.search_bar_fuzzy_search_enabled = true
	for field in fields:
		input.add_item(field if Config.enable_easter_eggs else field.trim_prefix("Trans "))
	input.get_popup().allow_search = true
	if Engine.is_editor_hint():
		reset()


func set_input_state(enabled: bool) -> void:
	input.disabled = not enabled
