class_name InspectorTree
extends Tree

const LAYER_ICON: Texture2D = preload("res://addons/at-icons/node/layers.svg")
const VISIBLE_ICON: Texture2D = preload("res://addons/at-icons/node/eye.svg")
const HIDDEN_ICON: Texture2D = preload("res://addons/at-icons/node/eye_closed.svg")
const LOCK_ICON: Texture2D = preload("res://addons/at-icons/node/lock.svg")
const UNLOCK_ICON: Texture2D = preload("res://addons/at-icons/node/unlock.svg")
const ITEM_HEIGHT: int = 2 * 4 + 16 # 2 * v_separation + font_size

enum LayerIcon {
	VISIBILITY,
	LOCK,
}

enum DropSection {
	ABOVE_ITEM,
	BELOW_ITEM,
	ABOVE_FIRST_CHILD,
	ABOVE_TREE,
	BELOW_TREE,
	UNDEFINED,
}

@onready var scroll_container: SmoothScrollContainer = get_parent()

@export var search_box: LineEdit

var selection: Selection
var flat_item_list: Array[TreeItem]


## Objects listed per layer before the tree stops and shows a count instead.
const MAX_ITEMS_PER_LAYER: int = 1000


func _ready() -> void:
	# Init root
	create_item()


func _gui_input(event):
	if event is InputEventMouseButton:
		# Prevent tree from eating up scrolling inputs.
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scroll_container._gui_input(event)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_LEFT and get_selected_items().size() == 1:
			if not event.double_click:
				get_next_selected(null).set_editable(0, true)


func _get_drag_data(_at_position: Vector2) -> Variant:
	return true


func _can_drop_data(at_position: Vector2, _data: Variant) -> bool:
	var dropped_items: Array[TreeItem] = get_selected_items()
	var item_at_position: TreeItem = get_item_at_position(at_position)
	var drop_section: DropSection = get_drop_section_at(at_position)
	if not item_at_position:
		match drop_section:
			DropSection.ABOVE_TREE:
				item_at_position = get_root().get_first_child()
			DropSection.BELOW_TREE:
				item_at_position = get_last_tree_item()
	var is_reordering_layers: bool = dropped_items[0].get_parent() == get_root()
	var is_dropping_on_layer: bool = item_at_position.get_parent() == get_root()

	if not is_reordering_layers:
		if is_dropping_on_layer:
			drop_mode_flags = DROP_MODE_ON_ITEM
		else:
			drop_mode_flags = DROP_MODE_INBETWEEN
		return true
	elif drop_section == DropSection.BELOW_TREE or is_dropping_on_layer:
		drop_mode_flags = DROP_MODE_INBETWEEN
		return true
	else:
		drop_mode_flags = DROP_MODE_DISABLED
	return false


