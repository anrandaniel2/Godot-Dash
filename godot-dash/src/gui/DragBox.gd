@tool
class_name DragBox
extends Range

signal interaction_ended(value: float, previous: float)

const EXP_EDIT_MINIMUM: float = 1E-6

@export var alignment: HorizontalAlignment:
	set(new_value):
		alignment = new_value
		line_edit.alignment = new_value
		_update_text(value)
@export var editable: bool = true:
	set(new_value):
		editable = new_value
		line_edit.editable = new_value
@export var prefix: String = "":
	set(new_value):
		if new_value.is_empty():
			line_edit.text = line_edit.text.trim_prefix(prefix + " ")
		else:
			line_edit.text = new_value + " " + line_edit.text.trim_prefix(prefix + " ")
		prefix = new_value
@export var suffix: String = "":
	set(new_value):
		if new_value.is_empty():
			line_edit.text = line_edit.text.trim_suffix(" " + suffix)
		else:
			line_edit.text = line_edit.text.trim_suffix(" " + suffix) + " " + new_value
		suffix = new_value
@export var select_all_on_focus: bool:
	set(new_value):
		select_all_on_focus = new_value
		line_edit.select_all_on_focus = new_value
@export var draw_slider: bool = false:
	set(new_value):
		draw_slider = new_value
		queue_redraw()
@export var slider_tick_count: int:
	set(new_value):
		slider_tick_count = maxi(new_value, 0)
		queue_redraw()
@export var slider_ticks_on_borders: bool:
	set(new_value):
		slider_ticks_on_borders = new_value
		queue_redraw()
@export var slider_ticks_position: Slider.TickPosition:
	set(new_value):
		slider_ticks_position = new_value
		queue_redraw()

var line_edit: LineEdit
var tick_length: int = 8
var tick_width: int = 4
var tick_color: Color = Color("b3b3b362")

var _real_value: float
var _expression: Expression
var _pressed: bool
var _hovered: bool:
	set(value):
		_hovered = value
		queue_redraw()
var _saved_cursor_position: Vector2i
var _real_cursor_position: Vector2
var _previous: float
var _line_edit_buffer: String


func _init() -> void:
	_expression = Expression.new()
	line_edit = LineEdit.new()
	line_edit.alignment = alignment
	line_edit.editable = editable
	line_edit.select_all_on_focus = select_all_on_focus
	line_edit.show_behind_parent = true
	add_child(line_edit)
	_update_text(value)
	_real_value = value
	line_edit.caret_column = len(line_edit.text)
	line_edit.set_anchors_preset(PRESET_FULL_RECT)
	line_edit.editing_toggled.connect(_on_line_edit_editing_toggled)
	line_edit.text_submitted.connect(_on_line_edit_text_submitted)
	line_edit.text_changed.connect(func(new_text: String) -> void: _line_edit_buffer = new_text)
	# The LineEdit consumes click events. We will focus it manually.
	line_edit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_default_cursor_shape = Control.CURSOR_HSIZE
	mouse_entered.connect(func(): _hovered = true)
	mouse_exited.connect(func(): _hovered = false)
	changed.connect(func(): _update_text(value))
	if has_theme_constant(&"tick_length", &"DragBox"):
		tick_length = get_theme_constant(&"tick_length", &"DragBox")
	if has_theme_constant(&"tick_width", &"DragBox"):
		tick_length = get_theme_constant(&"tick_width", &"DragBox")
	if has_theme_color(&"tick_color", &"DragBox"):
		tick_color = get_theme_color(&"tick_color", &"DragBox")


func _get_minimum_size() -> Vector2:
	return line_edit.get_minimum_size()


func _gui_input(event: InputEvent) -> void:
	line_edit.mouse_filter = Control.MOUSE_FILTER_STOP if line_edit.is_editing() else Control.MOUSE_FILTER_IGNORE
	if line_edit.is_editing():
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_pressed = event.is_pressed() and editable
		if event.is_pressed():
			_previous = value
			_real_cursor_position = DisplayServer.mouse_get_position()
			_saved_cursor_position = DisplayServer.mouse_get_position()
		elif editable:
			DisplayServer.warp_mouse(_saved_cursor_position)
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			if draw_slider:
				queue_redraw()
			if _real_cursor_position.distance_to(_saved_cursor_position) < 2.0:
				line_edit.edit()
				_on_line_edit_editing_toggled(true)
			else:
				interaction_ended.emit(value, _previous)

	if _pressed and event is InputEventMouseMotion:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_real_cursor_position += event.screen_relative
		var relative_speed: float = 1.0
		if event.is_shift_pressed:
			relative_speed *= 0.5
		if _is_exp_edit():
			relative_speed *= 0.1
		var relative: float = remap(event.screen_relative.x, 0.0, get_rect().size.x, 0.0, max_value) * relative_speed
		# `Range.value` is snapped to the nearest `step`. We use a second variable to avoid making the slider frustrating to use.
		if not _is_exp_edit():
			_real_value += relative
		else:
			_real_value = _exp_edit_clamp(_real_value) * exp(relative)
		_real_value = _clamp_value(_real_value)
		value = _real_value
		_update_text(value)

	if _pressed and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		accept_event()


