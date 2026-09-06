class_name MoveGizmo
extends Gizmo

signal position_changed(position: Vector2)

var initial_mouse_position: Vector2
var initial_global_position: Vector2
var transform_initial_global_position: Vector2
var tween: Tween
var used_axis: int = Constants.AxisBitflag.NONE
var mwheel_axis_constraint: Constants.Axis


func _ready() -> void:
	if get_viewport().get_camera_2d() is MapCamera2D and is_quick:
		get_viewport().get_camera_2d().drag = false
	state = State.ENABLED
	initial_mouse_position = get_global_mouse_position()
	initial_global_position = global_position
	Editor.shortcut_blocker = self
	get_viewport().gui_release_focus()
	tween = create_tween()
	tween.set_parallel()
	tween.tween_property(self, ^"gizmo_scale", 1.0, 0.25).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, ^"modulate:a", 1.0, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _process(_delta: float) -> void:
	if get_viewport().get_camera_2d():
		scale.x = 1 / get_viewport().get_camera_2d().zoom.x
		scale.y = 1 / get_viewport().get_camera_2d().zoom.y
		scale *= gizmo_scale
	else:
		scale = Vector2.ONE * gizmo_scale
	queue_redraw()
	if is_removing:
		return

	var horizontal_axis_hovered: bool = is_horizontal_axis_hovered()
	var vertical_axis_hovered: bool = is_vertical_axis_hovered()

	var constrained_axis: Constants.Axis = get_constrained_axis()
	if (horizontal_axis_hovered and vertical_axis_hovered) or used_axis == Constants.AxisBitflag.X | Constants.AxisBitflag.Y:
		Editor.viewport.override_cursor_shape(CursorShape.CURSOR_MOVE)
	elif horizontal_axis_hovered or used_axis == Constants.AxisBitflag.X:
		Editor.viewport.override_cursor_shape(CursorShape.CURSOR_HSPLIT)
	elif vertical_axis_hovered or used_axis == Constants.AxisBitflag.Y:
		Editor.viewport.override_cursor_shape(CursorShape.CURSOR_VSPLIT)
	else:
		Editor.viewport.remove_cursor_shape_override()

	var previous_global_position: Vector2 = global_position
	if is_quick:
		var quick_value: float = quick_gizmo_value_input.value * Constants.CELL_SIZE if quick_gizmo_value_input.has_value() else NAN
		if constrained_axis == Constants.Axis.X:
			used_axis = Constants.AxisBitflag.X
			global_position.y = initial_global_position.y
			global_position.x = initial_global_position.x + (quick_value if is_finite(quick_value) else get_global_mouse_position().x - initial_mouse_position.x)
			quick_gizmo_value_input.original_value = (get_global_mouse_position().x - initial_mouse_position.x) / Constants.CELL_SIZE
			if is_snapping():
				quick_gizmo_value_input.original_value = roundf(quick_gizmo_value_input.original_value)
		elif constrained_axis == Constants.Axis.Y:
			used_axis = Constants.AxisBitflag.Y
			global_position.x = initial_global_position.x
			global_position.y = initial_global_position.y + (-quick_value if is_finite(quick_value) else get_global_mouse_position().y - initial_mouse_position.y)
			quick_gizmo_value_input.original_value = (get_global_mouse_position().y - initial_mouse_position.y) / Constants.CELL_SIZE
			if is_snapping():
				quick_gizmo_value_input.original_value = roundf(quick_gizmo_value_input.original_value)
		else:
			used_axis = Constants.AxisBitflag.X | Constants.AxisBitflag.Y
			global_position = initial_global_position + get_global_mouse_position() - initial_mouse_position
			# HACK: display a Vector2 in the keychord display (QuickGizmoValueInput can only handle floats)
			if not quick_gizmo_value_input.has_value():
				var action: String = quick_gizmo_value_input.displayed_gizmo_action
				var unit: String = quick_gizmo_value_input.displayed_gizmo_unit
				var displacement: Vector2 = (get_global_mouse_position() - initial_mouse_position) / Constants.CELLS_TO_PX
				if is_snapping():
					displacement = displacement.round()
				quick_gizmo_value_input.keychord_display.text = "%s: (%.2f%s, %.2f%s)" % [action, displacement.x, unit, displacement.y, unit]
	else:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and used_axis == Constants.AxisBitflag.NONE:
			if horizontal_axis_hovered:
				used_axis |= Constants.AxisBitflag.X
			if vertical_axis_hovered:
				used_axis |= Constants.AxisBitflag.Y
			initial_mouse_position = get_global_mouse_position()
			transform_initial_global_position = global_position

		if used_axis & Constants.AxisBitflag.X:
			global_position.x = transform_initial_global_position.x + get_global_mouse_position().x - initial_mouse_position.x
		if used_axis & Constants.AxisBitflag.Y:
			global_position.y = transform_initial_global_position.y + get_global_mouse_position().y - initial_mouse_position.y

	var is_gizmo_in_use: bool = used_axis != Constants.AxisBitflag.NONE
	if is_snapping() and is_gizmo_in_use:
		if used_axis & Constants.AxisBitflag.X:
			global_position.x = snappedf(global_position.x - initial_global_position.x, Constants.CELL_SIZE) + initial_global_position.x
		if used_axis & Constants.AxisBitflag.Y:
			global_position.y = snappedf(global_position.y - initial_global_position.y, Constants.CELL_SIZE) + initial_global_position.y

	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		used_axis = Constants.AxisBitflag.NONE

	position_changed.emit((global_position - previous_global_position) / Constants.CELL_SIZE)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.is_pressed() and event.button_index == MOUSE_BUTTON_LEFT and not any_handle_hovered():
		remove_gizmo()


