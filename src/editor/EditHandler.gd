class_name EditHandler
extends Node

signal selection_zone_changed(new_zone: Rect2)
signal selection_changed(selection: Selection)
signal selection_changed_viewport
signal clipboard_changed(clipboard: Selection)
signal rotated_object_degrees(rotation_degrees: float)
signal deleted_selection
# Selection transform
signal moved_selection_cells(distance: Vector2)
signal rotated_selection_degrees(angle_degrees: float)
signal resized_selection(new_scale: Vector2)

enum TransformPivot {
	MEDIAN_POINT,
	INDIVIDUAL_ORIGINS,
}

enum TransformHistory {
	APPLY,
	APPLY_SILENT,
	FINISH,
}

const THROTTLE_MOVE_COOLDOWN: float = 0.2
const THROTTLE_ROTATE_COOLDOWN: float = 0.2

@export var gizmo_layer: CanvasLayer
@export var keychord_display: Label
@export var transform_pivot_button: OptionButton

var level: Level
var clipboard_camera_position: Vector2
var throttle_move_seconds: float = 0.0
var throttle_rotate_seconds: float = 0.0
var placed_objects_collider: Area2D
var editor_modes: TabContainer
var selection_index: int = 0
var cursor_position_snapped: Vector2
var previous_cursor_position_snapped: Vector2
var selection_pivot: Vector2
var selection_pivot_with_player: Vector2
var gizmo: Gizmo

@onready var selection := Selection.new()


func _ready() -> void:
	_reset_selection_zone(true)
	var update_global_clipboard := func(new_clipboard): Editor.clipboard = new_clipboard
	clipboard_changed.connect(update_global_clipboard)


func _physics_process(delta: float) -> void:
	if not level or LevelManager.level_playing or Editor.root.just_stopped_playtest:
		return
	if throttle_move_seconds > 0:
		throttle_move_seconds -= delta
	if throttle_rotate_seconds > 0:
		throttle_rotate_seconds -= delta
	cursor_position_snapped = level.get_local_mouse_position().snapped(Vector2.ONE * 128)
	if cursor_position_snapped != previous_cursor_position_snapped:
		selection_index = 0
	var is_already_swiping_selection: bool = $SelectionZone/Hitbox.shape.size != Vector2.ZERO
	if Input.is_action_just_pressed(&"editor_select_all", true) and not Editor.is_text_input_focused():
		select_all()

	if (
			Input.is_action_just_pressed(&"editor_delete", true)
			and Editor.root.inspector_tree.is_layer_selected_exclusive()
	):
		level.remove_layer(level.layers[level.active_layer_idx].name)

	var gizmo_in_use: bool = gizmo and (gizmo.is_enabled() or gizmo.any_handle_hovered())
	if is_already_swiping_selection or get_viewport().gui_get_hovered_control() == Editor.viewport:
		if Editor.is_picking_node:
			_update_interactive_picking()
		elif (
				editor_modes.current_tab == Editor.EditorMode.EDIT
				and not gizmo_in_use
				and not (Config.is_touch_screen and any_gizmo_is_open())
		):
			_update_selection()
		_handle_input()
		if not (
				Input.get_vector(&"editor_move_left", &"editor_move_right", &"editor_move_up", &"editor_move_down")
				or Input.get_axis(&"editor_rotate_-45", &"editor_rotate_45")
				or Input.get_axis(&"editor_rotate_-90", &"editor_rotate_90")
		):
			throttle_rotate_seconds = 0.0
	previous_cursor_position_snapped = cursor_position_snapped


func move_selection(distance_cells: Vector2, version_history: bool = true) -> void:
	var move_object := func(_selection: Selection):
		for _object: Node2D in _selection.to_array():
			_object.global_position += distance_cells * Constants.CELL_SIZE
			selection_pivot += distance_cells * Constants.CELL_SIZE
		moved_selection_cells.emit(distance_cells)
	var unmove_object := func(_selection: Selection):
		for _object: Node2D in _selection.to_array():
			_object.global_position -= distance_cells * Constants.CELL_SIZE
		selection_pivot -= distance_cells * Constants.CELL_SIZE
		moved_selection_cells.emit(-distance_cells)
	if not version_history:
		move_object.call(selection)
		return
	var selection_snapshot: Selection = selection.clone()
	Editor.version_history.create_action("Moved objects %s units" % distance_cells)
	Editor.version_history.add_do_method(move_object.bind(selection_snapshot))
	Editor.version_history.add_undo_method(unmove_object.bind(selection_snapshot))
	Editor.version_history.commit_action()


