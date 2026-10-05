class_name RandomTriggerComponent
extends Component
## Random (1912) and Advanced Random (2068) triggers: spawns one of
## [member groups], picked with the matching [member weights]. An empty group
## is a roll that spawns nothing. Twin of the native RANDOM arm
## (native/src/gdash_native.cpp, pick_weighted). Keys from gmdkit
## data/csv/prop_table.csv: 1912 key 10 chance %, key 51 on a hit, key 71
## otherwise; 2068 key 152 "group.weight" pairs.

@export var groups: PackedStringArray = PackedStringArray()
@export var weights: PackedFloat64Array = PackedFloat64Array()


func _ready() -> void:
	parent.interacted.connect(_on_interacted)


## Index whose cumulative weight first exceeds [param roll] * total, or -1.
static func pick_weighted(entry_weights: PackedFloat64Array, roll: float) -> int:
	var total: float = 0.0
	for weight: float in entry_weights:
		total += maxf(0.0, weight)
	if total <= 0.0:
		return -1
	var target: float = roll * total
	var running: float = 0.0
	for index: int in entry_weights.size():
		var weight: float = maxf(0.0, entry_weights[index])
		if weight <= 0.0:
			continue
		running += weight
		if target < running:
			return index
	for index: int in range(entry_weights.size() - 1, -1, -1):
		if entry_weights[index] > 0.0:
			return index
	return -1


func _on_interacted(player: Player = null) -> void:
	var picked: int = pick_weighted(weights, randf())
	if picked < 0 or picked >= groups.size() or groups[picked].is_empty():
		return
	for node: Node in get_tree().get_nodes_in_group(StringName(Constants.GROUP_PREFIX + groups[picked])):
		if node.has_signal(&"interacted"):
			node.interacted.emit(player)