func _input(event: InputEvent) -> void:
	if line_edit.is_editing() and (event.is_action_pressed(&"ui_focus_next") or event.is_action_pressed(&"ui_focus_prev") or (event is InputEventMouseButton and event.button_index == MouseButton.MOUSE_BUTTON_LEFT and not Rect2(Vector2(), line_edit.size).has_point(get_local_mouse_position()))):
		_on_line_edit_text_submitted(_line_edit_buffer)


func _draw() -> void:
	if not draw_slider:
		return
	if (value > min_value and not exp_edit) or (value > _exp_edit_clamp(0.0)):
		_draw_slider()
	_draw_ticks()


func _draw_slider() -> void:
	var slider_rect: Rect2 = get_rect()
	slider_rect.position = Vector2.ZERO
	slider_rect.size.x = (
			remap(value, min_value, max_value, 0.0, slider_rect.size.x)
			if not _is_exp_edit()
			else remap(log(value), log(_exp_edit_clamp(min_value)), log(max_value), _exp_edit_clamp(0.0), slider_rect.size.x)
	)
	slider_rect.size.x = clampf(slider_rect.size.x, 0.0, size.x)
	if has_theme_stylebox(&"slider", &"DragBox"):
		if editable:
			draw_style_box(get_theme_stylebox(&"slider_pressed" if _pressed else &"slider_hovered" if _hovered else &"slider", &"DragBox"), slider_rect)
		else:
			draw_style_box(get_theme_stylebox(&"slider", &"DragBox"), slider_rect)
	else:
		draw_style_box(get_theme_stylebox(&"fill", &"ProgressBar"), slider_rect)


func _draw_ticks() -> void:
	var points: PackedVector2Array = PackedVector2Array()
	if not slider_ticks_on_borders and slider_tick_count <= 2:
		return
	var tick_offset: float = size.x / (slider_tick_count - 1)
	for tick in range(slider_tick_count) if slider_ticks_on_borders else range(1, slider_tick_count - 1):
		var tick_position: Vector2 = Vector2.RIGHT * tick_offset * tick
		if slider_ticks_position in [Slider.TICK_POSITION_BOTTOM_RIGHT, Slider.TICK_POSITION_BOTH]:
			points.append(tick_position + Vector2.DOWN * size.y)
			points.append(tick_position + Vector2.DOWN * (size.y + tick_length))
		if slider_ticks_position in [Slider.TICK_POSITION_TOP_LEFT, Slider.TICK_POSITION_BOTH]:
			points.append(tick_position)
			points.append(tick_position + Vector2.UP * tick_length)
		if slider_ticks_position in [Slider.TICK_POSITION_CENTER]:
			points.append(tick_position)
			points.append(tick_position + Vector2.DOWN * size.y)
	draw_multiline(points, tick_color, tick_width)


func _value_changed(new_value: float) -> void:
	_update_text(new_value)


# HACK: `set_value_no_signal` can't be overriden. This doesn't achieve parity with SpinBox
# but it's all I can do.
func set_value_no_signal_refresh(new_value: float) -> void:
	set_value_no_signal(new_value)
	_real_value = new_value
	_update_text(value)


func get_line_edit() -> LineEdit:
	return line_edit


func _clamp_value(_value: float) -> float:
	if not allow_lesser:
		_value = maxf(_value, min_value)
	if not allow_greater:
		_value = minf(_value, max_value)
	return _value


func _round_value(_value: float) -> Variant: # int | float
	var new_value: Variant = snappedf(_value, step)
	if rounded or is_equal_approx(step, roundf(step)):
		new_value = int(new_value)
	else:
		new_value = float(new_value)
	return new_value


func _exp_edit_clamp(new_value: float) -> float:
	return maxf(
		new_value,
		maxf(step / 2.0, EXP_EDIT_MINIMUM) if step <= 1.0 else EXP_EDIT_MINIMUM,
	)


func _is_exp_edit() -> bool:
	return exp_edit and not allow_lesser and not allow_greater and min_value >= 0.0


func _update_text(_value: float) -> void:
	line_edit.text = str(_round_value(_clamp_value(_value)))
	if not prefix.is_empty():
		line_edit.text = prefix + " " + line_edit.text
	if not suffix.is_empty():
		line_edit.text += " " + suffix
	if draw_slider:
		queue_redraw()


func _remove_prefix_suffix() -> void:
	line_edit.text = line_edit.text.trim_prefix(prefix + " ").trim_suffix(" " + suffix)


func _on_line_edit_editing_toggled(toggled_on: bool) -> void:
	if toggled_on:
		_remove_prefix_suffix()
		if select_all_on_focus:
			line_edit.caret_column = len(line_edit.text)
			line_edit.select_all()
		mouse_default_cursor_shape = Control.CURSOR_IBEAM
	else:
		line_edit.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mouse_default_cursor_shape = Control.CURSOR_HSIZE
		_update_text(value)


func _on_line_edit_text_submitted(new_text: String) -> void:
	mouse_default_cursor_shape = Control.CURSOR_HSIZE
	line_edit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _expression.parse(new_text) != OK:
		_update_text(value)
		return
	var parse_result: Variant = _expression.execute()
	if _expression.has_execute_failed() or (parse_result is not float and parse_result is not int):
		_update_text(value)
		return
	parse_result = float(parse_result) if not _is_exp_edit() else _exp_edit_clamp(parse_result)
	var previous_value: float = value
	value = parse_result
	interaction_ended.emit(value, previous_value)
	_real_value = snappedf(parse_result, step)
	_update_text(parse_result)
