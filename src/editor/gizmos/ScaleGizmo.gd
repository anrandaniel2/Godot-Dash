class_name ScaleGizmo
extends Gizmo

signal scale_changed(transform: Transform2D, rotation: float, is_global_axis: bool)

const AxisConstraint = QuickGizmoValueInput.AxisConstraint

var handles: Array[Handle] = [
	# Resize handles
	Handle.new(Vector2(-1.0, -1.0), Handle.Type.CORNER, 0),
	Handle.new(Vector2(0.0, -1.0), Handle.Type.HORIZONTAL_EDGE),
	Handle.new(Vector2(1.0, -1.0), Handle.Type.CORNER, 1),
	Handle.new(Vector2(-1.0, 0.0), Handle.Type.VERTICAL_EDGE),
	Handle.new(Vector2(1.0, 0.0), Handle.Type.VERTICAL_EDGE),
	Handle.new(Vector2(-1.0, 1.0), Handle.Type.CORNER, 3),
	Handle.new(Vector2(0.0, 1.0), Handle.Type.HORIZONTAL_EDGE),
	Handle.new(Vector2(1.0, 1.0), Handle.Type.CORNER, 2),
]
var hovered_handle: Handle
var has_hovered_handle: bool
var handle_center_mouse_offset: Vector2
var transform: Transform2D
var real_transform: Transform2D
var previous_transform: Transform2D
var initial_transform: Transform2D
var bounding_box: Transform2D
var snapped_origin: Vector2
var previous_mouse_position: Vector2
var tween: Tween
var displayed_transform: Transform2D
var displayed_handle_radius: float
var canvas_item: RID


class Handle:
	enum Type {
		CORNER,
		VERTICAL_EDGE,
		HORIZONTAL_EDGE,
	}

	var axis: Vector2
	var type: Type
	var corner_idx: int
	var origin: Vector2


	func _init(_axis: Vector2, _type: Type, _corner_idx: int = -1) -> void:
		axis = _axis
		type = _type

		if _type == Type.CORNER:
			assert(_corner_idx >= 0, "Corner Index must be defined when initializing corner handle")
			corner_idx = _corner_idx


	func displayed_position(transform: Transform2D, global: bool = false) -> Vector2:
		if global:
			return axis * transform.translated(-origin) * Transform2D.FLIP_X + origin
		else:
			return transform * axis


func _init(_bounding_box: Transform2D, _position: Vector2, _rotation: float) -> void:
	bounding_box = _bounding_box
	transform = Transform2D.IDENTITY.rotated(_rotation).translated(_position)
	initial_transform = transform
	real_transform = transform
	displayed_transform = transform * bounding_box
	canvas_item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(canvas_item, get_canvas_item())


func _exit_tree() -> void:
	RenderingServer.free_rid(canvas_item)


func _ready() -> void:
	Editor.shortcut_blocker = self
	get_viewport().gui_release_focus()
	tween = create_tween()
	tween.set_parallel()
	tween.tween_property(self, ^"gizmo_scale", 1.0, 0.25).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, ^"modulate:a", 1.0, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_method(func(_weight): queue_redraw(), 0.0, 1.0, 0.25)
	previous_mouse_position = get_gizmo_local_mouse_position()
	handles.map(func(handle: Handle): handle.origin = initial_transform.get_origin())


func _input(event: InputEvent) -> void:
	if is_zero_approx(gizmo_scale):
		return

	# Handle focus
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if has_hovered_handle and event.pressed and state == State.DISABLED:
			state = State.ENABLED
			handle_center_mouse_offset = hovered_handle.axis - get_local_mouse_position()
			previous_mouse_position = get_local_mouse_position() / gizmo_scale
		if not event.pressed and state == State.ENABLED:
			state = State.DISABLED
	elif event is InputEventMouseMotion:
		if state == State.DISABLED:
			for handle in handles:
				if handle.displayed_position(displayed_transform).distance_to(get_local_mouse_position()) < displayed_handle_radius:
					hovered_handle = handle
					has_hovered_handle = true
					break
				else:
					has_hovered_handle = false
		else:
			previous_transform = transform
			resize(event)
			accept_event()

	previous_mouse_position = get_gizmo_local_mouse_position()
	set_cursor_shape(hovered_handle if has_hovered_handle else null)


