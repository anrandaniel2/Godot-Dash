@tool
class_name EnumButton
extends PanelContainer

signal value_changed(variant_index: int)
signal interaction_ended(new_variant: int, previous_variant: int)

@export var default: int
@export var variants: PackedStringArray
@export var icons: Array[Texture2D]
@export var vertical: bool = false
@export var as_tab_container: bool = false
@warning_ignore("unused_private_class_variable")
@export_tool_button("Update") var _update = update

var box_container: BoxContainer
var button_group: ButtonGroup
var previous_enabled_button_index: int
var is_clicked: bool


func _ready() -> void:
	box_container = BoxContainer.new()
	box_container.alignment = BoxContainer.ALIGNMENT_CENTER
	box_container.add_theme_constant_override(&"separation", 0)
	add_child(box_container)
	button_group = ButtonGroup.new()
	clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	update()


func _input(event: InputEvent) -> void:
	if not as_tab_container:
		return
	if (event is InputEventMouseButton and event.get_button_index() == MOUSE_BUTTON_LEFT) or (event is InputEventScreenTouch):
		is_clicked = event.is_pressed() and get_rect().has_point(get_local_mouse_position())
	if is_clicked and get_rect().has_point(get_local_mouse_position()):
		var buttons: Array[BaseButton] = button_group.get_buttons()
		for button in buttons:
			if not button.is_visible_in_tree():
				continue
			button.button_pressed = button.is_hovered()


func update() -> void:
	theme_type_variation = &"ClipMaskPanel" if not as_tab_container else &"RoundedEnumButton"
	custom_minimum_size.y = 0.0 if not as_tab_container else 36.0
	box_container.vertical = vertical
	if box_container.get_child_count() > 0:
		NodeUtils.free_children(box_container)
		await get_tree().process_frame
	variants.resize(maxi(variants.size(), icons.size()))
	icons.resize(maxi(variants.size(), icons.size()))
	for i: int in variants.size():
		var enum_variant: String = variants[i]
		var icon: Texture2D = icons[i]
		var button: Button = Button.new()
		button.theme_type_variation = &"OneLineEnumButton"
		button.text = enum_variant
		button.icon = icon
		button.expand_icon = true
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.toggle_mode = true
		button.button_group = button_group
		button.custom_minimum_size = Vector2.ONE * custom_minimum_size.y
		button.toggled.connect(
			func(toggled_on: bool):
				if not toggled_on:
					previous_enabled_button_index = i
					# Avoid emitting `value_changed` for the button that gets toggled off
					return
				if previous_enabled_button_index != i:
					value_changed.emit(i)
					interaction_ended.emit(i, previous_enabled_button_index)
		)
		if i == default:
			button.set_pressed(true)
		box_container.add_child(button)


func set_value(variant_index: int) -> void:
	assert(variant_index < box_container.get_child_count(), "IndexError: variant index is out of range")
	var previous: int = get_value()
	value_changed.emit(variant_index)
	interaction_ended.emit(variant_index, previous)
	# Avoid infinite recursion by triggering `set_value` again
	box_container.get_child(previous).set_pressed_no_signal(false)
	box_container.get_child(variant_index).set_pressed_no_signal(true)


func set_value_no_signal(variant_index: int) -> void:
	assert(variant_index < box_container.get_child_count(), "IndexError: variant index is out of range")
	var previous: int = get_value()
	# Avoid infinite recursion by triggering `set_value` again
	box_container.get_child(previous).set_pressed_no_signal(false)
	box_container.get_child(variant_index).set_pressed_no_signal(true)


func get_value() -> int:
	return button_group.get_pressed_button().get_index()


func set_input_state(enabled: bool) -> void:
	for button: Button in box_container.get_children():
		button.disabled = not enabled


func hide_tab(idx: int) -> void:
	box_container.get_child(idx).hide()


func show_tab(idx: int) -> void:
	box_container.get_child(idx).show()


func get_tab_visibility(idx: int) -> bool:
	return box_container.get_child(idx).visible


func set_tab_visibility(idx: int, visibility: bool) -> void:
	box_container.get_child(idx).visible = visibility
