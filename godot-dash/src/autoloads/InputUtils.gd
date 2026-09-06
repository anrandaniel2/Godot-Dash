extends Node
## Tracks the pressed / just-pressed / just-released state of registered input actions.
##
## Pure GDScript port of the singleton that used to live in the `godot-rust-utils` GDExtension.
## Call [method update] once per (physics) frame to refresh the tracked state.
##
## Note: the Rust implementation could additionally poll raw OS input through libinput (Linux) or
## device_query (Windows) for the "click on steps" feature, i.e. keep reading the keyboard and
## mouse while the window was not focused. That required native code; this implementation always
## reads the engine's [Input] state instead (the same behaviour the extension had when
## `Config.is_click_on_steps_enabled()` was false), so the [code]click_on_steps[/code] setting no
## longer has an effect.

var _actions: Dictionary = {} # StringName -> { "pressed": bool, "just_pressed": bool, "just_released": bool }


## Starts tracking [param action]. Does nothing if it is already tracked.
func add_action(action: StringName) -> void:
	if _actions.has(action):
		return
	_actions[action] = {
		"pressed": false,
		"just_pressed": false,
		"just_released": false,
	}


## Stops tracking [param action]. Does nothing if it is not tracked.
func remove_action(action: StringName) -> void:
	_actions.erase(action)


## Refreshes the tracked state of every registered action from the [Input] singleton.
func update() -> void:
	for action: StringName in _actions:
		var action_data: Dictionary = _actions[action]
		action_data.pressed = Input.is_action_pressed(action)
		action_data.just_pressed = Input.is_action_just_pressed(action)
		action_data.just_released = Input.is_action_just_released(action)


## Whether the last [method update] reported [param action] as pressed.
func is_action_pressed(action: StringName) -> bool:
	return _get_action_data(action).pressed


## Whether the last [method update] reported [param action] as just pressed.
func is_action_just_pressed(action: StringName) -> bool:
	return _get_action_data(action).just_pressed


## Whether the last [method update] reported [param action] as just released.
func is_action_just_released(action: StringName) -> bool:
	return _get_action_data(action).just_released


## Returns [code]1.0[/code] if [param positive_action] is pressed, [code]-1.0[/code] if
## [param negative_action] is pressed, or [code]0.0[/code] if neither or both are pressed.
func get_axis(negative_action: StringName, positive_action: StringName) -> float:
	var value := 0.0
	if is_action_pressed(negative_action):
		value -= 1.0
	if is_action_pressed(positive_action):
		value += 1.0
	return value


func _get_action_data(action: StringName) -> Dictionary:
	assert(_actions.has(action), "tried to query unregistered action %s" % action)
	return _actions[action]