func rotate_selection(angle: float, is_gizmo: bool = false) -> void:
	if selection.is_empty() or (selection.size() == 1 and selection.first() is Player):
		return
	var do_rotate_selection := func(_selection: Selection):
		for _object in _selection.to_array():
			if _object is Player:
				continue
			_object.global_rotation_degrees += angle
		rotated_selection_degrees.emit(angle)
		if _selection.size() == 1 and not is_gizmo:
			rotated_object_degrees.emit(angle)
	var undo_rotate_selection := func(_selection: Selection):
		for _object in _selection.to_array():
			if _object is Player:
				continue
			_object.global_rotation_degrees -= angle
		rotated_selection_degrees.emit(-angle)
		if _selection.size() == 1 and not is_gizmo:
			rotated_object_degrees.emit(-angle)
	var do_pivot := func(_selection: Selection, _selection_pivot: Vector2):
		for _object in _selection.to_array():
			if _object is Player:
				continue
			var position_relative_to_pivot: Vector2 = _object.global_position - _selection_pivot
			var position_delta := position_relative_to_pivot.rotated(deg_to_rad(angle)) - position_relative_to_pivot
			_object.global_position += position_delta
	var undo_pivot := func(_selection_original_positions: Dictionary[Node2D, Vector2]):
		for _object: Node2D in _selection_original_positions:
			if _object is Player:
				continue
			_object.global_position = _selection_original_positions[_object]

	var selection_snapshot: Selection = selection.clone()
	# Avoid firing signals for RotateGizmo rotations
	# RotateGizmo fires a signal every frame its angle changes
	# This would clog the history with small rotations.
	if is_gizmo:
		do_rotate_selection.call(selection_snapshot)
		if transform_pivot_button.selected != TransformPivot.INDIVIDUAL_ORIGINS:
			do_pivot.call(selection_snapshot, selection_pivot)
		return

	Editor.version_history.create_action("Rotated objects %s°" % angle)
	Editor.version_history.add_do_method(do_rotate_selection.bind(selection_snapshot))
	Editor.version_history.add_undo_method(undo_rotate_selection.bind(selection_snapshot))
	if transform_pivot_button.selected != TransformPivot.INDIVIDUAL_ORIGINS:
		var object_to_position := func(accum: Dictionary, object: Node2D):
			accum[object] = object.global_position
			return accum
		var object_positions: Dictionary[Node2D, Vector2]
		object_positions.assign(selection_snapshot.fold_generic(object_to_position, { }))
		Editor.version_history.add_do_method(do_pivot.bind(selection_snapshot, selection_pivot))
		Editor.version_history.add_undo_method(undo_pivot.bind(object_positions))
	Editor.version_history.commit_action()


func scale_selection(
		transform: Transform2D,
		initial_rotation: float,
		is_global: bool,
		register_history: TransformHistory,
) -> void:
	if selection.is_empty() or (selection.size() == 1 and selection.first() is Player):
		return
	if register_history == TransformHistory.FINISH:
		var do_scale: Callable
		var undo_scale: Callable
		if is_global:
			do_scale = func():
				selection.for_each(scale_transform.bind(transform))
				resized_selection.emit(transform.get_scale())
			undo_scale = func():
				selection.for_each(scale_transform.bind(transform.affine_inverse()))
				resized_selection.emit(transform.affine_inverse().get_scale())
		else:
			do_scale = func():
				selection.for_each(scale_transform_local.bind(transform, initial_rotation))
				resized_selection.emit(transform.get_scale())
			undo_scale = func():
				selection.for_each(scale_transform_local.bind(transform.affine_inverse(), initial_rotation))
				resized_selection.emit(transform.affine_inverse().get_scale())
		Editor.version_history.create_action("Scaled selection by %s %s" % [transform.get_scale(), "globally" if is_global else "locally"])
		Editor.version_history.add_do_method(do_scale)
		Editor.version_history.add_undo_method(undo_scale)
		Editor.version_history.commit_action()
		update_pivot()
		return
	if is_global:
		selection.for_each(scale_transform.bind(transform))
	else:
		selection.for_each(scale_transform_local.bind(transform, initial_rotation))
	if register_history == TransformHistory.APPLY:
		resized_selection.emit(transform.get_scale())