func _process(_delta: float) -> void:
	RenderingServer.canvas_item_clear(canvas_item)
	# Update displayed_handle_radius
	if get_viewport().get_camera_2d():
		displayed_handle_radius = 1 / get_viewport().get_camera_2d().zoom.length() * HANDLE_RADIUS
	else:
		displayed_handle_radius = HANDLE_RADIUS
	var outline_color := Color.BLACK
	outline_color.a = 0.5
	draw_gizmo(outline_color, true)
	draw_gizmo(Color.WHITE)
	if quick_gizmo_value_input:
		var draw_transform: Transform2D = Transform2D.IDENTITY.translated(displayed_transform.get_origin())
		if not quick_gizmo_value_input.is_global_axis():
			draw_transform = draw_transform.rotated_local(initial_transform.get_rotation())
		RenderingServer.canvas_item_add_set_transform(canvas_item, draw_transform)
		var zoom_ratio: float = displayed_handle_radius / HANDLE_RADIUS
		match quick_gizmo_value_input.axis_constraint:
			AxisConstraint.GLOBAL_X, AxisConstraint.LOCAL_X:
				RenderingServer.canvas_item_add_line(canvas_item, Vector2.LEFT * 2048.0 * zoom_ratio, Vector2.RIGHT * 2048.0 * zoom_ratio, outline_color, zoom_ratio * 8.0)
				RenderingServer.canvas_item_add_line(canvas_item, Vector2.LEFT * 2048.0 * zoom_ratio, Vector2.RIGHT * 2048.0 * zoom_ratio, Color.RED, zoom_ratio * 2.0)
			AxisConstraint.GLOBAL_Y, AxisConstraint.LOCAL_Y:
				RenderingServer.canvas_item_add_line(canvas_item, Vector2.UP * 2048.0 * zoom_ratio, Vector2.DOWN * 2048.0 * zoom_ratio, outline_color, zoom_ratio * 8.0)
				RenderingServer.canvas_item_add_line(canvas_item, Vector2.UP * 2048.0 * zoom_ratio, Vector2.DOWN * 2048.0 * zoom_ratio, Color.GREEN, zoom_ratio * 2.0)


func _quick() -> void:
	quick_gizmo_value_input.value_changed.connect(_on_quick_scale_changed)
	quick_gizmo_value_input.axis_constraint_changed.connect(quick_set_selected_handle)
	quick_gizmo_value_input.original_value = 1.0
	quick_set_selected_handle.call_deferred(QuickGizmoValueInput.AxisConstraint.NONE)


func resize(event: InputEventMouseMotion) -> void:
	# Modifiers
	var resizing_keep_aspect: bool = event.shift_pressed or is_quick
	var resizing_around_center: bool = event.alt_pressed or is_quick
	var resizing_snapped: bool = event.ctrl_pressed

	var focused_handle: Handle = hovered_handle
	var mouse_position_delta: Vector2 = event.relative
	if get_viewport().get_camera_2d():
		mouse_position_delta /= get_viewport().get_camera_2d().zoom
	# When we're not resizing around the center, we move the center of the gizmo to the mean position
	# between the opposite edge and the cursor, and resize by half the amount.
	var resize_and_move: bool = not resizing_around_center
	var resize_and_move_multiplier: float = 0.5 if resize_and_move else 1.0
	if resizing_keep_aspect:
		mouse_position_delta = mouse_position_delta.project(focused_handle.displayed_position(displayed_transform.translated(-displayed_transform.origin)))
	var scale_multiplier: Vector2 = (
			Vector2.ONE
			+ displayed_transform.affine_inverse().basis_xform(mouse_position_delta)
			* focused_handle.axis # Constrains the angle perpendicular to the side
			* resize_and_move_multiplier
	)
	var transform_rotation: float = transform.get_rotation()
	var is_edge_handle: bool = focused_handle.type == Handle.Type.VERTICAL_EDGE or focused_handle.type == Handle.Type.HORIZONTAL_EDGE
	if resizing_keep_aspect and is_edge_handle:
		if scale_multiplier.x == 1.0:
			scale_multiplier.x = absf(scale_multiplier.y)
		elif scale_multiplier.y == 1.0:
			scale_multiplier.y = absf(scale_multiplier.x)

	if not has_quick_value():
		transform = transform.scaled_local(scale_multiplier)
		if is_quick:
			quick_gizmo_value_input.original_value *= scale_multiplier.x
			quick_gizmo_value_input.is_snapped = resizing_snapped
			match quick_gizmo_value_input.get_axis_constraint():
				AxisConstraint.NONE:
					transform = initial_transform.scaled_local(Vector2.ONE * quick_gizmo_value_input.original_value)
				AxisConstraint.GLOBAL_X, AxisConstraint.LOCAL_X:
					transform.y = transform.y.normalized()
				AxisConstraint.GLOBAL_Y, AxisConstraint.LOCAL_Y:
					transform.x = transform.x.normalized()

	if resize_and_move:
		match focused_handle.type:
			Handle.Type.CORNER:
				transform.origin += (mouse_position_delta.rotated(-transform_rotation) * resize_and_move_multiplier).rotated(transform_rotation)
			Handle.Type.VERTICAL_EDGE:
				transform.origin += (mouse_position_delta.rotated(-transform_rotation) * resize_and_move_multiplier * Vector2.RIGHT).rotated(transform_rotation)
			Handle.Type.HORIZONTAL_EDGE:
				transform.origin += (mouse_position_delta.rotated(-transform_rotation) * resize_and_move_multiplier * Vector2.DOWN).rotated(transform_rotation)

	var quick_and_global: bool = false if not is_quick else quick_gizmo_value_input.is_global_axis()

	if resizing_snapped:
		var previous_snapped_transform: Transform2D = (displayed_transform * bounding_box.affine_inverse())
		var snapped_transform: Transform2D = transform
		snapped_transform = snapped_transform.rotated(-transform_rotation)
		snapped_transform.x = snapped_transform.x.normalized() * maxf(snappedf(snapped_transform.x.length(), 0.5), 0.5)
		snapped_transform.y = snapped_transform.y.normalized() * maxf(snappedf(snapped_transform.y.length(), 0.5), 0.5)
		if resize_and_move:
			snapped_origin += (
					(snapped_transform.basis_xform(bounding_box.get_scale()) - previous_snapped_transform.rotated(-transform_rotation).basis_xform(bounding_box.get_scale()))
					* focused_handle.axis
			).rotated(transform_rotation)
		snapped_transform = snapped_transform.rotated(transform_rotation)
		snapped_transform.origin = initial_transform.origin + snapped_origin
		transform.origin = snapped_transform.origin
		displayed_transform = snapped_transform * bounding_box
		previous_transform = previous_snapped_transform
		scale_changed.emit(
			previous_snapped_transform.affine_inverse() * snapped_transform,
			initial_transform.get_rotation(),
			quick_and_global,
		)
	else:
		displayed_transform = transform * bounding_box
		scale_changed.emit(
			previous_transform.affine_inverse() * transform,
			initial_transform.get_rotation(),
			quick_and_global,
		)


