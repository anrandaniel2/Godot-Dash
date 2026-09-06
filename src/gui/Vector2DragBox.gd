@tool
class_name Vector2DragBox
extends BoxContainer

signal value_changed(new_value: Vector2)
signal interaction_ended(value: Vector2, previous: Vector2)

@export var keep_aspect: bool
@export var rounded: bool
@export var step: float
@export var min_value: float
@export var max_value: float
@export var allow_greater: bool
@export var allow_lesser: bool
@export var prefix: String:
	set = _set_prefix
@export var suffix: String:
	set(value):
		suffix = value
		if not is_node_ready():
			return
		for input in [input_x, input_y]:
			input.suffix = value
@export var select_all_on_focus: bool
@export var editable: bool:
	set(value):
		editable = value
		if not is_node_ready():
			return
		for input in [input_x, input_y]:
			input.editable = value

var aspect_ratio: float

var _value: Vector2 = Vector2.ZERO

@onready var input_x: DragBox
@onready var input_y: DragBox


func _init() -> void:
	input_x = DragBox.new()
	input_y = DragBox.new()
	add_child(input_x)
	add_child(input_y)
	input_x.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_y.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input_x.value_changed.connect(_set_x)
	input_y.value_changed.connect(_set_y)
	input_x.interaction_ended.connect(
		func(_new_x: float, previous_x: float):
			var previous: Vector2 = _value
			previous.x = previous_x
			interaction_ended.emit(_value, previous)
	)
	input_y.interaction_ended.connect(
		func(_new_y: float, previous_y: float):
			var previous: Vector2 = _value
			previous.y = previous_y
			interaction_ended.emit(_value, previous)
	)
	input_x.line_edit.focus_neighbor_right = input_x.line_edit.get_path_to(input_y.line_edit)
	input_y.line_edit.focus_neighbor_left = input_y.line_edit.get_path_to(input_x.line_edit)
	update_internals()
	set_value_no_signal(_value)


func update_internals() -> void:
	if keep_aspect:
		aspect_ratio = get_viewport_rect().size.aspect()
	for input: DragBox in [input_x, input_y]:
		input.alignment = HORIZONTAL_ALIGNMENT_FILL
		input.min_value = min_value
		input.max_value = max_value
		input.allow_greater = allow_greater
		input.allow_lesser = allow_lesser
		input.suffix = suffix
		input.step = step
		input.rounded = rounded
		input.select_all_on_focus = select_all_on_focus
	_set_prefix(prefix)


func set_value(new_value: Vector2) -> void:
	var previous: Vector2 = _value
	set_value_no_signal(new_value)
	value_changed.emit(_value)
	interaction_ended.emit(_value, previous)


func set_value_no_signal(new_value: Vector2):
	_value = new_value
	input_x.set_value_no_signal_refresh(new_value.x)
	input_y.set_value_no_signal_refresh(new_value.y)


func _set_x(new_value: float) -> void:
	_value.x = new_value
	if keep_aspect:
		_value.y = new_value / aspect_ratio
		input_y.set_value_no_signal_refresh(_value.y)
	value_changed.emit(_value)


func _set_y(new_value: float) -> void:
	_value.y = new_value
	if keep_aspect:
		_value.x = new_value * aspect_ratio
		input_x.set_value_no_signal_refresh(_value.x)
	value_changed.emit(_value)


func get_value() -> Vector2:
	return _value


func _set_prefix(new_prefix: String) -> void:
	if not input_x or not input_y:
		return
	prefix = new_prefix
	if not new_prefix.is_empty():
		for spinbox in [input_x, input_y]:
			spinbox.prefix = new_prefix
	else:
		input_x.prefix = "x:"
		input_y.prefix = "y:"
