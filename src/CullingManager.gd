class_name CullingManager
extends Node
## Hides level objects that are well outside the camera's view.
##
## A large imported level has tens of thousands of nodes; Godot's renderer
## culls anything off screen from the GPU, but each visible [CanvasItem] still
## costs a draw-list entry and each spinning sprite a process call. Turning off
## [member CanvasItem.visible] on everything far from the camera removes that
## cost entirely.
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
## too: the manager only ever touches objects it hid itself.
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


func _ready() -> void:
	level = get_parent() as Level
	set_process(false)
	LevelManager.level_started.connect(_on_level_started)
	LevelManager.level_stopped.connect(_on_level_stopped)


## Registers every object currently in the level's layers. Called by [Level]
## once its layers are built; safe to call again after the level changes.
func rebuild() -> void:
	_buckets.clear()
	_oversize.clear()
	_tracked = 0
	if level == null:
		return
	for layer: Layer in level.layers:
		for child: Node in layer.get_children():
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
	# Placements whose art is hidden and drawn through a shared batch while
	# playing (see LevelBatching): the batch culls itself by buckets.
	if object.has_meta(LevelBatching.OBJECT_META):
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
	var rect: Rect2
	if object is GDObject:
		rect = object.get_world_bounds()
	elif object.has_method("get_bounds"):
		rect = object.transform * object.get_bounds()
	else:
		# Hand-made scenes are at most a few cells; a generous fixed box
		# covers rotated and scaled ones too.
		var half: float = Constants.CELL_SIZE * 2.0 * maxf(absf(object.scale.x), absf(object.scale.y))
		rect = Rect2(object.position - Vector2(half, half), Vector2(half, half) * 2.0)
	return Vector2(rect.position.x, rect.end.x)


func _on_level_started() -> void:
	if not Config.culling_enabled:
		return
	if level == null or level != LevelManager.current_level:
		return
	# A streamed level bounds its live nodes to a window around the player
	# itself (see LevelStream); culling has nothing left to hide.
	if LevelStream.is_streaming(level):
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
	if not LevelManager.platformer:
		# A level scrolls one way; keep the full buffer where objects scroll
		# in (ahead of the camera) and barely any where they have already
		# passed, so far fewer objects stay live at once. Free-roaming
		# platformer levels move both ways and keep the symmetric buffer.
		var behind: float = minf(BEHIND_BUFFER_CELLS * cell, Config.culling_buffer_cells * cell)
		var ahead: float = Config.culling_buffer_cells * cell
		view = view.grow_individual(behind, ahead, ahead, ahead)
	else:
		view = view.grow(Config.culling_buffer_cells * cell)
	var first: int = _bucket_of(view.position.x)
	var last: int = _bucket_of(view.end.x)
	if first == _last_first and last == _last_last:
		return

	# Hide what left the range, show what entered it. Buckets are keyed on
	# the object's position at load time; a moving object is handled by the
	# oversize list or by simply remaining in its original buckets, which is
	# harmless as long as its motion stays within the buffer.
	if _last_first <= _last_last:
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
	return _hidden.size()
