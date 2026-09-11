class_name FrustumCuller
extends Node
## Dynamic node rendering: hides level objects that are outside the camera's
## view so the graphics card never draws them and they cost no per-frame work.
##
## Every placement keeps its own node (the level is fully built at open, like
## the editor build). A level with tens of thousands of placements would still
## make Godot submit every one of those CanvasItems to the draw list every
## frame; the renderer's own clip test happens far too late to save that work.
## Turning off [member CanvasItem.visible] on everything far from the camera
## removes the draw-list entry entirely, which is the win this exists for.
##
## "Not processed" comes along for free: the only per-node animation on a
## placement is [GDObject]'s built-in spin, and GDObject stops its own
## [method Node._process] as soon as [member CanvasItem.visible] becomes false
## and picks it back up when the object scrolls into view (see
## [method GDObject._apply_spin]). Objects that run real logic - triggers,
## portals, physics blocks, anything in a Geometry Dash group that a trigger
## can move - are never culled in the first place.
##
## Objects are bucketed by the horizontal span they cover, in cells. Every
## frame the camera's world rectangle is grown by a buffer of
## [member Config.culling_buffer_cells] cells on every side, and only the
## buckets it touches are made visible. The buffer is what stops gaps from
## showing: a speed portal or a camera trigger can move the view a long way in
## one frame, and objects must already be visible when they scroll in. It is
## generous by default (a screen's worth of cells) because unhiding is cheap
## and popping is not.
##
## Only objects that nothing can move are culled: anything in a Geometry Dash
## group can be driven by a Move, Rotate or Scale trigger and would leave its
## bucket, so those - along with triggers, portals and physics blocks - are
## left to the renderer. Objects a Toggle trigger has hidden are left alone
## too: the manager only ever shows objects it hid itself.
##
## Active only while a level plays (also during editor playtests); while
## editing, every object stays visible.

## Level objects with a horizontal extent wider than this many cells are never
## culled: a long moving platform or an enormous background sprite could
## otherwise vanish while its centre is far away but its edge is on screen.
const OVERSIZE_CELLS: float = 64.0
## Cells per bucket.
const BUCKET_CELLS: int = 8
## How far past the camera's trailing edge objects stay visible. The leading
## edge keeps the full [member Config.culling_buffer_cells] buffer so nothing
## pops in ahead of a fast camera; trailing objects have already been played
## through, so a small buffer is enough (a teleport or backward camera move
## still cannot pop more than this much in one step).
const BEHIND_BUFFER_CELLS: float = 8.0
## Covers floating-point edge rounding without retaining meaningfully off-screen
## art. The actual visual bounds, not this epsilon, provide the conservatism.
const EDGE_EPSILON: float = 2.0

var level: Level

## bucket index -> Array[Node2D]
var _buckets: Dictionary[int, Array] = { }
## Objects wider than OVERSIZE_CELLS; always visible.
var _oversize: Array[Node2D] = []
## Objects this manager hid, so only those are shown again.
var _hidden: Dictionary[Node2D, bool] = { }
var _tracked: int = 0
var _built_for_count: int = -1
## Bucket range shown last frame, so a frame with no camera movement is free.
var _last_first: int = 0x7fffffff
var _last_last: int = -0x7fffffff
var _active: bool = false
## Packed C++ visibility index. The GDScript structures remain as a portable
## source/editor fallback.
var _native_index: Object


func _ready() -> void:
	level = get_parent() as Level
	if NativeCore.available() and ClassDB.class_exists(&"NativeFrustumIndex"):
		_native_index = ClassDB.instantiate(&"NativeFrustumIndex")
	set_process(false)
	LevelManager.level_started.connect(_on_level_started)
	LevelManager.level_stopped.connect(_on_level_stopped)


## Registers every object currently in the level's layers. Called once the
## level's layers are built (on the first level start); safe to call again
## after the object set changed.
func rebuild() -> void:
	_buckets.clear()
	_oversize.clear()
	_tracked = 0
	if level == null:
		return
	if _native_index != null:
		var objects: Array = []
		var lefts := PackedFloat32Array()
		var rights := PackedFloat32Array()
		for current_layer: Layer in level.layers:
			for child: Node in current_layer.get_children():
				if child is not Node2D or not is_cullable(child):
					continue
				var span := _horizontal_span(child)
				_tracked += 1
				if span.y - span.x > OVERSIZE_CELLS * Constants.CELL_SIZE:
					_oversize.append(child)
					continue
				objects.append(child)
				lefts.append(span.x)
				rights.append(span.y)
		_native_index.call(
				&"configure", objects, lefts, rights,
				BUCKET_CELLS * Constants.CELL_SIZE,
		)
	else:
		for current_layer: Layer in level.layers:
			for child: Node in current_layer.get_children():
				if child is Node2D:
					track(child)
	_last_first = 0x7fffffff
	_last_last = -0x7fffffff


