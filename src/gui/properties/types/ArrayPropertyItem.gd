@tool
class_name ArrayPropertyItem
extends Property

signal value_changed(value: Variant)
signal interaction_ended(value: Variant, previous: Variant)

var property: Property
var delete_button: Button


func _init(_property: Property) -> void:
	property = _property


func _ready() -> void:
	add_child(property, false, INTERNAL_MODE_FRONT)
	property.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	property.name = name
	property.value_changed.connect(func(value): value_changed.emit(value))
	property.interaction_ended.connect(func(value, previous): interaction_ended.emit(value, previous))

	delete_button = NodeUtils.get_node_or_add(self, "Delete", Button, NodeUtils.INTERNAL)
	delete_button.icon = preload("res://assets/textures/icons/godot/Remove.svg")
	delete_button.custom_minimum_size.x = 24.0
	delete_button.expand_icon = true
	delete_button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	delete_button.pressed.connect(remove_self)

	renamed.connect(refresh)


func remove_self() -> void:
	var parent_container := get_parent() as ReorderableContainer
	var is_being_reordered := parent_container._focus_child and parent_container._focus_child.z_index == 1
	if is_being_reordered:
		return
	var parent_property := parent_container.get_meta("array_property") as ArrayProperty
	parent_property.remove_item(get_index())


func refresh() -> void:
	property.name = name


func set_value(value: Variant) -> void:
	property.set_value(value)
	value_changed.emit(value)


func set_value_no_signal(value: Variant) -> void:
	property.set_value_no_signal(value)


func get_value() -> Variant:
	return property.get_value()


func reset() -> void:
	pass # unimplemented


func set_input_state(enabled: bool) -> void:
	delete_button.disabled = not enabled
	property.set_input_state(enabled)
