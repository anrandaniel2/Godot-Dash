extends Node
## Compares DecorationPicker's hit sets with physics on a real editor level.
## GDASH_MEM_LEVEL=/path/level.gmd; grep "PICK_CHECK". This does NOT verify
## selection order, rendering parity, or browser frame time.

const _SAVE_PATH: String = "user://picking_check.gmd"
const _POINT_QUERIES: int = 3000
const _RECT_QUERIES: int = 600
const _SEED: int = 20261013
const _FRAME_SAMPLES: int = 60
## Physics selection collider is layer 256; the placed-objects collider and the
## selection zone both scan mask 264 (see EditorScene.tscn).
const _SCAN_MASK: int = 264
const _MAX_PHYSICS_HITS: int = 65536

var _start_ms: int = 0
var _saturated_queries: int = 0


func _log(message: String) -> void:
	print("PICK_CHECK +%.1fs %s" % [(Time.get_ticks_msec() - _start_ms) / 1000.0, message])


func _ready() -> void:
	_start_ms = Time.get_ticks_msec()
	var path: String = OS.get_environment("GDASH_MEM_LEVEL")
	var document: GMD.Document = GMD.read_any_file(path)
	if document == null or document.level_string.is_empty():
		_log("error: could not read %s" % path)
		get_tree().quit(1)
		return
	var data: Dictionary = GMDConverter.import_online_level_string(
		document.level_string, "PickCheck", GMDConverter.ImportReport.new()
	)
	document = null
	LevelOperationsHandler.write_level_and_meta(_SAVE_PATH, data)
	data = {}
	var loaded: Dictionary = LevelOperationsHandler.load_level_data_from_path(_SAVE_PATH)
	if loaded.is_empty():
		_log("error: saved level could not be loaded")
		get_tree().quit(1)
		return
	_log(
		(
			"level loaded seed=%d os=%s headless=%s"
			% [
				_SEED,
				OS.get_name(),
				DisplayServer.get_name() == "headless",
			]
		)
	)
	Editor.level_data_snapshot = loaded
	var started: int = Time.get_ticks_usec()
	var editor_scene: Node = (load("res://scenes/EditorScene.tscn") as PackedScene).instantiate()
	add_child(editor_scene)
	_log("editor_add_ms=%.3f" % ((Time.get_ticks_usec() - started) / 1000.0))
	await _sample_frames()
	await get_tree().physics_frame
	await get_tree().physics_frame
	_log("editor scene ready")
	_memory("editor_ready")
	var passed: bool = _check(editor_scene)
	get_tree().quit(0 if passed else 1)


## Instrument the existing 60-frame settling wait; do not add another wait.
## These startup intervals include deferred work, pacing and probe overhead,
## not just CPU time, and are not a steady-state rendering benchmark.
func _sample_frames() -> void:
	var samples: Array[float] = []
	var started: int = Time.get_ticks_usec()
	var previous: int = started
	for frame: int in _FRAME_SAMPLES:
		await get_tree().process_frame
		var now: int = Time.get_ticks_usec()
		samples.append((now - previous) / 1000.0)
		previous = now
	var elapsed_ms: float = (previous - started) / 1000.0
	samples.sort()
	_log(
		(
			"startup_frame_samples=%d mean_ms=%.3f p95_ms=%.3f max_ms=%.3f sample_elapsed_ms=%.3f"
			% [
				_FRAME_SAMPLES,
				elapsed_ms / _FRAME_SAMPLES,
				samples[ceili(_FRAME_SAMPLES * 0.95) - 1],
				samples.back(),
				elapsed_ms,
			]
		)
	)


