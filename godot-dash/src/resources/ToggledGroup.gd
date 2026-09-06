@tool
class_name ToggledGroup
extends Resource

enum ToggleState {
	ON,
	OFF,
	FLIP,
}

@export var group: StringName
@export var state: ToggleState


func _to_string() -> String:
	return "ToggledGroup { group: %s, state: %s }" % [group, state]


func to_data() -> Dictionary:
	return {
		"group": group,
		"state": state,
	}


static func from_data(data: Dictionary) -> ToggledGroup:
	var toggled_group := ToggledGroup.new()
	toggled_group.group = data.group
	toggled_group.state = data.state
	return toggled_group
