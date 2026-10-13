class_name PackedIndexBuilder
extends RefCounted
## Accumulate mutable lists before freezing them for native calls. Retrieving a
## PackedInt32Array from a Dictionary and appending clones the shared buffer on
## every insert, making a channel with N sprites copy O(N squared) integers.


static func append(lists: Dictionary, key: StringName, index: int) -> void:
	if not lists.has(key):
		lists[key] = []
	(lists[key] as Array).append(index)


static func finish(lists: Dictionary) -> Dictionary[StringName, PackedInt32Array]:
	var packed: Dictionary[StringName, PackedInt32Array] = {}
	for key: StringName in lists:
		packed[key] = PackedInt32Array(lists[key])
	return packed
