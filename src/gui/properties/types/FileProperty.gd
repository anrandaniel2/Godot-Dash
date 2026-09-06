@tool
class_name FileProperty
extends Property

signal value_changed(value: String)
signal interaction_ended(value: String, previous: String)

@export var default: String
@export var filetype_filters: PackedStringArray
@export var load_root: String
@export var import_to: String
@warning_ignore("unused_private_class_variable")
@export_tool_button("Refresh") var _refresh = refresh

var input: MenuButton


func _ready() -> void:
	label = NodeUtils.get_node_or_add(self, "Label", Label, NodeUtils.INTERNAL)
	input = NodeUtils.get_node_or_add(self, "Input", MenuButton, NodeUtils.INTERNAL)
	input.flat = false
	var popup := input.get_popup() as PopupMenu
	popup.clear()
	popup.add_item("Load")
	popup.add_item("Import and load")
	popup.index_pressed.connect(_on_input_pressed)
	renamed.connect(refresh)
	refresh()
	if _value == null or _value == "":
		set_value_no_signal("")
	NodeUtils \
			.get_node_or_add(self, "PropertyReset", PropertyReset, NodeUtils.INTERNAL) \
			.set_input(input)


func set_value(new_value: String) -> void:
	var previous: String = _value
	set_value_no_signal(new_value)
	value_changed.emit(_value)
	interaction_ended.emit(_value, previous)


func set_value_no_signal(new_value: String) -> void:
	_value = default if new_value.is_empty() else new_value
	if new_value.is_empty() or Engine.is_editor_hint():
		input.text = "    Load…    " if default.is_empty() else default.get_file()
	else:
		input.text = new_value.get_file()


func get_value() -> String:
	return _value


func reset() -> void:
	set_value("")


func refresh() -> void:
	label.text = name
	input.custom_minimum_size.y = MIN_HEIGHT
	if Engine.is_editor_hint():
		reset()


func set_input_state(enabled: bool) -> void:
	input.disabled = not enabled


func _on_input_pressed(index: int) -> void:
	var file_path: String
	match index:
		0: # Load
			Files.load(filetype_filters, load_root)
		1: # Import and load
			Files.import_and_load(filetype_filters, "", import_to, Files.SINGLE_FILE)
	file_path = await Files.file_loaded
	if not file_path.is_empty():
		set_value(file_path)
