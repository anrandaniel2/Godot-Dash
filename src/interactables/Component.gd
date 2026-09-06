@abstract
@icon("res://addons/at-icons/node/jigsaw_piece.svg")
class_name Component
extends Node

var parent: Interactable


func _enter_tree() -> void:
	if parent:
		return
	parent = get_parent()
	parent.register_public(self)


func require(component_types: Array[Script]) -> void:
	if not parent.is_node_ready():
		await parent.ready
	for component_type in component_types:
		assert(parent.has(component_type), "%s is missing %s" % [parent, component_type.get_global_name()])


func to_data(reason: Serialize.Reason = Serialize.Reason.SAVE) -> Dictionary:
	var fields: Array[Dictionary] = get_script().get_script_property_list()
	var is_field_serialized := func(field: Dictionary): return field.usage & PROPERTY_USAGE_STORAGE and not field.name.begins_with("_") and field.hint != PROPERTY_HINT_TOOL_BUTTON
	var data: Dictionary
	for field: Dictionary in fields.filter(is_field_serialized):
		var field_name: String = field.name
		var field_value: Variant = _field_to_data(field_name, reason)
		if field_value != null:
			data[field_name] = field_value
	return data


func use_data(data: Dictionary) -> void:
	for field_name in data:
		_field_from_data(field_name, data[field_name])


func get_property_default_value(property: String) -> Variant:
	return _get_property_default_value(property)


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	var field_value: Variant = get(field_name)
	if reason.is_saved_to_file():
		var is_resource := func(element: Variant): return element is Resource
		assert(
			field_value is not Resource and not (field_value is Array and field_value.any(is_resource)),
			"When saved to a file, any component with Resource fields must override `_field_to_data`",
		)
	return field_value


func _field_from_data(field_name: String, field_data: Variant) -> void:
	set(field_name, field_data)


func _get_property_default_value(property: String) -> Variant:
	return null
