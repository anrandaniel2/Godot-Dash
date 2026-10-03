extends Node

func _ready() -> void:
	if Config.input_map.is_empty():
		for action in InputMap.get_actions():
			Config.input_map.set(action, InputMap.action_get_events(action))
			Config.save()
	else:
		for action in Config.input_map:
			InputMap.action_erase_events(action)
			var events = Config.input_map[action]
			for event in events:
				InputMap.action_add_event(action, event)
