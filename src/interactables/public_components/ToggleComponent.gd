class_name ToggleComponent
extends Component

signal send_to_group_display(group_name: String)

@export var toggled_groups: Array[ToggledGroup]:
	set(value):
		toggled_groups = value
		update_group_display()

@export_storage var used_times: int = 0


func _ready() -> void:
	parent.interacted.connect(toggle)


func toggle(_player: Player = null) -> void:
	for toggled_group in toggled_groups:
		var group = Constants.GROUP_PREFIX + toggled_group.group
		var state = toggled_group.state
		var enable := func(object):
			object.show()
			object.process_mode = PROCESS_MODE_INHERIT
		var disable := func(object):
			object.hide()
			object.process_mode = PROCESS_MODE_DISABLED
		var objects_in_group := get_tree().get_nodes_in_group(group)
		if state == ToggledGroup.ToggleState.ON:
			objects_in_group.map(enable)
		elif state == ToggledGroup.ToggleState.OFF:
			objects_in_group.map(disable)
		elif state == ToggledGroup.ToggleState.FLIP:
			for object in objects_in_group:
				if object.process_mode == PROCESS_MODE_INHERIT: # If it is toggled on
					object.set_deferred(&"process_mode", PROCESS_MODE_DISABLED)
					object.hide()
				elif object.process_mode == PROCESS_MODE_DISABLED: # If it is toggled off
					object.set_deferred(&"process_mode", PROCESS_MODE_INHERIT)
					object.show()
	used_times += 1


func _field_to_data(field_name: String, reason: Serialize.Reason) -> Variant:
	match field_name:
		"toggled_groups":
			return toggled_groups.map(func(toggled_group: ToggledGroup): return toggled_group.to_data())
		"used_times":
			if reason != Serialize.Reason.PRACTICE:
				return null
			return used_times
		_:
			return get(field_name)


func _field_from_data(field_name: String, field_data: Variant) -> void:
	match field_name:
		"toggled_groups":
			toggled_groups.assign(field_data.map(func(toggled_group_data: Dictionary): return ToggledGroup.from_data(toggled_group_data)))
			update_group_display()
		"used_times":
			used_times = field_data
			if used_times % 2 == 1:
				toggle.call_deferred()
		_:
			set(field_name, field_data)


func update_group_display() -> void:
	if toggled_groups.size() == 1:
		send_to_group_display.emit(toggled_groups[0].group)
	else:
		send_to_group_display.emit("")
