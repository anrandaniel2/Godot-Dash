class_name DecorationPicker
extends RefCounted
## Index for editor picking of decoration selection boxes.
##
## Each entry is an oriented rectangle in world space (four corners). Queries
## are exact: a circle (the cursor) or an axis-aligned rectangle (the swipe or
## box selection) matches when it overlaps the box. That is the same overlap
## the physics selection colliders produced, so the result set is identical.
## Entries are bucketed into a uniform grid so a query only tests the boxes in
## the cells it touches.

const CELL_SIZE: float = 256.0
const EPSILON: float = 0.001

var _items: Array = []
var _quads: Array[PackedVector2Array] = []
var _bounds: Array[Rect2] = []
var _cells: Dictionary = { }  # Vector2i -> PackedInt32Array of entry indices


## Clears every entry.
func clear() -> void:
	_items.clear()
	_quads.clear()
	_bounds.clear()
	_cells.clear()


## Number of entries.
func size() -> int:
	return _items.size()


## Adds [param item] (any payload, returned by queries) with its world-space
## corners [param quad].
func add(item: Variant, quad: PackedVector2Array) -> void:
	var index := _items.size()
	var bounds := _aabb(quad)
	_items.append(item)
	_quads.append(quad)
	_bounds.append(bounds)
	var first := _cell(bounds.position)
	var last := _cell(bounds.end)
	for x in range(first.x, last.x + 1):
		for y in range(first.y, last.y + 1):
			var key := Vector2i(x, y)
			var list: PackedInt32Array = _cells.get(key, PackedInt32Array())
			list.append(index)
			_cells[key] = list


## World-space corners of [param rect] under [param xform].
static func quad_of(xform: Transform2D, rect: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		xform * rect.position,
		xform * Vector2(rect.end.x, rect.position.y),
		xform * rect.end,
		xform * Vector2(rect.position.x, rect.end.y),
	])


## Payloads whose box overlaps the circle at [param center] with [param radius],
## in insertion order.
func query_circle(center: Vector2, radius: float) -> Array:
	var area := Rect2(center - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)
	return _query(area, func(index: int) -> bool: return _circle_hits(_quads[index], center, radius))


## Payloads whose box overlaps [param rect], in insertion order.
func query_rect(rect: Rect2) -> Array:
	return _query(rect, func(index: int) -> bool: return _rect_hits(_quads[index], rect))


func _query(area: Rect2, test: Callable) -> Array:
	var candidates := { }
	var first := _cell(area.position)
	var last := _cell(area.end)
	for x in range(first.x, last.x + 1):
		for y in range(first.y, last.y + 1):
			for index: int in _cells.get(Vector2i(x, y), PackedInt32Array()):
				candidates[index] = true
	var ordered: Array = candidates.keys()
	ordered.sort()
	var hits: Array = []
	for index: int in ordered:
		if _bounds[index].grow(EPSILON).intersects(area) and test.call(index):
			hits.append(_items[index])
	return hits


func _cell(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / CELL_SIZE), floori(point.y / CELL_SIZE))


static func _aabb(quad: PackedVector2Array) -> Rect2:
	var low := quad[0]
	var high := quad[0]
	for corner in quad:
		low = low.min(corner)
		high = high.max(corner)
	return Rect2(low, high - low)


## Circle against a convex quad: the centre is inside, or within the radius of
## one of the four edges.
static func _circle_hits(quad: PackedVector2Array, center: Vector2, radius: float) -> bool:
	var inside_positive := true
	var inside_negative := true
	for i in 4:
		var a := quad[i]
		var b := quad[(i + 1) % 4]
		var edge := b - a
		var side := edge.cross(center - a)
		if side < 0.0:
			inside_positive = false
		if side > 0.0:
			inside_negative = false
		var length_squared := edge.length_squared()
		var t := 0.0 if length_squared <= 0.0 else clampf((center - a).dot(edge) / length_squared, 0.0, 1.0)
		if (a + edge * t).distance_squared_to(center) <= radius * radius + EPSILON:
			return true
	return inside_positive or inside_negative


## Axis-aligned rectangle against a convex quad, by separating axis test over
## the rectangle's axes and the quad's edge normals.
static func _rect_hits(quad: PackedVector2Array, rect: Rect2) -> bool:
	var rect_corners := PackedVector2Array([
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	])
	var axes: Array[Vector2] = [Vector2.RIGHT, Vector2.DOWN]
	for i in 4:
		var normal := (quad[(i + 1) % 4] - quad[i]).orthogonal()
		if normal.length_squared() > 0.0:
			axes.append(normal.normalized())
	for axis in axes:
		var a_low := INF
		var a_high := -INF
		var b_low := INF
		var b_high := -INF
		for corner in rect_corners:
			var p := corner.dot(axis)
			a_low = minf(a_low, p)
			a_high = maxf(a_high, p)
		for corner in quad:
			var p := corner.dot(axis)
			b_low = minf(b_low, p)
			b_high = maxf(b_high, p)
		if a_high < b_low - EPSILON or b_high < a_low - EPSILON:
			return false
	return true