func duplicate_selection() -> void:
	if selection.is_empty() or (selection.size() == 1 and selection.first() is Player):
		return

	var do_duplicate_selection := func(_selection: Selection):
		_selection.for_each(
			func(object: Node2D):
				if object.is_inside_tree() or object is Player:
					return
				var layer: Layer = object.get_meta(Constants.LAYER_META)
				layer.add_child(object, true)
				NodeUtils.change_owner_recursive(object, level)
		)

	var undo_duplicate_selection := func(_selection: Selection):
		_selection.for_each(
			func(object: Node2D):
				if object is Player:
					return
				object.get_parent().remove_child(object)
		)

	var new_selection: Selection = selection.map(_clone_object)
	var new_selection_size: int = new_selection.size()
	if new_selection.contains(LevelManager.player):
		new_selection_size -= 1

	Editor.version_history.create_action("Duplicated %s objects" % new_selection_size)
	Editor.version_history.add_do_method(do_duplicate_selection.bind(new_selection))
	Editor.version_history.add_undo_method(undo_duplicate_selection.bind(new_selection))
	Editor.version_history.commit_action()
	select(new_selection, true, true)


func copy_selection() -> void:
	var clipboard: Selection = Editor.clipboard
	clipboard.clear()
	clipboard = selection.clone()
	clipboard_camera_position = get_viewport().get_camera_2d().get_screen_center_position()
	clipboard_changed.emit(clipboard)
	var clipboard_size: int = clipboard.size()
	if clipboard.contains(LevelManager.player):
		clipboard_size -= 1
	var plural: String = "" if clipboard_size <= 1 else "s"
	Toasts.new_toast("%s object%s copied!" % [clipboard_size, plural])


func paste_selection() -> void:
	var clipboard: Selection = Editor.clipboard
	if clipboard.is_empty() or (clipboard.size() == 1 and clipboard.first() is Player):
		return

	var do_duplicate_selection := func(_selection: Selection):
		_selection.for_each(
			func(_object: Node2D):
				var layer: Layer = _object.get_meta(Constants.LAYER_META)
				if not layer:
					return
				layer.add_child(_object, true)
				NodeUtils.change_owner_recursive(_object, level)
		)

	var undo_duplicate_selection := func(_selection: Selection):
		_selection.for_each(
			func(_object: Node2D):
				if _object is Player:
					return
				_object.get_parent().remove_child(_object)
		)

	var move_objects_to_new_screen_center = func(object: Node2D):
		if object is Player:
			return
		object.global_position += (get_viewport().get_camera_2d().get_screen_center_position() - clipboard_camera_position).snappedf(Constants.CELL_SIZE)

	var new_selection: Selection = clipboard.map(_clone_object)
	new_selection.for_each(move_objects_to_new_screen_center)
	var new_selection_size: int = new_selection.size()
	if new_selection.contains(LevelManager.player):
		new_selection_size -= 1

	Editor.version_history.create_action("Duplicated %s objects" % new_selection_size)
	Editor.version_history.add_do_method(do_duplicate_selection.bind(new_selection))
	Editor.version_history.add_undo_method(undo_duplicate_selection.bind(new_selection))
	Editor.version_history.commit_action()
	select(new_selection, true)


func delete_selection() -> void:
	if selection.is_empty() or (selection.size() == 1 and selection.first() is Player):
		return

	var do_delete_selection := func(_selection: Selection):
		_selection.for_each(
			func(_object: Node2D) -> void:
				if _object is not Player:
					_object.set_meta(&"index_in_layer", _object.get_index())
					_object.get_parent().remove_child(_object)
		)
	var undo_delete_selection := func(_selection: Selection):
		_selection.for_each(
			func(_object: Node2D) -> void:
				if _object is Player:
					return
				var layer: Layer = _object.get_meta(Constants.LAYER_META)
				if not layer:
					return
				layer.add_child(_object)
				NodeUtils.change_owner_recursive(_object, level)
		)
		_selection.for_each(
			func(_object: Node2D) -> void:
				var layer: Layer = _object.get_meta(Constants.LAYER_META)
				if not layer:
					return
				layer.move_child(_object, _object.get_meta(&"index_in_layer", -1)),
			true, # Reorders in reverse order to avoid messing up the layering
		)

	var selection_snapshot: Selection = selection.clone()
	Editor.version_history.create_action("Deleted objects")
	Editor.version_history.add_do_method(do_delete_selection.bind(selection_snapshot))
	Editor.version_history.add_undo_method(undo_delete_selection.bind(selection_snapshot))
	Editor.version_history.commit_action()
	clear_selection(true)
	deleted_selection.emit()