func _draw() -> void:
	draw_gizmo(Color.BLACK, true)
	draw_gizmo(Color.WHITE)


func draw_gizmo(color: Color, outline: bool = false) -> void:
	if outline:
		color.a /= 2
	var horizontal_axis_color: Color = color
	if is_horizontal_axis_hovered() or used_axis & Constants.AxisBitflag.X:
		horizontal_axis_color.a /= 2
	var vertical_axis_color: Color = color
	if is_vertical_axis_hovered() or used_axis & Constants.AxisBitflag.Y:
		vertical_axis_color.a /= 2
	var length: int = 102 if outline else 100
	var width: int = 5 if outline else 1

	if is_quick:
		var constrained_axis: Constants.Axis = get_constrained_axis()
		if constrained_axis == Constants.Axis.X:
			horizontal_axis_color.a /= 2
			draw_line(Vector2(2000, 0), Vector2(-2000, 0), Color.RED if not outline else horizontal_axis_color, width, true)
		elif constrained_axis == Constants.Axis.Y:
			vertical_axis_color.a /= 2
			draw_line(Vector2(0, 2000), Vector2(0, -2000), Color.GREEN if not outline else vertical_axis_color, width, true)

	draw_line(Vector2(length, 0), Vector2(-length, 0), horizontal_axis_color, width, true)
	draw_line(Vector2(0, length), Vector2(0, -length), vertical_axis_color, width, true)

	if outline:
		draw_circle(Vector2.ZERO, HANDLE_RADIUS, color, false, 6.0)
	else:
		draw_circle(Vector2.ZERO, HANDLE_RADIUS, color, true)

	for direction in [0, 90, 180, 270]:
		var points: PackedVector2Array = [
			Vector2(92, -10) + (Vector2.ZERO if not outline else Vector2.ONE * -sqrt(2)),
			Vector2(102, 0),
			Vector2(92, 10) + (Vector2.ZERO if not outline else Vector2(1, -1) * -sqrt(2)),
		].map(func(point: Vector2): return point.rotated(deg_to_rad(direction)))
		if direction % 180 == 0:
			draw_polyline(points, horizontal_axis_color, width, true)
		else:
			draw_polyline(points, vertical_axis_color, width, true)


func remove_gizmo(reset: bool = false) -> void:
	if is_removing:
		return
	if get_viewport().get_camera_2d() is MapCamera2D:
		get_viewport().get_camera_2d().drag = true
	is_removing = true
	state = State.DISABLED
	used_axis = Constants.AxisBitflag.NONE
	Editor.viewport.remove_cursor_shape_override()
	tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	tween.set_parallel()
	var do_reset_position := func(_position: Vector2):
		var position_delta: Vector2 = _position - global_position
		global_position += position_delta
		position_changed.emit(position_delta / Constants.CELL_SIZE)
	tween.tween_property(self, ^"gizmo_scale", 0.0, 0.25).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	tween.tween_property(self, ^"modulate:a", 0.0, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	if reset:
		tween.tween_method(do_reset_position, global_position, initial_global_position, 0.5).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	else:
		var distance_from_start: Vector2 = initial_global_position - global_position
		position_changed.emit(distance_from_start / Constants.CELL_SIZE)
		confirmed.emit(-distance_from_start / Constants.CELL_SIZE)
	if quick_gizmo_value_input:
		quick_gizmo_value_input.keychord_display.text = ""
	await tween.finished
	queue_free()


func is_enabled() -> bool:
	return state != State.DISABLED


func is_horizontal_axis_hovered() -> bool:
	var horizontal_axis_rect: Rect2 = Rect2(global_position - Vector2(125, 12.5) / get_viewport().get_camera_2d().zoom, Vector2(250, 25) / get_viewport().get_camera_2d().zoom)
	return horizontal_axis_rect.has_point(get_global_mouse_position()) and not is_quick


func is_vertical_axis_hovered() -> bool:
	var vertical_axis_rect: Rect2 = Rect2(global_position - Vector2(12.5, 125) / get_viewport().get_camera_2d().zoom, Vector2(25, 250) / get_viewport().get_camera_2d().zoom)
	return vertical_axis_rect.has_point(get_global_mouse_position()) and not is_quick


func any_handle_hovered() -> bool:
	return is_horizontal_axis_hovered() or is_vertical_axis_hovered()


func is_snapping() -> bool:
	return Input.is_key_pressed(KEY_CTRL)


func get_constrained_axis() -> Constants.Axis:
	const AxisConstraint = QuickGizmoValueInput.AxisConstraint
	var abs_distance_from_start: Vector2 = abs(transform_initial_global_position + get_global_mouse_position() - initial_mouse_position)
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
		mwheel_axis_constraint = Constants.Axis.BOTH
	elif abs_distance_from_start.x > abs_distance_from_start.y:
		mwheel_axis_constraint = Constants.Axis.X
	else:
		mwheel_axis_constraint = Constants.Axis.Y
	if not quick_gizmo_value_input or quick_gizmo_value_input.axis_constraint == AxisConstraint.NONE:
		return mwheel_axis_constraint
	else:
		match quick_gizmo_value_input.axis_constraint:
			AxisConstraint.GLOBAL_X, AxisConstraint.LOCAL_X:
				return Constants.Axis.X
			AxisConstraint.GLOBAL_Y, AxisConstraint.LOCAL_Y:
				return Constants.Axis.Y
			_:
				return Constants.Axis.BOTH


func _quick() -> void:
	pass
