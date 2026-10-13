extends Node
## Verifies that [DecorationPicker] returns exactly the selection boxes that the
## physics overlap returns, on a real level in the editor. Grep "PICK_CHECK".
##   GDASH_MEM_LEVEL=/path/level.gmd  (any .gmd, e.g. the Change of Scene level)

const _SAVE_PATH := "user://picking_check.gmd"
const _POINT_QUERIES := 3000
const _RECT_QUERIES := 600
const _SEED := 20261013
## Physics selection collider is layer 256; the placed-objects collider and the
## selection zone both scan mask 264 (see EditorScene.tscn).
const _SCAN_MASK := 264


var _start_ms := 0


func _log(message: String) -> void:
	print("PICK_CHECK +%.1fs %s" % [(Time.get_ticks_msec() - _start_ms) / 1000.0, message])


func _ready() -> void:
	_start_ms = Time.get_ticks_msec()
	var path := OS.get_environment("GDASH_MEM_LEVEL")
	var document: GMD.Document = GMD.read_any_file(path)
	if document == null or document.level_string.is_empty():
		print("PICK_CHECK error: could not read %s" % path)
		get_tree().quit(1)
		return
	var data := GMDConverter.import_online_level_string(document.level_string, "PickCheck", GMDConverter.ImportReport.new())
	document = null
	LevelOperationsHandler.write_level_and_meta(_SAVE_PATH, data)
	var loaded := LevelOperationsHandler.load_level_data_from_path(_SAVE_PATH)
	_log("level loaded")
	Editor.level_data_snapshot = loaded
	var editor_scene: Node = (load("res://scenes/EditorScene.tscn") as PackedScene).instantiate()
	add_child(editor_scene)
	for frame in 60:
		await get_tree().process_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	_log("editor scene ready")
	_check(editor_scene)
	get_tree().quit(0)


func _check(editor_scene: Node) -> void:
	var selectors: Dictionary = { }  # GDObject instance id -> selector Area2D
	var picker := DecorationPicker.new()
	var centres: Array[Vector2] = []
	var stack: Array[Node] = [editor_scene]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is GDObject and node.has_node(^"EditorSelectionCollider"):
			var selector: Area2D = node.get_node(^"EditorSelectionCollider")
			var hitbox: CollisionShape2D = selector.get_node_or_null(^"EditorSelectionHitbox")
			if hitbox != null and hitbox.shape is RectangleShape2D:
				var rect := Rect2(-(hitbox.shape as RectangleShape2D).size * 0.5, (hitbox.shape as RectangleShape2D).size)
				picker.add(node, DecorationPicker.quad_of(selector.global_transform * hitbox.transform, rect))
				selectors[node.get_instance_id()] = selector
				centres.append(node.global_position)
		stack.append_array(node.get_children())
	_log("objects=%d entries=%d" % [selectors.size(), picker.size()])
	if centres.is_empty():
		print("PICK_CHECK error: no selection boxes")
		return

	var space := (editor_scene as CanvasItem).get_world_2d().direct_space_state
	var rng := RandomNumberGenerator.new()
	rng.seed = _SEED
	var point_mismatch := 0
	var point_hits := 0
	for q in _POINT_QUERIES:
		var centre := centres[rng.randi() % centres.size()] + Vector2(rng.randf_range(-60.0, 60.0), rng.randf_range(-60.0, 60.0))
		var physics := _physics_ids(space, selectors, _circle_query(centre))
		var index := _ids(picker.query_circle(centre, 2.0))
		point_hits += physics.size()
		if physics != index:
			point_mismatch += 1
			if point_mismatch <= 5:
				print("PICK_CHECK point mismatch at %s physics=%s index=%s" % [centre, physics, index])
	var rect_mismatch := 0
	var rect_hits := 0
	for q in _RECT_QUERIES:
		var centre := centres[rng.randi() % centres.size()]
		var size := Vector2(rng.randf_range(2.0, 240.0), rng.randf_range(2.0, 240.0))
		var rect := Rect2(centre - size * 0.5, size)
		var physics := _physics_ids(space, selectors, _rect_query(rect))
		var index := _ids(picker.query_rect(rect))
		rect_hits += physics.size()
		if physics != index:
			rect_mismatch += 1
			if rect_mismatch <= 5:
				print("PICK_CHECK rect mismatch at %s physics=%s index=%s" % [rect, physics, index])
	_log("points=%d hits=%d mismatches=%d" % [_POINT_QUERIES, point_hits, point_mismatch])
	_log("rects=%d hits=%d mismatches=%d" % [_RECT_QUERIES, rect_hits, rect_mismatch])
	_log("result=%s" % ("PASS" if point_mismatch == 0 and rect_mismatch == 0 else "FAIL"))


func _circle_query(centre: Vector2) -> PhysicsShapeQueryParameters2D:
	var query := PhysicsShapeQueryParameters2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 2.0
	query.shape = shape
	query.transform = Transform2D(0.0, centre)
	return query


func _rect_query(rect: Rect2) -> PhysicsShapeQueryParameters2D:
	var query := PhysicsShapeQueryParameters2D.new()
	var shape := RectangleShape2D.new()
	shape.size = rect.size
	query.shape = shape
	query.transform = Transform2D(0.0, rect.get_center())
	return query


## Physics overlaps of selection boxes, as a sorted list of GDObject ids.
func _physics_ids(space: PhysicsDirectSpaceState2D, selectors: Dictionary, query: PhysicsShapeQueryParameters2D) -> Array:
	query.collision_mask = _SCAN_MASK
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var ids: Array = []
	for hit: Dictionary in space.intersect_shape(query, 512):
		var collider: Object = hit.collider
		if collider is Area2D and collider.name == &"EditorSelectionCollider" and collider.get_parent() is GDObject:
			ids.append(collider.get_parent().get_instance_id())
	ids.sort()
	return ids


func _ids(objects: Array) -> Array:
	var ids: Array = []
	for object: Node in objects:
		ids.append(object.get_instance_id())
	ids.sort()
	return ids
