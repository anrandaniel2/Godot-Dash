class_name FrustumCuller
extends Node
## Dynamic node rendering: hides level objects that are outside the camera's
## view so the graphics card never draws them and they cost no per-frame work.
##
## Turning off [member CanvasItem.visible] on everything off screen removes
## the draw-list entry entirely; GDObject also stops its spin while hidden.
## The index and the exact per-frame test live in C++ (NativeFrustumIndex):
## static objects are sectioned once, grouped objects - which triggers move -
## are tested at their live position every frame, and Link Visible (3662)
## groups stay shown while any member is on screen. Triggers, portals and
## physics blocks are never culled; objects a Toggle trigger hid stay hidden.
##
## Active only while a level plays (also during editor playtests).

## Level objects with a horizontal extent wider than this many cells are never
## culled: a long moving platform or an enormous background sprite could
## otherwise vanish while its centre is far away but its edge is on screen.
const OVERSIZE_CELLS: float = 64.0
## Cells per native index section.
const BUCKET_CELLS: int = 8
## Slack around grouped objects, whose span scale/rotate triggers can grow.
const DYNAMIC_MARGIN_CELLS: float = 4.0
## Covers floating-point edge rounding without retaining meaningfully off-screen
## art. The actual visual bounds, not this epsilon, provide the conservatism.
const EDGE_EPSILON: float = 2.0

var level: Level

var _tracked: int = 0
var _built_for_count: int = -1
var _active: bool = false
var _native_index: Object


func _ready() -> void:
	level = get_parent() as Level
	_native_index = ClassDB.instantiate(&"NativeFrustumIndex")
	set_process(false)
	LevelManager.level_started.connect(_on_level_started)
	LevelManager.level_stopped.connect(_on_level_stopped)


## Registers every object currently in the level's layers. Called once the
## level's layers are built (on the first level start); safe to call again
## after the object set changed.
func rebuild() -> void:
	_tracked = 0
	if level == null:
		return
	var objects: Array = []
	var lefts := PackedFloat32Array()
	var rights := PackedFloat32Array()
	var dynamic_objects: Array = []
	var dynamic_lefts := PackedFloat32Array()
	var dynamic_rights := PackedFloat32Array()
	var dynamic_links := PackedInt32Array()
	var link_of_group: Dictionary[StringName, int] = { }
	for link: int in level.gd_link_visible_groups.size():
		for group: String in level.gd_link_visible_groups[link]:
			link_of_group[StringName(Constants.GROUP_PREFIX + group)] = link
	for current_layer: Layer in level.layers:
		for child: Node in current_layer.get_children():
			if child is not Node2D or not is_cullable(child):
				continue
			var span := _horizontal_span(child)
			_tracked += 1
			if span.y - span.x > OVERSIZE_CELLS * Constants.CELL_SIZE:
				continue
			if is_grouped(child):
				var link: int = -1
				for group: StringName in child.get_groups():
					link = link_of_group.get(group, link)
				# Scale and rotate triggers can grow the span after load.
				var margin: float = DYNAMIC_MARGIN_CELLS * Constants.CELL_SIZE
				dynamic_objects.append(child)
				dynamic_lefts.append(span.x - margin)
				dynamic_rights.append(span.y + margin)
				dynamic_links.append(link)
				continue
			objects.append(child)
			lefts.append(span.x)
			rights.append(span.y)
	_native_index.call(
			&"configure", objects, lefts, rights,
			BUCKET_CELLS * Constants.CELL_SIZE,
	)
	_native_index.call(
			&"configure_dynamic", dynamic_objects, dynamic_lefts, dynamic_rights,
			dynamic_links, level.gd_link_visible_groups.size(),
	)


## Whether the manager may hide [param object]: static scenery only.
static func is_cullable(object: Node2D) -> bool:
	if object is Layer or object is Player or object is Interactable:
		return false
	# NativeLevelBuildJob removes these roots' Sprite2D trees after transferring
	# identical artwork to the node-free native renderer. Visibility cannot affect their
	# collision, so indexing and exact-testing them every camera frame is waste.
	if object.has_meta(&"_gd_native_packed_art"):
		return false
	if object is SolidObject and object.physics_object:
		return false
	return true


## Whether a trigger can address [param object]: it may move, so it is tested
## at its live position every frame instead of from a load-time bucket.
static func is_grouped(object: Node) -> bool:
	for group: StringName in object.get_groups():
		if str(group).begins_with(Constants.GROUP_PREFIX):
			return true
	return false


