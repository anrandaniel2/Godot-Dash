class_name RemoveKeybindButton
extends Button

var keybind_loader: KeybindLoader
var input_event: InputEvent


func _init(_keybind_loader: KeybindLoader, _input_event: InputEvent) -> void:
	keybind_loader = _keybind_loader
	input_event = _input_event


func _ready() -> void:
	icon = preload("res://assets/textures/icons/godot/Remove.svg")
	icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pressed.connect(_on_button_pressed)
	expand_icon = true
	# Set `custom_minimum_size` the next frame, after the layout is solved
	# and `size` is set.
	await get_tree().process_frame
	custom_minimum_size = Vector2.ONE * get_parent().size.y


func _on_button_pressed() -> void:
	InputMap.action_erase_event(keybind_loader.input_action, input_event)
	Config.input_map.set(keybind_loader.input_action, InputMap.action_get_events(keybind_loader.input_action))
	Config.save()
	keybind_loader.refresh_inputs()