func quick_set_selected_handle(axis_constraint: AxisConstraint) -> void:
	var local_mouse_position_normalized: Vector2 = (initial_transform.affine_inverse() * get_local_mouse_position()).normalized()
	var matches_axis := func(handle: Handle) -> bool:
		match axis_constraint:
			AxisConstraint.NONE:
				return true
			AxisConstraint.GLOBAL_X, AxisConstraint.LOCAL_X:
				return absf(handle.axis.rotated(initial_transform.get_rotation()).normalized().dot(Vector2.RIGHT)) > 0.9
			AxisConstraint.GLOBAL_Y, AxisConstraint.LOCAL_Y:
				return absf(handle.axis.rotated(initial_transform.get_rotation()).dot(Vector2.DOWN)) > 0.9
			AxisConstraint.DISABLED:
				return false
		return false

	# Measures similarity between the mouse local direction and the handle axis.
	var max_cosine: float
	var max_cosine_handle: Handle
	for handle in handles.filter(matches_axis):
		if handle.axis.normalized().dot(local_mouse_position_normalized) > max_cosine:
			max_cosine = handle.axis.normalized().dot(local_mouse_position_normalized)
			max_cosine_handle = handle
	hovered_handle = max_cosine_handle


func draw_gizmo(color: Color, outline: bool = false) -> void:
	var quick_and_global: bool = false if not is_quick else quick_gizmo_value_input.is_global_axis()
	var scaled_displayed_transform: Transform2D = displayed_transform.scaled_local(Vector2.ONE * gizmo_scale)

	var corner_handles: Array = handles.filter(func(handle: Handle): return handle.type == Handle.Type.CORNER)
	corner_handles.sort_custom(func(handle_a: Handle, handle_b: Handle): return handle_a.corner_idx < handle_b.corner_idx)
	corner_handles.append(corner_handles[0])
	var color_array: PackedColorArray = PackedColorArray()
	for i in corner_handles.size():
		color_array.append(color)
	RenderingServer.canvas_item_add_polyline(
		canvas_item,
		corner_handles.map(func(handle: Handle): return handle.displayed_position(scaled_displayed_transform, quick_and_global)),
		color_array,
		(displayed_handle_radius * 8.0) / HANDLE_RADIUS if outline else (displayed_handle_radius * 2.0) / HANDLE_RADIUS,
	)

	for handle in handles:
		var handle_color: Color = color
		if handle == hovered_handle:
			if has_hovered_handle:
				handle_color.a /= 2.0
			if state == State.ENABLED:
				handle_color.a /= 2.0
		if outline:
			RenderingServer.canvas_item_add_circle(
				canvas_item,
				handle.displayed_position(scaled_displayed_transform, quick_and_global),
				displayed_handle_radius * 1.5,
				handle_color,
				false,
			)
		else:
			RenderingServer.canvas_item_add_circle(
				canvas_item,
				handle.displayed_position(scaled_displayed_transform, quick_and_global),
				displayed_handle_radius,
				handle_color,
				false,
			)


