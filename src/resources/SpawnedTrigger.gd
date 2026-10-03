class_name SpawnedTrigger
extends Resource

@export var path: NodePath:
	set(value):
		path = value
		emit_changed()
@export_range(0.0, 1.0, 0.01, "suffix:s") var time: float

var loop_idx: int = 0


func _to_string() -> String:
	return "SpawnedTrigger { path: %s, time: %s }" % [path, time]


func to_data() -> Dictionary:
	var data: Dictionary
	data.path = path
	data.time = time
	return data


static func from_data(data: Dictionary) -> SpawnedTrigger:
	var spawned_trigger := SpawnedTrigger.new()
	spawned_trigger.path = data.path
	spawned_trigger.time = data.time
	return spawned_trigger
