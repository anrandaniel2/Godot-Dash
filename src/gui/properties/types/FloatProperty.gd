@tool
class_name FloatProperty
extends Property

signal value_changed(value: float)
signal interaction_ended(value: float, previous: float)

@export var default: float
@export var min_value: float
@export var max_value: float = 100.0
@export var step: float = 0.001
@export var rounded: bool
@export var allow_lesser: bool
@export var allow_greater: bool
@export var prefix: String
@export var suffix: String
@export var draw_slider: bool
@export var slider_tick_count: int
@export var slider_ticks_on_borders: bool
@export var slider_ticks_position: Slider.TickPosition
@export var is_percentage: bool
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var input: DragBox


func _ready() -> void:
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	input = NodeUtils.get_node_or_add(self, "Input", DragBox, NodeUtils.INTERNAL)
	input.value_changed.connect(func(new_value: float): value_changed.emit(new_value if not is_percentage else new_value / 100.0))
	input.interaction_ended.connect(func(new_value: float, previous_value: float): interaction_ended.emit(new_value if not is_percentage else new_value / 100.0, previous_value if not is_percentage else previous_value / 100.0))
	renamed.connect(refresh)
	var line_edit = input.get_line_edit()
	line_edit.text_submitted.connect(submitted_release_focus)
	line_edit.editing_toggled.connect(unedit_release_focus)
	refresh()
	NodeUtils \
			.get_node_or_add(self, "PropertyReset", PropertyReset, NodeUtils.INTERNAL) \
			.set_input(input)


func set_value(new_value: float) -> void:
	set_value_no_signal(new_value)
	value_changed.emit(new_value)


func set_value_no_signal(new_value: float) -> void:
	_value = new_value
	input.set_value_no_signal_refresh(new_value if not is_percentage else new_value * 100.0)


func get_value() -> float:
	return input.get_value() if not is_percentage else input.get_value() / 100.0


func reset() -> void:
	set_value(default)


func refresh() -> void:
	label.text = name
	input.set_block_signals(true)
	input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	input.min_value = min_value if not is_percentage else min_value * 100.0
	input.max_value = max_value if not is_percentage else max_value * 100.0
	input.step = step if not is_percentage else step * 100.0
	input.rounded = rounded
	input.allow_greater = allow_greater
	input.allow_lesser = allow_lesser
	input.prefix = prefix
	input.suffix = suffix if not is_percentage else "%"
	input.select_all_on_focus = true
	input.draw_slider = draw_slider
	input.slider_tick_count = slider_tick_count
	input.slider_ticks_on_borders = slider_ticks_on_borders
	input.slider_ticks_position = slider_ticks_position
	input.set_block_signals(false)
	if Engine.is_editor_hint():
		reset()


func set_input_state(enabled: bool) -> void:
	input.editable = enabled