func remove_gizmo(reset: bool = false) -> void:
	is_removing = true
	Editor.viewport.remove_cursor_shape_override()
	state = State.DISABLED
	has_hovered_handle = false
	tween = create_tween()
	tween.set_parallel()
	tween.tween_property(self, ^"gizmo_scale", 0.0, 0.25).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_IN)
	tween.tween_property(self, ^"modulate:a", 0.0, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	var quick_and_global: bool = is_quick and quick_gizmo_value_input.is_global_axis()
	var do_reset_scale := func(weight: float, start_transform: Transform2D):
		previous_transform = transform
		transform.x = start_transform.x.lerp(initial_transform.x, weight)
		transform.y = start_transform.y.lerp(initial_transform.y, weight)
		transform.origin = start_transform.origin.lerp(initial_transform.origin, weight)
		displayed_transform = transform * bounding_box
		scale_changed.emit(
			previous_transform.affine_inverse() * transform,
			initial_transform.get_rotation(),
			quick_and_global,
		)
	transform = displayed_transform * bounding_box.affine_inverse()
	if reset:
		tween.tween_method(do_reset_scale.bind(transform), 0.0, 1.0, 0.5).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	else:
		confirmed.emit(
			initial_transform.affine_inverse() * transform,
			initial_transform.get_rotation(),
			quick_and_global,
		)
	if quick_gizmo_value_input:
		quick_gizmo_value_input.keychord_display.text = ""
	await tween.finished
	if Editor.shortcut_blocker == self:
		Editor.shortcut_blocker = null
	queue_free()


func set_cursor_shape(active_handle: Handle) -> void:
	if not active_handle:
		mouse_default_cursor_shape = Control.CURSOR_ARROW
		Editor.viewport.remove_cursor_shape_override()
		return
	const AXES: PackedVector2Array = [
		Vector2.LEFT,
		Vector2.RIGHT,
		Vector2.UP,
		Vector2.DOWN,
		Vector2.UP + Vector2.LEFT,
		Vector2.DOWN + Vector2.LEFT,
		Vector2.UP + Vector2.RIGHT,
		Vector2.DOWN + Vector2.RIGHT,
	]
	var axis_to_dot: Dictionary[Vector2, float]
	var handle_axis: Vector2 = active_handle.axis.rotated(initial_transform.get_rotation()).normalized()
	for axis: Vector2 in AXES:
		axis_to_dot[axis] = absf(axis.normalized().dot(handle_axis) - 1.0)
	var closest_axis_dot: float = axis_to_dot.values().min()
	var closest_axis: Vector2 = axis_to_dot.find_key(closest_axis_dot)
	match closest_axis:
		Vector2.LEFT, Vector2.RIGHT:
			Editor.viewport.override_cursor_shape(Control.CURSOR_HSIZE)
		Vector2.UP, Vector2.DOWN:
			Editor.viewport.override_cursor_shape(Control.CURSOR_VSIZE)
		(Vector2.UP + Vector2.LEFT), (Vector2.DOWN + Vector2.RIGHT):
			Editor.viewport.override_cursor_shape(Control.CURSOR_FDIAGSIZE)
		(Vector2.UP + Vector2.RIGHT), (Vector2.DOWN + Vector2.LEFT):
			Editor.viewport.override_cursor_shape(Control.CURSOR_BDIAGSIZE)


func is_enabled() -> bool:
	return state != State.DISABLED


func any_handle_hovered() -> bool:
	return has_hovered_handle


func _on_quick_scale_changed(quick_scale: float) -> void:
	var quick_and_global: bool = false if not is_quick else quick_gizmo_value_input.is_global_axis()
	previous_transform = transform
	match quick_gizmo_value_input.axis_constraint:
		AxisConstraint.NONE:
			transform.x = transform.x.normalized() * quick_scale
			transform.y = transform.y.normalized() * quick_scale
		AxisConstraint.GLOBAL_X, AxisConstraint.LOCAL_X:
			transform.x = transform.x.normalized() * quick_scale
			transform.y = transform.y.normalized()
		AxisConstraint.GLOBAL_Y, AxisConstraint.LOCAL_Y:
			transform.x = transform.x.normalized()
			transform.y = transform.y.normalized() * quick_scale
	if quick_scale == quick_gizmo_value_input.original_value:
		transform.x = transform.x.normalized() * quick_scale
		transform.y = transform.y.normalized() * quick_scale

	displayed_transform = transform * bounding_box
	scale_changed.emit(
		previous_transform.affine_inverse() * transform,
		initial_transform.get_rotation(),
		quick_and_global,
	)