func clear_selection(merge_history_actions: bool = false) -> void:
	select(Selection.EMPTY(), merge_history_actions)
	_reset_selection_zone()


func select_all(merge_history_actions: bool = false) -> void:
	var only_node_2ds := func(object): return object is Node2D
	var objects: Array[Node2D]
	for layer in level.layers:
		if layer.hidden_in_editor or layer.locked:
			continue
		objects.append_array(layer.get_children().filter(only_node_2ds))
	select(Selection.from_array(objects), merge_history_actions)


func remove_gizmo(_selection = null) -> void:
	if not gizmo:
		return
	gizmo.remove_gizmo()
	if selection_changed.is_connected(remove_gizmo):
		selection_changed.disconnect(remove_gizmo)
	if get_viewport().gui_focus_changed.is_connected(remove_gizmo):
		get_viewport().gui_focus_changed.disconnect(remove_gizmo)
	gizmo = null


func any_gizmo_is_open() -> bool:
	return gizmo != null


func update_pivot() -> void:
	if selection.is_empty():
		return
	var group_parents: Selection = selection.filter(func(object: Node2D): return object.has_meta("group_parent"))
	if not group_parents.is_empty():
		selection_pivot = group_parents.first().global_position
	else:
		# Take the mean of the position of all objects
		var object_positions := (
				selection \
						.map_generic(func(object: Node2D): return object.global_position)
		)
		if object_positions.is_empty():
			return
		selection_pivot_with_player = ArrayUtils.transform(object_positions, ArrayUtils.Transformation.MEAN, true)
		object_positions = (
				selection \
						.filter(is_not_player) \
						.map_generic(func(object: Node2D): return object.global_position)
		)
		if object_positions.is_empty():
			return
		selection_pivot = ArrayUtils.transform(object_positions, ArrayUtils.Transformation.MEAN, true)


func select(objects: Selection, merge_history_actions: bool = false, as_duplicate: bool = false) -> void:
	# Avoid creating unnecessary actions
	if selection.is_identical(objects):
		return
	var change_selection := func(new_selection: Selection, is_undo: bool):
		selection.for_each(remove_selection_highlight)
		selection = new_selection
		if not new_selection.is_empty():
			selection.for_each(add_selection_highlight.bind(as_duplicate and not is_undo))
		selection_changed.emit(selection)
	if merge_history_actions:
		Editor.version_history.create_action(Editor.version_history.get_current_action_name(), UndoRedo.MERGE_ALL)
	else:
		Editor.version_history.create_action("Selected %s objects" % objects.size())
	Editor.version_history.add_do_method(change_selection.bind(objects, false))
	Editor.version_history.add_undo_method(change_selection.bind(selection.clone(), true))
	Editor.version_history.commit_action()


func deselect(objects: Selection, merge_history_actions: bool = false) -> void:
	# Avoid creating unnecessary actions
	if objects.is_empty() or selection.is_identical(objects):
		return
	var do_deselection := func(negative_selection: Selection):
		selection.for_each(remove_selection_highlight)
		selection = selection.difference(negative_selection)
		selection.for_each(add_selection_highlight)
		selection_changed.emit(selection)
	var undo_deselection := func(new_selection: Selection):
		selection.for_each(remove_selection_highlight)
		selection = new_selection
		if not new_selection.is_empty():
			selection.for_each(add_selection_highlight)
		selection_changed.emit(selection)
	if merge_history_actions:
		Editor.version_history.create_action(Editor.version_history.get_current_action_name(), UndoRedo.MERGE_ALL)
	else:
		Editor.version_history.create_action("Deselected %s objects" % objects.size())
	Editor.version_history.add_do_method(do_deselection.bind(objects))
	Editor.version_history.add_undo_method(undo_deselection.bind(selection.clone()))
	Editor.version_history.commit_action()


