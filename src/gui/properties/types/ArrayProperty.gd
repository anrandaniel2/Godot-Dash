@tool
class_name ArrayProperty
extends Property

signal value_changed(value: Array)
signal interaction_ended(value: Array, previous: Array)

const NO_SIGNAL: int = 1

@export var default_size: int
@export var minimum_size: int = 0
@export var maximum_size: int = 10
@export var or_greater: bool
@export var item_template: PackedScene
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var add: Button
var items: ReorderableVBox
var item_panel: PanelContainer


func _ready() -> void:
	if _value is not Array:
		_value = []
	vertical = true
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	item_panel = NodeUtils.get_node_or_add(self, "PanelContainer", PanelContainer, NodeUtils.INTERNAL)
	var margin_container: MarginContainer = NodeUtils.get_node_or_add(item_panel, "MarginContainer", MarginContainer, NodeUtils.INTERNAL)
	var vbox: VBoxContainer = NodeUtils.get_node_or_add(margin_container, "VBoxContainer", VBoxContainer, NodeUtils.INTERNAL)
	items = NodeUtils.get_node_or_add(vbox, "Items", ReorderableVBox, NodeUtils.INTERNAL)
	items.hold_duration = 0.2
	items.set_meta("array_property", self)
	items.reordered.connect(refresh_item_names)
	add = NodeUtils.get_node_or_add(vbox, "Add", Button, NodeUtils.INTERNAL)
	add.icon = preload("res://assets/textures/icons/godot/Add.svg")
	add.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add.custom_minimum_size.x = custom_minimum_size.y
	add.pressed.connect(add_item.bind(-1))
	renamed.connect(refresh)
	refresh()


func refresh_item_names(from: int, to: int) -> void:
	if _value.size() <= 1:
		return
	_value.insert(to, _value.pop_at(from))
	# Avoid duplicate names (e.g. <idx>2)
	# I'm forced to apply a unique name to every item first,
	# and then put the actual index as the name, because
	# I can't find a universal way of doing it in one pass
	# without having duplicate names at an iteration.
	for item in items.get_children():
		item.name = str(hash(item))
	for item in items.get_children():
		item.name = str(item.get_index())


func refresh() -> void:
	label.text = name
	var array_size = items.get_child_count() if not Engine.is_editor_hint() else default_size
	array_size = maxi(array_size, minimum_size)
	if not or_greater:
		array_size = mini(array_size, maximum_size)
	# Substractive
	if items.get_child_count() > array_size:
		for i in range(array_size, items.get_child_count()):
			items.get_child(i).queue_free()
		if array_size <= 0:
			items.hide()
		return
	# Additive
	for i in range(array_size):
		if items.get_child(i) != null:
			continue
		add_item(i)
	items.visible = array_size > 0
	items.reorder_disabled = array_size <= 1


func add_item(idx: int, options: int = 0) -> ArrayPropertyItem:
	if _value.size() + 1 > maximum_size and not or_greater:
		return
	var item = ArrayPropertyItem.new(item_template.instantiate())
	item.property.show()
	item.value_changed.connect(
		func(value):
			_value = _value.duplicate()
			_value[item.get_index()] = value
			value_changed.emit(_value.duplicate())
	)
	item.interaction_ended.connect(
		func(value, previous):
			var _previous: Array = _value.duplicate()
			_value = _value.duplicate()
			_value[item.get_index()] = value
			_previous[item.get_index()] = previous
			interaction_ended.emit(_value, _previous)
	)
	item.name = str(idx if idx >= 0 else items.get_child_count())
	items.add_child(item)
	var previous_value: Array = _value.duplicate()
	if idx > 0:
		_value.insert(idx, item.get_value())
	else:
		_value.append(item.get_value())
	if not options & NO_SIGNAL:
		value_changed.emit(_value.duplicate())
		interaction_ended.emit(_value.duplicate(), previous_value)
	items.show()
	items.reorder_disabled = _value.size() <= 1
	return item


func remove_item(idx: int, options: int = 0) -> void:
	if items.get_child_count() - 1 < minimum_size:
		return
	for i in range(idx, items.get_child_count()):
		var item = items.get_child(i)
		# There is an issue where if we use `str(i - 1)` directly as the name,
		# the item doesn't get renamed correctly.
		# HACK: Adding a suffix fixes the renaming issue for some reason.
		# I'm using U+200B to avoid making the label wider.
		# Removing the suffix afterwards doesn't introduce the issue back.
		item.name = (str(i - 1) + "​").trim_prefix("​")
	items.get_child(idx).queue_free()
	var _previous_value: Array = _value.duplicate()
	_value.remove_at(idx)
	if not options & NO_SIGNAL:
		value_changed.emit(_value.duplicate())
		interaction_ended.emit(_value.duplicate(), _previous_value)
	if _value.size() == 0:
		items.hide()
	items.reorder_disabled = _value.size() <= 1


func set_value(value: Array) -> void:
	var _previous_value: Array = _value.duplicate()
	set_value_no_signal(value)
	value_changed.emit(_value)
	interaction_ended.emit(_value.duplicate(), _previous_value)


func set_value_no_signal(value: Array) -> void:
	var new_value = value.duplicate()
	NodeUtils.free_children(items)
	_value = []
	if new_value.size() < minimum_size:
		for i in range(minimum_size):
			add_item(i, NO_SIGNAL)
	if new_value.size() > maximum_size and not or_greater:
		new_value.resize(maximum_size)
	for i in (new_value.size() if new_value.size() >= minimum_size else maxi(new_value.size() - minimum_size, 0)):
		add_item(i, NO_SIGNAL).set_value_no_signal(new_value[i])
	_value = new_value
	items.visible = _value.size() > 0


func get_value() -> Array:
	return _value.duplicate()


func reset() -> void:
	pass # unimplemented, there is no easy way to change the type of an inspector typed array


func set_input_state(enabled: bool) -> void:
	add.disabled = not enabled
	items.get_children().map(func(item): item.set_input_state(enabled))