func _drop_data(at_position: Vector2, _data: Variant) -> void:
	var dropped_items: Array[TreeItem] = get_selected_items()
	var item_at_position: TreeItem = get_item_at_position(at_position)
	var drop_section: DropSection = get_drop_section_at(at_position)
	if not item_at_position:
		match drop_section:
			DropSection.ABOVE_TREE:
				item_at_position = get_root().get_first_child()
			DropSection.BELOW_TREE:
				item_at_position = get_last_tree_item()
	var is_cursor_closer_to_top: bool = get_drop_section_at_position(at_position) == -1
	# Reordering
	var is_dropping_on_layer: bool = item_at_position.get_parent() == get_root()
	var is_reordering_layer: bool = dropped_items[0].get_parent() == get_root()
	var level: Level = Editor.root.level

	var do_methods: Array[Callable]
	var undo_methods: Array[Callable]

	for dropped_item: TreeItem in dropped_items:
		var previous_index: int = dropped_item.get_index()
		if not is_reordering_layer:
			var layer: Layer = level.layers[dropped_item.get_parent().get_index()]
			var reordered_object: Node2D = layer.get_child(dropped_item.get_index())
			var reordered_object_name: StringName = reordered_object.name
			if is_dropping_on_layer:
				var new_layer: Layer = level.layers[item_at_position.get_index()]
				var is_dropping_on_same_layer: bool = reordered_object.get_parent() == new_layer
				if not is_dropping_on_same_layer:
					do_methods.append(
						func():
							if new_layer != layer and new_layer.has_node(NodePath(reordered_object_name)):
								var name_collision_offset: int = 1
								while new_layer.has_node(reordered_object_name + str(name_collision_offset)):
									name_collision_offset += 1
								reordered_object.name = reordered_object_name + str(name_collision_offset)
							reordered_object.reparent(new_layer)
							new_layer.move_child(reordered_object, -1)
					)
					undo_methods.append(
						func():
							reordered_object.reparent(layer)
							layer.move_child(reordered_object, previous_index)
							reordered_object.name = reordered_object_name
					)
			else:
				var layer_item: TreeItem = item_at_position.get_parent()
				var new_layer: Layer = level.layers[layer_item.get_index()]
				var new_index: int = item_at_position.get_index() if is_cursor_closer_to_top else item_at_position.get_index() + 1
				do_methods.append(
					func():
						if new_layer != layer and new_layer.has_node(NodePath(reordered_object_name)):
							var name_collision_offset: int = 1
							while new_layer.has_node(reordered_object_name + str(name_collision_offset)):
								name_collision_offset += 1
							reordered_object.name = reordered_object_name + str(name_collision_offset)
						reordered_object.reparent(new_layer)
						new_layer.move_child(reordered_object, new_index)
				)
				undo_methods.append(
					func():
						reordered_object.reparent(layer)
						layer.move_child(reordered_object, previous_index)
						reordered_object.name = reordered_object_name
				)
		else:
			var layer: Layer = level.layers[dropped_item.get_index()]
			var layer_name: String = layer.name
			var new_layer_idx: int = item_at_position.get_index()
			do_methods.append(level.move_layer.bind(layer_name, new_layer_idx))
			undo_methods.append(level.move_layer.bind(layer_name, previous_index))

	if not is_cursor_closer_to_top and not is_dropping_on_layer:
		do_methods.reverse()

	var version_history: UndoRedo = Editor.version_history
	version_history.create_action("Reordered objects")
	for do_method: Callable in do_methods:
		version_history.add_do_method(do_method)
	for undo_method: Callable in undo_methods:
		version_history.add_undo_method(undo_method)
	version_history.add_do_method(refresh)
	version_history.add_undo_method(refresh)
	version_history.commit_action()


func get_last_tree_item() -> TreeItem:
	var last_tree_item: TreeItem = get_root().get_child(-1)
	if not last_tree_item:
		return null
	while last_tree_item.get_child_count() > 0:
		last_tree_item = last_tree_item.get_child(-1)
	return last_tree_item


func refresh(selected: Selection = selection) -> void:
	selection = selected
	clear()
	var root: TreeItem = create_item()
	var level: Level = Editor.root.level
	var layers: Array[Layer] = level.layers
	for layer_idx: int in layers.size():
		var layer: Layer = layers[layer_idx]
		var layer_item: TreeItem
		layer_item = root.create_child()
		layer_item.set_icon(0, LAYER_ICON)
		layer_item.add_button(0, VISIBLE_ICON)
		if layer.locked:
			layer_item.add_button(0, LOCK_ICON)
		else:
			layer_item.add_button(0, UNLOCK_ICON)
		layer_item.set_text(0, layer.name)
		if layer.selected_in_editor:
			layer_item.select(0)
		else:
			layer_item.deselect(0)
		if layer_idx == level.active_layer_idx:
			layer_item.set_custom_bg_color(0, Color.WHITE, true)
		layer_item.visible = true
		# An imported Geometry Dash level can hold a hundred thousand objects
		# per layer; listing them all would freeze the editor on every
		# selection change. The tree shows the first MAX_ITEMS_PER_LAYER and
		# says how many more there are.
		var shown: int = mini(layer.get_child_count(), MAX_ITEMS_PER_LAYER)
		for object_idx: int in shown:
			var object: Node2D = layer.get_child(object_idx)
			var object_item: TreeItem = layer_item.create_child()
			object_item.visible = true
			object_item.set_text(0, object.name)
			object_item.set_icon(0, ObjectThumbnail.generate(object, 16))
			if selection.contains(object):
				object_item.select(0)
			else:
				object_item.deselect(0)
		if layer.get_child_count() > shown:
			var more_item: TreeItem = layer_item.create_child()
			more_item.visible = true
			more_item.set_text(0, "… and %d more objects" % (layer.get_child_count() - shown))
			more_item.set_selectable(0, false)
			more_item.set_custom_color(0, Color(1.0, 1.0, 1.0, 0.5))

	update_active_layer(false)


