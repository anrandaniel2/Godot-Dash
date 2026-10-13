extends RefCounted
## Rejected mutable-list candidate, retained only for reproducible A/B evidence.
## It preserved indices but measured slower than the existing packed-array path
## on Windows Godot 4.7.2. It is NOT used by the shipped game.


static func append(lists: Dictionary, key: StringName, index: int) -> void:
	if not lists.has(key):
		lists[key] = []
	(lists[key] as Array).append(index)


static func finish(lists: Dictionary) -> Dictionary[StringName, PackedInt32Array]:
	var packed: Dictionary[StringName, PackedInt32Array] = {}
	for key: StringName in lists:
		packed[key] = PackedInt32Array(lists[key])
	return packed