## Adds one object, unless it is one the manager must not touch.
func track(object: Node2D) -> void:
	if not is_cullable(object):
		return
	var span: Vector2 = _horizontal_span(object)
	if span.y - span.x > OVERSIZE_CELLS * Constants.CELL_SIZE:
		_oversize.append(object)
		_tracked += 1
		return
	var first: int = _bucket_of(span.x)
	var last: int = _bucket_of(span.y)
	for bucket: int in range(first, last + 1):
		if not _buckets.has(bucket):
			_buckets[bucket] = []
		_buckets[bucket].append(object)
	_tracked += 1


## Whether the manager may hide [param object]: static scenery only.
static func is_cullable(object: Node2D) -> bool:
	if object is Layer or object is Player or object is Interactable:
		return false
	if object is SolidObject and object.physics_object:
		return false
	# Anything a trigger can address may move, so its load-time bucket
	# would go stale.
	for group: StringName in object.get_groups():
		if str(group).begins_with(Constants.GROUP_PREFIX):
			return false
	return true


func _bucket_of(x: float) -> int:
	return floori(x / (BUCKET_CELLS * Constants.CELL_SIZE))


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
		var node := pending.pop_back()
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
	# First pass: reconcile every tracked object with the camera (hiding those
	# outside the view) instead of only the range edges.
	_last_first = 0x7fffffff
	_last_last = -0x7fffffff
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
	if _native_index != null:
		_native_index.call(&"show_all")
	for object: Node2D in _hidden:
		if is_instance_valid(object) and object.process_mode != Node.PROCESS_MODE_DISABLED:
			object.visible = true
	_hidden.clear()
	_last_first = 0x7fffffff
	_last_last = -0x7fffffff


func _process(_delta: float) -> void:
	_update()


func _update() -> void:
	var camera: Camera2D = get_viewport().get_camera_2d() if is_inside_tree() else null
	if camera == null:
		return
	var cell: float = Constants.CELL_SIZE
	var view: Rect2 = _camera_rect(camera)
	if _native_index != null:
		# Native sections are only a candidate index. The final comparison uses
		# exact world coordinates every camera frame, so visible objects behind
		# the player remain until their last pixel exits and already-offscreen
		# objects are not retained by a coarse eight-cell bucket.
		_native_index.call(&"set_view", view.position.x, view.end.x)
		_last_first = _bucket_of(view.position.x)
		_last_last = _bucket_of(view.end.x)
		return
	if not LevelManager.platformer:
		# Portable fallback keeps a look-ahead buffer to avoid GDScript bucket
		# popping. Native builds do not need it because their final test is exact.
		var behind: float = minf(BEHIND_BUFFER_CELLS * cell, Config.culling_buffer_cells * cell)
		var ahead: float = Config.culling_buffer_cells * cell
		view = view.grow_individual(behind, ahead, ahead, ahead)
	else:
		view = view.grow(Config.culling_buffer_cells * cell)
	var first: int = _bucket_of(view.position.x)
	var last: int = _bucket_of(view.end.x)
	var had_range: bool = _last_first <= _last_last
	if had_range and first == _last_first and last == _last_last:
		return

	if not had_range:
		# First pass after a (re)build: reconcile every tracked object with the
		# camera rather than only the range edges, so objects that start
		# outside the view are hidden right away. The range is set first so the
		# per-object span test inside _set_bucket_visible sees the final
		# window and keeps wide objects visible.
		_last_first = first
		_last_last = last
		for bucket: int in _buckets.keys():
			if bucket < first or bucket > last:
				_set_bucket_visible(bucket, false)
		for bucket: int in range(first, last + 1):
			if _buckets.has(bucket):
				_set_bucket_visible(bucket, true)
		return

	# Hide what left the range, show what entered it. Buckets are keyed on
	# the object's position at load time; a moving object is handled by the
	# oversize list or by simply remaining in its original buckets, which is
	# harmless as long as its motion stays within the buffer.
	for bucket: int in range(_last_first, _last_last + 1):
		if bucket >= first and bucket <= last:
			continue
		_set_bucket_visible(bucket, false)
	for bucket: int in range(first, last + 1):
		if bucket >= _last_first and bucket <= _last_last:
			continue
		_set_bucket_visible(bucket, true)
	_last_first = first
	_last_last = last


func _set_bucket_visible(bucket: int, shown: bool) -> void:
	var objects: Array = _buckets.get(bucket, [])
	for object: Node2D in objects:
		if not is_instance_valid(object):
			continue
		if shown:
			# An object toggled off by a trigger while it was culled stays
			# off; ToggleComponent marks that state by disabling processing.
			if _hidden.erase(object) and object.process_mode != Node.PROCESS_MODE_DISABLED:
				object.visible = true
		else:
			# Never hide something already hidden by a trigger or the editor;
			# it would be shown again by us later.
			if not object.visible:
				continue
			# An object spanning several buckets stays visible while any of
			# them is in range.
			if _spans_visible_range(object):
				continue
			object.visible = false
			_hidden[object] = true


func _spans_visible_range(object: Node2D) -> bool:
	var span: Vector2 = _horizontal_span(object)
	var first: int = _bucket_of(span.x)
	var last: int = _bucket_of(span.y)
	return last >= _last_first and first <= _last_last


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
	if _native_index != null:
		return int(_native_index.call(&"hidden_count"))
	return _hidden.size()