func _handle_input() -> void:
	var can_use_actions: bool = (
			not Editor.is_picking_node
			and not selection.is_empty()
			and not (
					Input.is_action_pressed(&"editor_save", true)
					or Input.is_action_pressed(&"editor_save_as", true)
					or Input.is_action_pressed(&"editor_new_level", true)
					or Input.is_action_pressed(&"editor_import_level", true)
					or Input.is_action_pressed(&"editor_export_level", true)
					or any_gizmo_is_open()
					or Editor.is_text_input_focused()
			)
	)
	if not can_use_actions:
		return

	if Input.is_action_just_pressed(&"editor_deselect", true):
		clear_selection()
	if Input.is_action_just_pressed(&"editor_delete", true):
		delete_selection()
	if Input.is_action_just_pressed(&"editor_duplicate", true):
		duplicate_selection()
		throttle_move_seconds = 5.0
	if Input.is_action_just_pressed(&"ui_copy", true):
		copy_selection()
	if Input.is_action_just_pressed(&"ui_paste", true):
		paste_selection()
	if Input.get_axis(&"editor_rotate_-45", &"editor_rotate_45") and throttle_rotate_seconds <= 0:
		update_pivot()
		rotate_selection(Input.get_axis(&"editor_rotate_-45", &"editor_rotate_45") * 45.0)
		throttle_rotate_seconds = THROTTLE_ROTATE_COOLDOWN
	if Input.get_axis(&"editor_rotate_-90", &"editor_rotate_90") and throttle_rotate_seconds <= 0:
		update_pivot()
		rotate_selection(Input.get_axis(&"editor_rotate_-90", &"editor_rotate_90") * 90.0)
		throttle_rotate_seconds = THROTTLE_ROTATE_COOLDOWN
	if Input.is_action_just_pressed(&"editor_flip_h", true):
		_flip_selection(Vector2.AXIS_X)
	if Input.is_action_just_pressed(&"editor_flip_v", true):
		_flip_selection(Vector2.AXIS_Y)
	if Input.is_action_just_pressed(&"editor_rotate_free", true):
		_on_rotate_free_pressed()
	elif Input.is_action_just_pressed(&"editor_quick_rotate_free", true):
		_on_rotate_free_pressed(true)
	if Input.is_action_just_pressed(&"editor_scale", true):
		_on_scale_pressed()
	elif Input.is_action_just_pressed(&"editor_quick_scale", true):
		_on_scale_pressed(true)
	if Input.is_action_just_pressed(&"editor_move", true):
		_on_move_pressed()
	elif Input.is_action_just_pressed(&"editor_quick_move", true):
		_on_move_pressed(true)

	_handle_move_keys()


func _handle_move_keys() -> void:
	if Input.is_key_pressed(KEY_CTRL):
		return

	var direction: Vector2 = Vector2.ZERO
	if Input.is_action_just_pressed(&"editor_move_left", true):
		direction.x -= 1
	if Input.is_action_just_pressed(&"editor_move_right", true):
		direction.x += 1
	if Input.is_action_just_pressed(&"editor_move_up", true):
		direction.y -= 1
	if Input.is_action_just_pressed(&"editor_move_down", true):
		direction.y += 1

	var direction_changed_this_frame: bool = direction != Vector2.ZERO
	var held_direction: Vector2 = Input.get_vector(&"editor_move_left", &"editor_move_right", &"editor_move_up", &"editor_move_down").sign()
	if direction_changed_this_frame:
		throttle_move_seconds = THROTTLE_MOVE_COOLDOWN
	elif throttle_move_seconds <= 0.0 and held_direction != Vector2.ZERO:
		direction = held_direction
		throttle_move_seconds = THROTTLE_MOVE_COOLDOWN
	if direction == Vector2.ZERO:
		return

	var move_multiplier: float = 1.0
	if Input.is_key_pressed(KEY_SHIFT):
		move_multiplier = 0.5
	move_selection(direction * move_multiplier)


