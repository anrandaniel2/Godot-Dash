@abstract
class_name Deserialize
## Deserialization functions for builtin types.

## Deserialize a [Transform2D] from data produced by [method Serialize.Transform2D].
static func Transform2D(data: Dictionary) -> Transform2D:
	return Transform2D(
		Deserialize.Vector2(data.x),
		Deserialize.Vector2(data.y),
		Deserialize.Vector2(data.origin),
	)


## Deserialize a [Vector2] from data produced by [method Serialize.Vector2].
static func Vector2(data: Array) -> Vector2:
	return Vector2(
		data[0],
		data[1],
	)


static func Node(path: NodePath) -> Node:
	return LevelManager.current_level.get_node_or_null(path)


## Resolves an array of saved [NodePath]s, dropping any that no longer point at
## a live node.
##
## Saved paths go stale legitimately: imported decoration is drawn in batches
## rather than as individual nodes, so paths recorded against those objects
## resolve to nothing. Letting the nulls through puts them into typed arrays
## like [code]Array[HSVWatcher][/code], where the first property access fails.
static func Nodes(paths: Array) -> Array:
	var result: Array = []
	for path: Variant in paths:
		var node: Node = Deserialize.Node(path)
		if node != null:
			result.append(node)
	return result


## Like [method DictUtils.map_keys] with [method Deserialize.Node], but entries
## whose key no longer resolves are dropped instead of being keyed on null.
static func NodeKeyedDict(data: Dictionary) -> Dictionary:
	var result: Dictionary = { }
	for path: Variant in data:
		var node: Node = Deserialize.Node(path)
		if node != null:
			result[node] = data[path]
	return result
