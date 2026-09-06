class_name Selection
extends RefCounted
## A wrapper type for an ordered set. Works like an [Array] of [Node2D]s but all objects are
## unique.
##
## Pure GDScript port of the class that used to live in the `godot-rust-utils` GDExtension.

var _objects: Array[Node2D] = []


func _init(objects: Array[Node2D] = []) -> void:
	for object: Node2D in objects:
		insert(object)


func _to_string() -> String:
	return "Selection " + str(_objects)


## Empty [Selection] constant.
static func EMPTY() -> Selection:
	return Selection.new()


## Creates a [Selection] and fills it with the array's objects.
static func from_array(array: Array[Node2D]) -> Selection:
	return Selection.new(array)


## Creates a [Selection] containing this [Node2D].
## Shorthand for
## [codeblock]
## var selection := Selection.new()
## selection.insert(object)
## [/codeblock]
static func from_object(object: Node2D) -> Selection:
	var selection := Selection.new()
	selection.insert(object)
	return selection


## Creates a typed [Array] of [Node2D]s with the objects of the selection.
func to_array() -> Array[Node2D]:
	return _objects.duplicate()


## Returns the number of objects in this selection.
func size() -> int:
	return _objects.size()


## Creates a new [Selection] with elements that are in [code]self[/code] [b]or[/b] in [code]other[/code].
func union(other: Selection) -> Selection:
	var result := Selection.new(_objects)
	for object: Node2D in other.to_array():
		result.insert(object)
	return result


## Creates a new [Selection] with elements that are in [code]self[/code] [b]and[/b] in [code]other[/code].
func intersection(other: Selection) -> Selection:
	var result := Selection.new()
	for object: Node2D in _objects:
		if other.contains(object):
			result.insert(object)
	return result


## Creates a new [Selection] with elements that are in [code]self[/code] [b]and not[/b] in
## [code]other[/code].
func difference(other: Selection) -> Selection:
	var result := Selection.new()
	for object: Node2D in _objects:
		if not other.contains(object):
			result.insert(object)
	return result


## Adds an element to the selection.
func insert(object: Node2D) -> void:
	if not _objects.has(object):
		_objects.append(object)


## Checks if an element exists in the selection.
func contains(object: Node2D) -> bool:
	return _objects.has(object)


## Removes an element from the selection.
## Returns whether the element was present in the selection.
func remove(object: Node2D) -> bool:
	var index := _objects.find(object)
	if index == -1:
		return false
	_objects.remove_at(index)
	return true


## Returns the first element of the selection, or [code]null[/code] if there is none.
func first() -> Node2D:
	if _objects.is_empty():
		return null
	return _objects[0]


## Removes all elements from the selection.
func clear() -> void:
	_objects.clear()


## Creates a copy of the selection. The elements are unchanged.
func clone() -> Selection:
	return Selection.new(to_array())


## See [method Array.is_empty].
func is_empty() -> bool:
	return _objects.is_empty()


## Compares two [Selection]s. Returns [code]true[/code] if the selections have the same elements.
func is_identical(other: Selection) -> bool:
	if size() != other.size():
		return false
	for object: Node2D in _objects:
		if not other.contains(object):
			return false
	return true


## Compares two [Selection]s.
## Returns [code]true[/code] if the set is a superset of another,
## i.e., [code]self[/code] contains at least all the values in [code]other[/code].
func is_superset(other: Selection) -> bool:
	for object: Node2D in other.to_array():
		if not contains(object):
			return false
	return true


## Compares two [Selection]s.
## Returns [code]true[/code] if the set is a subset of another,
## i.e., [code]other[/code] contains at least all the values in [code]self[/code].
func is_subset(other: Selection) -> bool:
	for object: Node2D in _objects:
		if not other.contains(object):
			return false
	return true


## See [method Array.all].
func all(method: Callable) -> bool:
	for object: Node2D in _objects:
		if not _to_bool(method.call(object)):
			return false
	return true


## See [method Array.any].
func any(method: Callable) -> bool:
	for object: Node2D in _objects:
		if _to_bool(method.call(object)):
			return true
	return false


## Like [method Selection.map_generic], but returns another [Selection], which
## implies [param method] returns a [Node2D].
##
## Maps every object through [param method], collecting the results.
##
## Entries that map to nothing are skipped rather than aborting the whole
## selection: cloning an object can legitimately produce null (imported
## decoration whose artwork is unavailable), and losing one object should not
## turn a duplicate or paste of fifty into a hard failure.
func map(method: Callable) -> Selection:
	var result := Selection.new()
	for object: Node2D in _objects:
		var mapped: Variant = method.call(object)
		if mapped is Node2D:
			result.insert(mapped)
	return result


## Like [method Selection.map_generic], but returns another [Selection].
## This implies [code]method[/code] needs to return a [Node2D].
## If the return type is anything else or the value is [code]null[/code], it won't be included.
func flat_map(method: Callable) -> Selection:
	var result := Selection.new()
	for object: Node2D in _objects:
		var mapped: Variant = method.call(object)
		if mapped is Node2D:
			result.insert(mapped)
	return result


## See [method Array.map].
func map_generic(method: Callable) -> Array:
	var result: Array = []
	for object: Node2D in _objects:
		result.append(method.call(object))
	return result


## Like [method Selection.map_generic], but it produces a [Dictionary] with,
## for each element, keys and values being [code]element[/code] and [code]method.call(element)[/code].
func map_generic_dict(method: Callable) -> Dictionary[Node2D, Variant]:
	var result: Dictionary[Node2D, Variant] = {}
	for object: Node2D in _objects:
		result[object] = method.call(object)
	return result


## See [method Array.filter].
## Produces a new [Selection] with elements where [code]method.call(element)[/code] returns [code]true[/code].
func filter(method: Callable) -> Selection:
	var result := Selection.new()
	for object: Node2D in _objects:
		if method.call(object):
			result.insert(object)
	return result


## See [method Array.reduce].
func fold_generic(method: Callable, accum: Variant) -> Variant:
	for object: Node2D in _objects:
		accum = method.call(accum, object)
	return accum


## Runs [code]method[/code] on each element in the selection.
func for_each(method: Callable, reverse: bool = false) -> void:
	var objects := to_array()
	if reverse:
		objects.reverse()
	for object: Node2D in objects:
		method.call(object)


# Mirrors the relaxed Variant -> bool conversion used by the Rust implementation:
# anything that fails to convert counts as false.
static func _to_bool(value: Variant) -> bool:
	if value is bool:
		return value
	if value is float or value is int:
		return value != 0
	if value is String or value is StringName:
		return not str(value).is_empty()
	if value is Array or value is Dictionary:
		return not value.is_empty()
	if value is Object:
		return value != null
	return false