func _update_selection() -> void:
	if Input.is_action_just_pressed(&"editor_add") or Input.is_action_just_pressed(&"editor_selection_remove"):
		_reset_selection_zone(false)
	if Input.is_action_just_pressed(&"editor_add", false) and get_viewport().gui_get_hovered_control() == Editor.viewport:
		if not Input.is_action_just_pressed(&"editor_add_swipe", true) \
				and not Input.is_action_just_pressed(&"editor_selection_remove", true):
			selection_index += 1
		if (
				not (
						Input.is_action_just_pressed(&"editor_add_swipe", false)
						or Input.is_action_just_pressed(&"editor_selection_remove", false)
				)
		):
			if placed_objects_collider.has_overlapping_areas():
				var cycled_object: Node2D = (
						get_object_parent(
							placed_objects_collider.get_overlapping_areas()[selection_index % len(placed_objects_collider.get_overlapping_areas())],
						)
				)
				if is_in_editable_layer(cycled_object):
					select(Selection.from_object(cycled_object))
					selection_changed_viewport.emit()
			else:
				select(Selection.EMPTY())
				selection_changed_viewport.emit()
	if Input.is_action_pressed(&"editor_selection_remove", false) or Input.is_action_pressed(&"editor_add", false):
		_swipe_selection_zone()
	if Input.is_action_just_released(&"editor_selection_remove", true):
		var selection_buffer_array: Array[Node2D]
		selection_buffer_array.assign(
			$SelectionZone \
					.get_overlapping_areas() \
					.map(get_object_parent) \
					.filter(is_in_editable_layer),
		)
		var selection_buffer: Selection = Selection.from_array(selection_buffer_array)
		deselect(selection_buffer)
		selection_changed_viewport.emit()
		_reset_selection_zone(true)
	elif (Input.is_action_just_released(&"editor_add", true) and $SelectionZone/Hitbox.shape.size > Vector2.ONE * 2) or Input.is_action_just_released(&"editor_add_swipe", true):
		var selection_buffer_array: Array[Node2D]
		selection_buffer_array.assign(
			$SelectionZone \
					.get_overlapping_areas() \
					.map(get_object_parent) \
					.filter(is_in_editable_layer),
		)
		var selection_buffer: Selection = Selection.from_array(selection_buffer_array)
		select(selection.union(selection_buffer))
		selection_changed_viewport.emit()
		_reset_selection_zone(true)
	elif Input.is_action_just_released(&"editor_add", true) and $SelectionZone/Hitbox.shape.size < Vector2.ONE * 2:
		_reset_selection_zone(true)


func _update_interactive_picking() -> void:
	if not (
			get_viewport().gui_get_hovered_control() == Editor.viewport
			and Input.is_action_just_pressed(&"editor_add", true)
	):
		return
	# Clicking on an empty space will cancel the picking.
	var picked_object: Node2D
	if placed_objects_collider.has_overlapping_areas():
		picked_object = get_object_parent(placed_objects_collider.get_overlapping_areas()[0])
	var active_node_property: NodeProperty = Editor.shortcut_blocker
	active_node_property.finish_interactive_picker(picked_object)


func _reset_selection_zone(unreachable: bool = true) -> void:
	$SelectionZone.position = Vector2.ONE * INF if unreachable else get_parent().get_local_mouse_position()
	$SelectionZone/Hitbox.shape.size = Vector2.ZERO
	$SelectionZone/Hitbox.position = Vector2.ZERO
	selection_zone_changed.emit(Rect2(Vector2.ZERO, Vector2.ZERO))


func _swipe_selection_zone() -> void:
	var mouse_position := get_parent().get_local_mouse_position() as Vector2
	var hitbox := $SelectionZone/Hitbox as CollisionShape2D

	hitbox.shape.size = abs(mouse_position - $SelectionZone.position)
	# Right Down
	if mouse_position.x >= $SelectionZone.position.x and mouse_position.y >= $SelectionZone.position.y:
		hitbox.position = hitbox.shape.size * 0.5
	# Right Up
	elif mouse_position.x >= $SelectionZone.position.x and mouse_position.y < $SelectionZone.position.y:
		hitbox.position.x = hitbox.shape.size.x * 0.5
		hitbox.position.y = -hitbox.shape.size.y * 0.5
	# Left Down
	elif mouse_position.x < $SelectionZone.position.x and mouse_position.y >= $SelectionZone.position.y:
		hitbox.position.x = -hitbox.shape.size.x * 0.5
		hitbox.position.y = hitbox.shape.size.y * 0.5
	# Left Up
	elif mouse_position.x < $SelectionZone.position.x and mouse_position.y < $SelectionZone.position.y:
		hitbox.position = -hitbox.shape.size * 0.5

	selection_zone_changed.emit(Rect2($SelectionZone/Hitbox.position - $SelectionZone/Hitbox.shape.size * 0.5, $SelectionZone/Hitbox.shape.size))