func update_active_layer(is_changing_single_layer_selection: bool) -> void:
	var root: TreeItem = get_root()
	var level: Level = Editor.root.level
	var first_item_in_selection: TreeItem = get_next_selected(null)
	var selection_is_single_layer: bool = first_item_in_selection and first_item_in_selection.get_parent() == root
	if not selection_is_single_layer:
		return
	var new_active_layer_idx: int = first_item_in_selection.get_index()
	if level.active_layer_idx == new_active_layer_idx:
		return
	if is_changing_single_layer_selection:
		Editor.version_history.create_action("Set active layer to %s" % root.get_child(new_active_layer_idx).get_text(0))
	else:
		Editor.version_history.create_action(Editor.version_history.get_current_action_name(), UndoRedo.MERGE_ALL)
	Editor.version_history.add_do_method(set_active_layer.bind(level.active_layer_idx, new_active_layer_idx))
	Editor.version_history.add_do_method(_set_layer_item_selected_silent.bind(level.active_layer_idx, new_active_layer_idx, is_changing_single_layer_selection, true))
	Editor.version_history.add_undo_method(set_active_layer.bind(new_active_layer_idx, level.active_layer_idx))
	Editor.version_history.add_undo_method(_set_layer_item_selected_silent.bind(level.active_layer_idx, new_active_layer_idx, is_changing_single_layer_selection, false))
	Editor.version_history.commit_action()


func set_active_layer(previous_layer_idx: int, new_layer_idx: int) -> void:
	var root: TreeItem = get_root()
	var level: Level = Editor.root.level
	root.get_child(previous_layer_idx).clear_custom_bg_color(0)
	level.active_layer_idx = new_layer_idx
	root.get_child(new_layer_idx).set_custom_bg_color(0, Color.WHITE, true)


func handle_item_rename(item: TreeItem) -> void:
	var is_item_layer: bool = item.get_parent() == get_root()
	var new_name: String = item.get_text(0)
	if is_item_layer:
		_update_layer_name(item, new_name)
	else:
		Editor.root.inspector_manager.update_object_name(new_name)


func set_items_editable(editable: bool) -> void:
	for item: TreeItem in get_flat_visible_item_list():
		item.set_editable(0, editable)


func get_selected_items() -> Array[TreeItem]:
	var item: TreeItem = null
	var selected_items: Array[TreeItem]
	while get_next_selected(item):
		selected_items.append(get_next_selected(item))
		item = get_next_selected(item)
	return selected_items


func set_selected_items(selected_items: Array[TreeItem]) -> void:
	for item: TreeItem in get_flat_visible_item_list():
		if item in selected_items:
			item.select(0)
		else:
			item.deselect(0)


func is_layer_selected_exclusive() -> bool:
	return get_selected_items().size() == 1 and get_next_selected(null).get_parent() == get_root()