func _check(editor_scene: Node) -> bool:
	var selectors: Dictionary = {}  # GDObject instance id -> selector Area2D
	var centres: Array[Vector2] = []
	var stack: Array[Node] = [editor_scene]
	var picker: DecorationPicker = DecorationPicker.new()
	var before_bytes: int = OS.get_static_memory_usage()
	var started: int = Time.get_ticks_usec()
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is GDObject and node.has_node(^"EditorSelectionCollider"):
			var selector: Area2D = node.get_node(^"EditorSelectionCollider")
			var hitbox: CollisionShape2D = selector.get_node_or_null(^"EditorSelectionHitbox")
			if hitbox != null and hitbox.shape is RectangleShape2D and not hitbox.disabled:
				var size: Vector2 = (hitbox.shape as RectangleShape2D).size
				var rect: Rect2 = Rect2(-size * 0.5, size)
				picker.add(
					node,
					DecorationPicker.quad_of(selector.global_transform * hitbox.transform, rect)
				)
				selectors[node.get_instance_id()] = selector
				centres.append(selector.global_transform * hitbox.position)
		stack.append_array(node.get_children())
	_log(
		(
			"objects=%d entries=%d index_and_oracle_build_ms=%.3f static_delta_bytes=%d"
			% [
				selectors.size(),
				picker.size(),
				(Time.get_ticks_usec() - started) / 1000.0,
				OS.get_static_memory_usage() - before_bytes,
			]
		)
	)
	_memory("index_and_oracle_ready")
	if centres.is_empty():
		_log("error: no selection boxes; result=FAIL")
		return false

	var space: PhysicsDirectSpaceState2D = (
		(editor_scene as CanvasItem).get_world_2d().direct_space_state
	)
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _SEED
	var point_mismatch: int = 0
	var point_hits: int = 0
	var physics_us: int = 0
	var index_us: int = 0
	for q: int in _POINT_QUERIES:
		var centre: Vector2 = (
			centres[rng.randi() % centres.size()]
			+ Vector2(rng.randf_range(-60.0, 60.0), rng.randf_range(-60.0, 60.0))
		)
		var query: PhysicsShapeQueryParameters2D = _circle_query(centre)
		started = Time.get_ticks_usec()
		var physics: Array = _physics_ids(space, selectors, query)
		physics_us += Time.get_ticks_usec() - started
		started = Time.get_ticks_usec()
		var index: Array = _ids(picker.query_circle(centre, 2.0))
		index_us += Time.get_ticks_usec() - started
		point_hits += physics.size()
		if physics != index:
			point_mismatch += 1
			if point_mismatch <= 5:
				_log("point mismatch at %s physics=%s index=%s" % [centre, physics, index])
	_log(
		(
			"points=%d hits=%d mismatches=%d physics_total_ms=%.3f index_total_ms=%.3f"
			% [
				_POINT_QUERIES,
				point_hits,
				point_mismatch,
				physics_us / 1000.0,
				index_us / 1000.0,
			]
		)
	)
	var rect_mismatch: int = 0
	var rect_hits: int = 0
	physics_us = 0
	index_us = 0
	for q: int in _RECT_QUERIES:
		var centre: Vector2 = centres[rng.randi() % centres.size()]
		var size: Vector2 = Vector2(rng.randf_range(2.0, 240.0), rng.randf_range(2.0, 240.0))
		var rect: Rect2 = Rect2(centre - size * 0.5, size)
		var query: PhysicsShapeQueryParameters2D = _rect_query(rect)
		started = Time.get_ticks_usec()
		var physics: Array = _physics_ids(space, selectors, query)
		physics_us += Time.get_ticks_usec() - started
		started = Time.get_ticks_usec()
		var index: Array = _ids(picker.query_rect(rect))
		index_us += Time.get_ticks_usec() - started
		rect_hits += physics.size()
		if physics != index:
			rect_mismatch += 1
			if rect_mismatch <= 5:
				_log("rect mismatch at %s physics=%s index=%s" % [rect, physics, index])
	_log(
		(
			"rects=%d hits=%d mismatches=%d physics_total_ms=%.3f index_total_ms=%.3f"
			% [
				_RECT_QUERIES,
				rect_hits,
				rect_mismatch,
				physics_us / 1000.0,
				index_us / 1000.0,
			]
		)
	)
	## Empty or truncated physics results cannot establish parity.
	var passed: bool = (
		point_mismatch == 0
		and rect_mismatch == 0
		and _saturated_queries == 0
		and point_hits > 0
		and rect_hits > 0
	)
	_log("saturated_queries=%d result=%s" % [_saturated_queries, "PASS" if passed else "FAIL"])
	return passed


func _circle_query(centre: Vector2) -> PhysicsShapeQueryParameters2D:
	var query: PhysicsShapeQueryParameters2D = PhysicsShapeQueryParameters2D.new()
	var shape: CircleShape2D = CircleShape2D.new()
	shape.radius = 2.0
	query.shape = shape
	query.transform = Transform2D(0.0, centre)
	return query


func _rect_query(rect: Rect2) -> PhysicsShapeQueryParameters2D:
	var query: PhysicsShapeQueryParameters2D = PhysicsShapeQueryParameters2D.new()
	var shape: RectangleShape2D = RectangleShape2D.new()
	shape.size = rect.size
	query.shape = shape
	query.transform = Transform2D(0.0, rect.get_center())
	return query


## Grow the physics result buffer until completeness is known. A fixed 512-hit
## limit silently truncates dense overlaps and creates false index mismatches.
func _physics_ids(
	space: PhysicsDirectSpaceState2D, selectors: Dictionary, query: PhysicsShapeQueryParameters2D
) -> Array:
	query.collision_mask = _SCAN_MASK
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var limit: int = 512
	var hits: Array[Dictionary] = space.intersect_shape(query, limit)
	while hits.size() == limit and limit < _MAX_PHYSICS_HITS:
		limit *= 2
		hits = space.intersect_shape(query, limit)
	if hits.size() == limit:
		_saturated_queries += 1
	var unique_ids: Dictionary = {}
	for hit: Dictionary in hits:
		var collider: Object = hit.collider
		if (
			collider is Area2D
			and collider.name == &"EditorSelectionCollider"
			and collider.get_parent() is GDObject
		):
			var id: int = collider.get_parent().get_instance_id()
			if selectors.get(id) == collider:
				unique_ids[id] = true
	var ids: Array = unique_ids.keys()
	ids.sort()
	return ids


func _ids(objects: Array) -> Array:
	var ids: Array = []
	for object: Node in objects:
		ids.append(object.get_instance_id())
	ids.sort()
	return ids


func _memory(stage: String) -> void:
	_log(
		(
			"stage=%s static_bytes=%d static_peak_bytes=%d nodes=%d"
			% [
				stage,
				OS.get_static_memory_usage(),
				OS.get_static_memory_peak_usage(),
				int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
			]
		)
	)
	if OS.has_feature("linux"):
		var status: FileAccess = FileAccess.open("/proc/self/status", FileAccess.READ)
		if status != null:
			while not status.eof_reached():
				var line: String = status.get_line()
				if line.begins_with("VmRSS:") or line.begins_with("VmHWM:"):
					_log("stage=%s %s" % [stage, line.strip_edges()])