func _flip_selection(axis: int):
	if selection.is_empty() or (selection.size() == 1 and selection.first() is Player):
		return
	var flip: Callable
	var unflip := func(_object, _scale, _position):
		_object.scale = _scale
		_object.global_position = _position
	match axis:
		Vector2.AXIS_X:
			flip = func(_object):
				_object.scale.x *= -1
				var position_relative_to_pivot: Vector2 = _object.global_position - selection_pivot
				_object.global_position.x = selection_pivot.x - position_relative_to_pivot.x
		Vector2.AXIS_Y:
			flip = func(_object):
				_object.scale.y *= -1
				var position_relative_to_pivot: Vector2 = _object.global_position - selection_pivot
				_object.global_position.y = selection_pivot.y - position_relative_to_pivot.y
	Editor.version_history.create_action("Flipped objects")
	for object in selection.to_array():
		if object is Player:
			continue
		Editor.version_history.add_do_method(flip.bind(object))
		Editor.version_history.add_undo_method(unflip.bind(object, object.scale, object.global_position))
	Editor.version_history.commit_action()


func _clone_object(object: Node2D) -> Node2D:
	if object is Player:
		return object
	var object_data: Dictionary = Level.serialize_object(object, Serialize.Reason.SAVE)
	var cloned_object: Node2D = Level.instantiate_object_from_data(object_data)
	# Cloning can legitimately produce nothing - imported decoration whose
	# artwork is missing, for instance - so callers get null rather than a
	# half-built node.
	if cloned_object == null:
		return null
	Level.deserialize_data_to_object(object_data, cloned_object, level, true)
	cloned_object.set_meta(Constants.LAYER_META, object.get_parent())
	return cloned_object


func _on_place_handler_object_deleted(object: Node2D) -> void:
	if selection.contains(object):
		selection.remove(object)
		selection_changed.emit(selection)


func _on_move_controls_direction_pressed(direction: Vector2, step: float) -> void:
	if selection.is_empty():
		return
	move_selection(direction * step)


func _on_rotate_left_90_pressed() -> void:
	update_pivot()
	rotate_selection(-90)


func _on_rotate_right_90_pressed() -> void:
	update_pivot()
	rotate_selection(90)


func _on_rotate_left_45_pressed() -> void:
	update_pivot()
	rotate_selection(-45)


func _on_rotate_right_45_pressed() -> void:
	update_pivot()
	rotate_selection(45)


func _on_flip_h_pressed() -> void:
	update_pivot()
	_flip_selection(Vector2.AXIS_X)


func _on_flip_v_pressed() -> void:
	update_pivot()
	_flip_selection(Vector2.AXIS_Y)


func _on_rotate_free_pressed(quick: bool = false) -> void:
	if selection.is_empty() or (selection.size() == 1 and selection.first() is Player):
		return
	if any_gizmo_is_open():
		remove_gizmo()
	update_pivot()
	gizmo = RotateGizmo.new()
	if get_viewport().gui_focus_changed.is_connected(remove_gizmo):
		get_viewport().gui_focus_changed.disconnect(remove_gizmo)
	if quick:
		gizmo.quick(keychord_display, "Rotating", "°", true)
		get_viewport().gui_focus_changed.connect(remove_gizmo)
	gizmo_layer.add_child(gizmo)
	gizmo.global_position = selection_pivot
	gizmo.angle_changed.connect(rotate_selection.bind(true))
	var _on_rotate_gizmo_confirmed := func(angle: float):
		# Undo untracked rotation
		rotate_selection(-angle, true)
		rotate_selection(angle)
	gizmo.confirmed.connect(_on_rotate_gizmo_confirmed)
	selection_changed.connect(remove_gizmo)


func _on_move_pressed(quick: bool = false):
	if selection.is_empty():
		return
	if any_gizmo_is_open():
		remove_gizmo()
	update_pivot()
	gizmo = MoveGizmo.new()
	gizmo.global_position = selection_pivot_with_player
	if quick:
		gizmo.quick(keychord_display, "Moving", " units", false)
	gizmo_layer.add_child(gizmo)
	gizmo.position_changed.connect(move_selection.bind(false))
	gizmo.confirmed.connect(move_selection.bind(true))
	NodeUtils.connect_once(selection_changed, remove_gizmo)


