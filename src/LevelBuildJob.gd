class_name LevelBuildJob
extends RefCounted
## Incrementally builds a level without ever creating a scene-tree node for
## runtime decoration. Imported levels can contain hundreds of thousands of
## decorative placements; representing those as GDObject scenes is both the
## dominant open-time cost and the dominant source of memory pressure.
##
## In the editor each placement remains a node (selection/editing requires it).
## In the game, decoration is fed directly into GDDecorationLoader and emitted
## as a small set of DecorationBatch canvas items. The batches use the same GD
## atlas frames, transforms, colours, blend modes and z ordering as the scenes,
## so this removes scene-tree overhead without lowering visual quality.

var level: Level
var finished: bool = false

var _data: Dictionary
var _layers_data: Array
var _drop_decoration: bool
var _batch_all_decoration: bool
var _layer_index: int = 0
var _object_index: int = 0
var _layer: Layer
var _layer_initialised: bool = false

# Incremental decoration build state. Accumulating directly into batches avoids
# retaining a second Array of every decoration dictionary while a level opens.
var _decoration_batches: Dictionary = {}
var _sealing: bool = false
var _seal_batches: Array = []
var _seal_index: int = 0
var _finished_batches: Array[DecorationBatch] = []


func _init(data: Dictionary) -> void:
	_data = data
	level = Level.new()
	_drop_decoration = Config.ldm and not Editor.in_editor
	_batch_all_decoration = not Editor.in_editor
	level.set_meta(Level.RUNTIME_BATCHED_DECORATION_META, _batch_all_decoration)
	_layers_data = _data.layers
	if _layers_data.is_empty():
		_finish()


## Builds as much as fits inside budget_ms. The deadline is checked after each
## placement and each completed batch. A single generated scene or sort may
## overshoot slightly, but large layers can no longer be finalised all at once.
func step(budget_ms: int) -> void:
	if finished:
		return
	var deadline := Time.get_ticks_msec() + maxi(1, budget_ms)
	while not finished and Time.get_ticks_msec() < deadline:
		_work()


func _work() -> void:
	if not _layer_initialised:
		_start_next_layer()
		return
	if _sealing:
		_seal_step()
		return
	var layer_data: Dictionary = _layers_data[_layer_index]
	var objects: Array = layer_data.objects
	if _object_index < objects.size():
		_place(objects[_object_index])
		_object_index += 1
		return
	_begin_seal()


func _start_next_layer() -> void:
	if _layer_index >= _layers_data.size():
		_finish()
		return
	var layer_data: Dictionary = _layers_data[_layer_index]
	var new_layer := Layer.new()
	new_layer.name = layer_data.name
	new_layer.locked = layer_data.locked
	_layer = new_layer
	_layer_initialised = true
	_object_index = 0
	_decoration_batches = GDDecorationLoader.new_batches()
	_sealing = false
	_seal_batches.clear()
	_finished_batches.clear()
	_seal_index = 0


func _place(object_data: Dictionary) -> void:
	if object_data.get("decoration", false):
		if _drop_decoration:
			return
		# Runtime decoration never needs selection collision, scripts or one
		# CanvasItem per sprite. Feed every mapped object to the atlas batcher,
		# even when a generated gd_<id>.tscn happens to exist.
		if _batch_all_decoration:
			GDDecorationLoader.add_object(
					_decoration_batches, object_data, GDDecorationLoader.art_scale()
			)
			return
		var placed: GDObject = Level.instantiate_gd_object(object_data, level)
		if placed != null:
			placed.set_meta(Constants.LAYER_META, _layer)
			_layer.add_child(placed)
		else:
			GDDecorationLoader.add_object(
					_decoration_batches, object_data, GDDecorationLoader.art_scale()
			)
		return

	var object: Node2D = Level.instantiate_object_from_data(object_data, level)
	if object == null:
		return
	# Most gameplay blocks have no trigger group. Keep their lightweight root
	# and collision identity, but draw their atlas art through the same batch as
	# decoration. This removes Base/Detail Sprite2D trees and HSVWatcher nodes
	# from thousands of static blocks without changing a pixel.
	if (
			_batch_all_decoration
			and object is GDObject
			and object_data.get("groups", []).is_empty()
	):
		var visual_data: Dictionary = object_data.duplicate(true)
		visual_data["decoration"] = true
		visual_data["_runtime_gameplay_art"] = true
		visual_data["z_layer"] = int((object as GDObject).z_layer)
		visual_data["z_order"] = int((object as GDObject).z_order)
		visual_data["tint"] = (object as GDObject).tint
		visual_data["detail_tint"] = (object as GDObject).detail_tint
		visual_data["base_alpha"] = (object as GDObject).base_alpha
		var object_hsv: Dictionary = object_data.get("hsv", {})
		var shift: Array = object_hsv.get("hsv_shift", [])
		if shift.size() >= 3:
			visual_data["hsv_shift"] = PackedFloat32Array([
					float(shift[0]), float(shift[1]), float(shift[2]), 1.0, 1.0,
			])
		visual_data["base_alpha"] *= float(object_hsv.get("alpha", 1.0))
		var intensity := float(object_hsv.get("intensity", 1.0))
		visual_data["tint"] = Color(
				visual_data.tint.r * intensity,
				visual_data.tint.g * intensity,
				visual_data.tint.b * intensity,
				visual_data.tint.a,
		)
		GDDecorationLoader.add_object(
				_decoration_batches, visual_data, GDDecorationLoader.art_scale()
		)
		object.set_meta(Level.RUNTIME_BATCHED_ART_META, true)
		(object as GDObject).set_runtime_art_batched()
	object.set_meta(Constants.LAYER_META, _layer)
	_layer.add_child(object)


func _begin_seal() -> void:
	_sealing = true
	_seal_batches = _decoration_batches.values()
	_seal_index = 0
	_finished_batches.clear()
	if _seal_batches.is_empty():
		_finish_seal()


## Builds at most one decoration batch per work unit. Previously finish_batches
## sorted every batch in one call, causing a large end-of-layer hitch.
func _seal_step() -> void:
	if _seal_index >= _seal_batches.size():
		_finish_seal()
		return
	var batch := _seal_batches[_seal_index] as DecorationBatch
	_seal_index += 1
	if batch == null or batch.items.is_empty():
		if batch != null:
			batch.free()
		return
	batch.build()
	_finished_batches.append(batch)


func _finish_seal() -> void:
	GDDecorationLoader.finalise_batch_order(_finished_batches)
	for batch: DecorationBatch in _finished_batches:
		batch.capture_initial_state()
		batch.set_meta(Constants.LAYER_META, _layer)
		_layer.add_child(batch)
	level.layers.append(_layer)
	level.add_child(_layer)
	_layer_initialised = false
	_sealing = false
	_layer_index += 1
	_decoration_batches.clear()
	_seal_batches.clear()
	_finished_batches.clear()


func _finish() -> void:
	# The input graph can be very large. Level.use_data must run before these
	# references are released, but after that the job should not pin it in RAM.
	level.use_data(_data, Level.UseDataFlags.IS_INSTANTIATION)
	level.ready.connect(level.setup_color_channel_watchers, CONNECT_ONE_SHOT)
	finished = true
	_data = {}
	_layers_data = []
