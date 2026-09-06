class_name AddKeybindButton
extends Button

var remapping: bool = false
var keybind_loader: KeybindLoader


func _init(_keybind_loader: KeybindLoader) -> void:
	keybind_loader = _keybind_loader


func _ready() -> void:
	text = "Add"
	pressed.connect(_on_button_pressed)


func _on_button_pressed() -> void:
	text = "Press Any Key"
	remapping = true
	Editor.shortcut_blocker = self


func _input(event: InputEvent) -> void:
	if remapping && event is not InputEventJoypadMotion && event is not InputEventMouseMotion:
		# Support keybinds with modifiers
		if event is InputEventKey and (event.keycode == KEY_SHIFT or event.keycode == KEY_CTRL or event.keycode == KEY_ALT):
			return
		InputMap.action_add_event(keybind_loader.input_action, event)
		Config.input_map.set(keybind_loader.input_action, InputMap.action_get_events(keybind_loader.input_action))
		Config.save()
		keybind_loader.refresh_inputs()