func _on_scale_pressed(quick: bool = false) -> void:
	if selection.is_empty() or (selection.size() == 1 and selection.first() is Player):
		return
	update_pivot()
	if any_gizmo_is_open():
		remove_gizmo()

	var selection_collision_objects: Array[CollisionObject2D]
	selection_collision_objects.assign(
		selection.filter(func(object: Node2D): return object is CollisionObject2D and object is not Player).to_array(),
	)

	var first_object_rotation: float = selection.first().global_rotation
	var mean_objects_rotation: float = first_object_rotation
	var gizmo_center: Vector2 = ArrayUtils.transform(
		selection.filter(is_not_player) \
				.map_generic(func(object: Node2D): return object.global_position.rotated(-mean_objects_rotation)),
		ArrayUtils.Transformation.MEAN,
		true,
	).rotated(mean_objects_rotation)
	selection_pivot = gizmo_center

	selection_collision_objects.assign(selection_collision_objects.map(get_object_selection_collider))
	var selection_bounding_box: Transform2D = BoundingBox.new(selection_collision_objects, selection_pivot, mean_objects_rotation).as_transform()
	gizmo = ScaleGizmo.new(selection_bounding_box, gizmo_center, mean_objects_rotation)
	if get_viewport().gui_focus_changed.is_connected(remove_gizmo):
		get_viewport().gui_focus_changed.disconnect(remove_gizmo)
	if quick:
		gizmo.quick(keychord_display, "Scaling", "×", false)
		get_viewport().gui_focus_changed.connect(remove_gizmo)
	gizmo_layer.add_child(gizmo)
	gizmo.scale_changed.connect(scale_selection.bind(TransformHistory.APPLY))

	var _on_scale_gizmo_confirmed := func(transform: Transform2D, initial_rotation: float, is_global: bool):
		scale_selection(transform.affine_inverse(), initial_rotation, is_global, TransformHistory.APPLY)
		scale_selection(transform, initial_rotation, is_global, TransformHistory.FINISH)

	gizmo.confirmed.connect(_on_scale_gizmo_confirmed)
	NodeUtils.connect_once(selection_changed, remove_gizmo)


func scale_transform(
		object: Node2D,
		transform: Transform2D,
):
	if object is Player:
		return
	object.global_transform = (transform * object.global_transform.translated(-selection_pivot)).translated(selection_pivot)
	if object is StaticBody2D:
		var absolutesize: NinePatchSprite2DAbsoluteSize = object.get_node_or_null(^"NinePatchSprite2DAbsoluteSize")
		if absolutesize == null:
			return
		absolutesize.update_size()


func scale_transform_local(
		object: Node2D,
		transform: Transform2D,
		initial_rotation: float,
):
	if object is Player:
		return
	object.global_transform = (transform * object.global_transform.translated(-selection_pivot).rotated(-initial_rotation)).rotated(initial_rotation).translated(selection_pivot)
	if object is StaticBody2D:
		var absolutesize: NinePatchSprite2DAbsoluteSize = object.get_node_or_null(^"NinePatchSprite2DAbsoluteSize")
		if absolutesize == null:
			return
		absolutesize.update_size()


static func add_selection_highlight(object: Node2D, as_duplicate: bool = false) -> void:
	var hsv_watcher: HSVWatcher
	if object is Interactable and object.has(DefaultPlayerDataComponent):
		hsv_watcher = NodeUtils.get_child_of_type(object.get_parent(), HSVWatcher)
	else:
		hsv_watcher = NodeUtils.get_child_of_type(object, HSVWatcher)
	# A batch of fallback decoration has no watcher; it simply isn't tinted.
	if hsv_watcher == null:
		return
	hsv_watcher.selection_highlight = HSVWatcher.SelectionHighlight.NORMAL if not as_duplicate else HSVWatcher.SelectionHighlight.DUPLICATE
	hsv_watcher.update_color()


static func remove_selection_highlight(object: Node2D) -> void:
	var hsv_watcher: HSVWatcher = NodeUtils.get_child_of_type(object, HSVWatcher)
	if hsv_watcher == null:
		return
	hsv_watcher.selection_highlight = HSVWatcher.SelectionHighlight.NONE
	hsv_watcher.update_color()


static func get_object_parent(object: Node) -> Node2D:
	if object is EditorSelectionCollider or object.has_meta(&"EditorPlayerSelectionCollider"):
		return object.get_parent()
	else:
		return object


static func get_object_selection_collider(object: Node2D) -> CollisionObject2D:
	var selection_collider: EditorSelectionCollider = NodeUtils.get_child_of_type(object, EditorSelectionCollider)
	return selection_collider if selection_collider else object as CollisionObject2D


static func is_not_player(object: Node2D) -> bool:
	return object is not Player


static func is_in_editable_layer(object: Node2D) -> bool:
	if object is Player:
		return true
	var object_parent: Node = object.get_parent()
	return object_parent is Layer and not (object_parent.hidden_in_editor or object_parent.locked)