func bulk_update_selection(is_caller_selected: bool) -> void:
	var edit_handler: EditHandler = Editor.root.edit_handler
	if selection.is_identical(edit_handler.selection) and is_caller_selected:
		update_active_layer(true)
		return
	edit_handler.select(selection)


func get_drop_section_at(at: Vector2) -> DropSection:
	match get_drop_section_at_position(at):
		-1:
			return DropSection.ABOVE_ITEM
		1:
			return DropSection.BELOW_ITEM
		2:
			return DropSection.ABOVE_FIRST_CHILD
		-100:
			return DropSection.ABOVE_TREE if at.y < ITEM_HEIGHT / 2.0 else DropSection.BELOW_TREE
	return DropSection.UNDEFINED


func filter_items(match_expr: String) -> void:
	if match_expr.is_empty():
		for item: TreeItem in flat_item_list:
			item.visible = true
		return
	var valid_items: Array[TreeItem]
	for item: TreeItem in flat_item_list:
		if StringUtils.fuzzy_filter([item.get_text(0)], match_expr).is_empty():
			item.visible = false
			continue
		item.uncollapse_tree()
		if item not in valid_items:
			valid_items.append(item)
		# Parents need to be visible for the item to be visible too.
		for item_parent: TreeItem in get_item_parents(item):
			if item_parent not in valid_items:
				valid_items.append(item_parent)
	for valid_item: TreeItem in valid_items:
		valid_item.visible = true


func get_flat_visible_item_list() -> Array[TreeItem]:
	var new_flat_item_list: Array[TreeItem]
	_get_flat_item_list_inner(get_root(), new_flat_item_list)
	return new_flat_item_list


func get_item_parents(item: TreeItem) -> Array[TreeItem]:
	var parents: Array[TreeItem]
	var traversed_item: TreeItem = item
	while traversed_item.get_parent() != get_root():
		traversed_item = traversed_item.get_parent()
		parents.append(traversed_item)
	return parents


func _get_flat_item_list_inner(item: TreeItem, new_flat_item_list: Array[TreeItem], depth: int = 0) -> void:
	const MAX_RECURSION_DEPTH: int = 6
	if depth >= MAX_RECURSION_DEPTH or item.get_child_count() == 0:
		return
	for child_item: TreeItem in item.get_children():
		new_flat_item_list.append(child_item)
		_get_flat_item_list_inner(child_item, new_flat_item_list, depth + 1)


func _set_layer_item_selected_silent(
		previous_layer_idx: int,
		new_layer_idx: int,
		is_changing_single_layer_selection: bool,
		selected: bool,
) -> void:
	var root: TreeItem = get_root()
	var layer_item: TreeItem = root.get_child(new_layer_idx)
	layer_item.set_metadata(0, true)
	if selected:
		layer_item.select(0)
	else:
		layer_item.deselect(0)
	if is_changing_single_layer_selection:
		var previous_layer_item: TreeItem = root.get_child(previous_layer_idx)
		previous_layer_item.set_metadata(0, true)
		if selected:
			previous_layer_item.deselect(0)
		else:
			previous_layer_item.select(0)


func _update_layer_name(item: TreeItem, new_name: String) -> void:
	var layer: Layer = Editor.root.level.layers[item.get_index()]
	var previous_name: String = layer.name
	var sanitized_new_name: String = new_name.validate_node_name()
	Editor.version_history.create_action("Renamed layer %s to %s" % [previous_name, sanitized_new_name])
	Editor.version_history.add_do_property(layer, &"name", sanitized_new_name)
	Editor.version_history.add_undo_property(layer, &"name", previous_name)
	Editor.version_history.add_do_method(refresh)
	Editor.version_history.add_undo_method(refresh)
	Editor.version_history.commit_action()


func _on_edit_handler_selection_changed(new_selection: Selection) -> void:
	if not new_selection.is_empty():
		Editor.root.level.layers.map(Layer.deselect)
	refresh(new_selection)