## Leftmost and rightmost world x this object can cover, at its current
## transform.
func _horizontal_span(object: Node2D) -> Vector2:
	# Authored bounds can lag behind multi-part/generated artwork (especially
	# glow and offset child sprites). Merge them with the actual Sprite2D quads
	# once at index-build time. This prevents a parent from being hidden while
	# one of its children is still visibly crossing either screen edge.
	var rect := Rect2()
	var has_rect := false
	if object is GDObject:
		rect = object.global_transform * object.bounds
		has_rect = rect.has_area()
	elif object.has_method("get_bounds"):
		rect = object.global_transform * object.get_bounds()
		has_rect = rect.has_area()
	var visual := _sprite_tree_bounds(object)
	if visual.has_area():
		rect = rect.merge(visual) if has_rect else visual
		has_rect = true
	if not has_rect:
		# Unknown handmade nodes get a conservative fallback. This is only used
		# when the scene contains no Sprite2D from which exact visual bounds can
		# be calculated.
		var global_scale := object.global_transform.get_scale().abs()
		var half: float = Constants.CELL_SIZE * 2.0 * maxf(global_scale.x, global_scale.y)
		rect = Rect2(object.global_position - Vector2(half, half), Vector2(half, half) * 2.0)
	return Vector2(rect.position.x - EDGE_EPSILON, rect.end.x + EDGE_EPSILON)


## Global AABB of every sprite below one placement. Called only while rebuilding
## the native index, never per frame.
static func _sprite_tree_bounds(root: Node) -> Rect2:
	var result := Rect2()
	var found := false
	var pending: Array[Node] = [root]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		if node is Sprite2D and node.texture != null:
			var sprite_rect: Rect2 = node.global_transform * node.get_rect()
			if sprite_rect.has_area():
				result = result.merge(sprite_rect) if found else sprite_rect
				found = true
		for child: Node in node.get_children():
			pending.append(child)
	return result if found else Rect2()


func _on_level_started() -> void:
	if not Config.culling_enabled:
		return
	if level == null or level != LevelManager.current_level:
		return
	# Buckets are keyed on load-time positions, which every attempt restores,
	# so they are only rebuilt when the set of objects changed.
	var object_count: int = 0
	for layer: Layer in level.layers:
		object_count += layer.get_child_count()
	if object_count != _built_for_count:
		rebuild()
		_built_for_count = object_count
	_active = true
	set_process(true)
	_update()


func _on_level_stopped() -> void:
	if not _active:
		return
	_active = false
	set_process(false)
	show_all()


func _exit_tree() -> void:
	if _active:
		show_all()


## Restores everything this manager hid. Objects a trigger hid stay hidden.
func show_all() -> void:
	_native_index.call(&"show_all")


func _process(_delta: float) -> void:
	_update()


func _update() -> void:
	var camera: Camera2D = get_viewport().get_camera_2d() if is_inside_tree() else null
	if camera == null:
		return
	# Sections are only a candidate index; the comparison uses exact world
	# coordinates every frame, so nothing pops at the edges.
	var view: Rect2 = _camera_rect(camera)
	_native_index.call(&"set_view", view.position.x, view.end.x)
	_native_index.call(&"update_dynamic", view.position.x, view.end.x)


## The camera's visible world rectangle, accounting for zoom and rotation.
func _camera_rect(camera: Camera2D) -> Rect2:
	var viewport_size: Vector2 = camera.get_viewport_rect().size
	var zoom: Vector2 = camera.zoom
	if is_zero_approx(zoom.x) or is_zero_approx(zoom.y):
		zoom = Vector2.ONE
	var half: Vector2 = viewport_size / zoom * 0.5
	var center: Vector2 = camera.get_screen_center_position()
	if is_zero_approx(camera.global_rotation):
		return Rect2(center - half, half * 2.0)
	# A rotated view covers the bounding box of its rotated corners.
	var rect := Rect2(center, Vector2.ZERO)
	for corner: Vector2 in [
		Vector2(-half.x, -half.y), Vector2(half.x, -half.y),
		Vector2(-half.x, half.y), Vector2(half.x, half.y),
	]:
		rect = rect.expand(center + corner.rotated(camera.global_rotation))
	return rect


## Number of objects being managed, for diagnostics.
func tracked_count() -> int:
	return _tracked


## Number of objects currently hidden by the manager.
func hidden_count() -> int:
	return int(_native_index.call(&"hidden_count"))
