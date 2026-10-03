@tool
class_name ResourceProperty
extends Property

signal value_changed(value: Resource)
signal interaction_ended(value: Resource, previous: Resource)

@export var default: Resource
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var indentation_container: VBoxContainer
var resource_properties: Array


func _ready() -> void:
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	var margin_container: MarginContainer = NodeUtils.get_node_or_add(
		NodeUtils.get_node_or_add(self, "PanelContainer", PanelContainer, NodeUtils.INTERNAL),
		"MarginContainer",
		MarginContainer,
		NodeUtils.INTERNAL,
	)
	indentation_container = NodeUtils.get_node_or_add(
		margin_container,
		"VBoxContainer",
		VBoxContainer,
		NodeUtils.INTERNAL,
	)
	assert(default != null, "Default needs to be a valid Resource")
	resource_properties = default.get_property_list()
	if default.get_script():
		resource_properties.append_array(default.get_script().get_script_property_list())
	resource_properties.remove_at(0)
	resource_properties = (
			resource_properties \
					.filter(_is_property_exported) \
					.map(func(property): return property.name)
	)
	var index: int = 0
	for child in get_children(false):
		var child_duplicate: Control = child.duplicate()
		child_duplicate.show()
		index = _connect_child_properties(child_duplicate, index)
		indentation_container.add_child(child_duplicate, false, INTERNAL_MODE_BACK)
		child.queue_free()
	renamed.connect(refresh)
	refresh()
	reset()
	_value.changed.connect(func(): set_value(_value))


func refresh() -> void:
	label.text = name
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Set defaults for individual fields
	var fields: Array[Property]
	fields.assign(NodeUtils.get_children_of_type(indentation_container, Property, true))
	for i in fields.size():
		var field_input: Property = fields[i]
		var field_name: StringName = field_input.get_meta(&"field_name", resource_properties[i])
		var field_value: Variant = default.get(field_name)
		if field_value == null and field_input is not NodeProperty:
			continue
		field_input.default = field_value
	vertical = true
	if Engine.is_editor_hint():
		reset()


func set_value(new_value: Resource) -> void:
	var previous: Resource = _value.duplicate() if _value else new_value.duplicate()
	set_value_no_signal(new_value)
	value_changed.emit(_value)
	if "prevent_history_action" in _value and _value.prevent_history_action:
		return
	interaction_ended.emit(_value, previous)


func set_value_no_signal(new_value: Resource) -> void:
	_value = new_value.duplicate(true)
	var fields: Array = NodeUtils.get_children_of_type(indentation_container, Property, true, true)
	for i in fields.size():
		var field_input: Property = fields[i]
		var field_name: StringName = field_input.get_meta(&"field_name", resource_properties[i])
		var field_value: Variant = _value.get(field_name)
		if field_value == null:
			continue
		field_input.set_value_no_signal(field_value)


func get_value() -> Resource:
	return _value.duplicate(true)


func reset() -> void:
	set_value(default)


func set_input_state(enabled: bool) -> void:
	NodeUtils.get_children_of_type(indentation_container, Property, true).map(func(input): input.set_input_state(enabled))


func _connect_child_properties(node: Node, index: int, depth: int = 0) -> int:
	if depth == 4:
		return index
	if node is Property:
		node.value_changed.connect(
			func(value):
				_value = _value.duplicate(true) if _value else default.duplicate()
				_value.set(node.get_meta(&"field_name", resource_properties[index]), value)
				value_changed.emit(_value)
		)
		node.interaction_ended.connect(
			func(value, previous):
				var _previous: Resource = _value.duplicate()
				_value = _value.duplicate(true)
				_value.set(node.get_meta(&"field_name", resource_properties[index]), value)
				_previous.set(node.get_meta(&"field_name", resource_properties[index]), previous)
				interaction_ended.emit(_value, _previous)
		)
		index += 1
	elif node is FoldableContainer and node.get_child(0) is BoxContainer:
		for child in node.get_child(0).get_children():
			index = _connect_child_properties(child, index, depth + 1)
	return index


func _is_property_exported(property: Dictionary) -> bool:
	return (
			property.usage & PROPERTY_USAGE_EDITOR != 0
			and not property.name.contains("resource")
			and not property.name == "script"
			and not property.name.begins_with("_")
	)