func _on_edit_handler_selection_changed_viewport() -> void:
	# Scroll to selected item
	var root: TreeItem = get_root()
	var selected_item: TreeItem = get_next_selected(null)
	if not selected_item:
		return
	# Prioritize objects over layers
	if selected_item.get_parent() == root and get_next_selected(selected_item):
		selected_item = get_next_selected(selected_item)
	selected_item.get_parent().set_collapsed(false)
	await get_tree().process_frame # Wait for rect to be updated
	var item_rect: Rect2 = get_item_area_rect(selected_item)
	if item_rect.position.y < scroll_container.scroll_vertical:
		scroll_container.scroll_vertical = int(item_rect.position.y)
	elif item_rect.position.y + item_rect.size.y > scroll_container.scroll_vertical + scroll_container.size.y:
		scroll_container.scroll_vertical = int(item_rect.position.y + item_rect.size.y - scroll_container.size.y)


func _on_level_operations_handler_level_loaded(_level: Level) -> void:
	selection = Selection.EMPTY()
	refresh()


func _on_place_handler_object_deleted(_object: Node2D) -> void:
	refresh()


func _on_multi_selected(item: TreeItem, _column: int, selected: bool) -> void:
	if Editor.is_picking_node:
		return
	var is_item_layer: bool = item.get_parent() == get_root()
	if is_item_layer:
		var layer: Layer = Editor.root.level.layers[item.get_index()]
		layer.selected_in_editor = selected
	else:
		var object_layer: Layer = Editor.root.level.layers[item.get_parent().get_index()]
		var object: Node2D = object_layer.get_child(item.get_index())
		if selected:
			selection = selection.union(Selection.from_object(object))
		else:
			selection = selection.difference(Selection.from_object(object))
	if item.get_metadata(0):
		item.set_metadata(0, false)
		return
	bulk_update_selection.call_deferred(selected)
	refresh.call_deferred()


func _on_button_clicked(item: TreeItem, column: int, id: int, _mouse_button_index: int) -> void:
	var is_item_layer: bool = item.get_parent() == get_root()
	if not is_item_layer:
		return
	var button_texture: Texture2D = item.get_button(column, id)
	var layer_idx: int = item.get_index()
	var layer: Layer = Editor.root.level.layers[layer_idx]
	var on_state_texture: Texture2D
	var off_state_texture: Texture2D
	match id as LayerIcon:
		LayerIcon.VISIBILITY:
			on_state_texture = HIDDEN_ICON
			off_state_texture = VISIBLE_ICON
		LayerIcon.LOCK:
			on_state_texture = LOCK_ICON
			off_state_texture = UNLOCK_ICON
	var is_item_button_toggled: bool = button_texture == on_state_texture
	match id as LayerIcon:
		LayerIcon.VISIBILITY:
			layer.hidden_in_editor = not is_item_button_toggled
		LayerIcon.LOCK:
			layer.locked = not layer.locked
	item.set_button(column, id, off_state_texture if is_item_button_toggled else on_state_texture)


func _on_search_box_editing_toggled(toggled_on: bool) -> void:
	if toggled_on:
		flat_item_list = get_flat_visible_item_list()


func _on_search_box_text_changed(new_text: String) -> void:
	filter_items(new_text)


func _on_search_box_text_submitted(layer_name: String) -> void:
	search_box.clear()
	Editor.root.level.create_layer(layer_name)


func _on_confirm_pressed() -> void:
	var layer_name: String = search_box.text
	search_box.clear()
	Editor.root.level.create_layer(layer_name)


func _on_inspector_manager_renamed_object(object: Node2D, new_name: String) -> void:
	var layer: Layer = object.get_parent()
	var layer_item: TreeItem = get_root().get_child(layer.get_index())
	var object_item: TreeItem = layer_item.get_child(object.get_index())
	object_item.set_text(0, new_name)


func _on_item_edited() -> void:
	var item: TreeItem = get_next_selected(null)
	item.set_editable(0, false)
	handle_item_rename.call_deferred(item)
