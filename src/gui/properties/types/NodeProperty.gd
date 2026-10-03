@tool
class_name NodeProperty
extends Property

signal value_changed(value: NodePath)
signal interaction_ended(value: NodePath, previous: NodePath)

@export var default: NodePath
@export var type: Script = null:
	set(value):
		type = value
		notify_property_list_changed()
@export var allow_layer_selection: bool = false
@export var component_filter: Array[Script] # Script can't be filtered by inherited classes so that's the best i can do. `Array[Script[Component]]` would be awesome
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var input: Button
var _tree_item_selection: Array[TreeItem]
var _multi_selected_ran_times: int = 0


func _ready() -> void:
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	input = NodeUtils.get_node_or_add(self, "Input", Button, NodeUtils.INTERNAL)
	input.pressed.connect(_on_input_pressed)
	input.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	renamed.connect(refresh)
	refresh()
	if _value == null:
		reset()
	NodeUtils \
			.get_node_or_add(self, "PropertyReset", PropertyReset, NodeUtils.INTERNAL) \
			.set_input(input)


func _validate_property(property: Dictionary) -> void:
	if property.name == "component_filter" and type != Interactable:
		property.usage = PROPERTY_USAGE_NO_EDITOR


func _input(event: InputEvent) -> void:
	if not (Editor.is_picking_node and Editor.shortcut_blocker == self):
		return
	var is_press: bool = (event is InputEventMouseButton and event.button_index == MouseButton.MOUSE_BUTTON_LEFT) or event is InputEventScreenTouch
	var mouse_hovers_viewport: bool = Editor.viewport.get_global_rect().has_point(get_global_mouse_position())
	var mouse_hovers_tree: bool = Editor.root.inspector_tree.get_global_rect().has_point(get_global_mouse_position())
	var mouse_hovers_self: bool = get_global_rect().has_point(get_global_mouse_position())
	if (
			event.is_action_pressed(&"ui_cancel")
			or (is_press and not (mouse_hovers_viewport or mouse_hovers_tree) and not mouse_hovers_self)
	):
		cancel_interactive_picker()


func set_value(new_value: NodePath) -> void:
	if not new_value.is_empty():
		var node: Node = Deserialize.Node(new_value)
		if (
				(type and not is_instance_of(node, type))
				or (type == Interactable and not _matches_component_filter(node))
		):
			Toasts.error("Selected object is of invalid type for this field.")
			return
	var previous: NodePath = _value
	set_value_no_signal(new_value)
	value_changed.emit(_value)
	interaction_ended.emit(_value, previous)


func set_value_no_signal(new_value: NodePath) -> void:
	if new_value.is_empty():
		input.text = "Assign…"
	else:
		var node: Node = Deserialize.Node(new_value)
		if (
				(type and not is_instance_of(node, type))
				or (type == Interactable and not _matches_component_filter(node))
		):
			Toasts.error("Selected object is of invalid type for this field.")
			return
		input.text = new_value.get_name(new_value.get_name_count() - 1)
		# Remove trailing dots for special nodes, e.g. LevelManager.player
		if input.text.contains(".."):
			input.text = input.text.get_file()
	_value = new_value


func get_value() -> NodePath:
	return _value


func reset() -> void:
	_value = ^""
	input.text = "Assign…"
	value_changed.emit(^"")


func refresh() -> void:
	label.text = name
	if Engine.is_editor_hint():
		reset()


func set_input_state(enabled: bool) -> void:
	input.disabled = not enabled


func finish_interactive_picker(picked_node: Node2D) -> void:
	cancel_interactive_picker()
	if picked_node:
		set_value(Serialize.Node(picked_node))


func cancel_interactive_picker() -> void:
	Editor.shortcut_blocker = null
	Editor.is_picking_node = false
	set_value_no_signal(get_value())
	Editor.viewport.remove_cursor_shape_override()
	var inspector_tree: InspectorTree = Editor.root.inspector_tree
	inspector_tree.mouse_default_cursor_shape = Control.CURSOR_ARROW
	inspector_tree.set_items_editable(true)
	inspector_tree.set_selected_items(_tree_item_selection)
	inspector_tree.multi_selected.disconnect(_finish_tree_interactive_picker)
	_tree_item_selection.clear()


func _matches_component_filter(interactable: Interactable) -> bool:
	for component_script: Script in component_filter:
		if not interactable.has(component_script):
			return false
	return true


func _start_interactive_picker() -> void:
	input.text = "Select an object…"
	Editor.viewport.override_cursor_shape(CursorShape.CURSOR_CROSS)
	Editor.root.inspector_tree.mouse_default_cursor_shape = Control.CURSOR_CROSS
	Editor.is_picking_node = true
	Editor.shortcut_blocker = self


func _finish_tree_interactive_picker(item: TreeItem, _column: int, selected: bool) -> void:
	if not selected or _multi_selected_ran_times > 0:
		return
	var inspector_tree: InspectorTree = Editor.root.inspector_tree
	var picked_item: TreeItem = item
	inspector_tree.set_selected_items(_tree_item_selection)

	# Prevent picking layers.
	var picked_item_is_layer: bool = picked_item.get_parent() == inspector_tree.get_root()
	if picked_item_is_layer and not allow_layer_selection:
		Toasts.warning("Layers cannot be assigned to this property")
		return

	# A valid object was picked.
	_multi_selected_ran_times += 1
	var layer: Layer = Editor.root.level.layers[picked_item.get_parent().get_index()]
	var picked_object: Node2D = layer.get_child(picked_item.get_index())
	cancel_interactive_picker.call_deferred()
	set_value(Serialize.Node(picked_object))


func _on_input_pressed() -> void:
	if Editor.is_picking_node:
		if Editor.shortcut_blocker == self:
			cancel_interactive_picker()
		# Avoid starting another interactive picker if a NodeProperty is already active.
		return
	var inspector_tree: InspectorTree = Editor.root.inspector_tree
	_tree_item_selection = inspector_tree.get_selected_items()
	_multi_selected_ran_times = 0
	inspector_tree.set_items_editable(false)
	NodeUtils.connect_once(inspector_tree.multi_selected, _finish_tree_interactive_picker)
	_start_interactive_picker()
