class_name LevelBuildJob
extends RefCounted
## Builds a [Level] from level data one placement at a time, so opening a
## level never blocks the main thread for seconds at once.
##
## [method Level.from_data] feeds every placement through this job in one
## unlimited step, so editor behaviour is byte-for-byte the old synchronous
## build. The game (see GameScene) instead creates the job, adds the level to
## the tree only when it is finished, and calls [method step] with a small
## millisecond budget once per frame - Android would otherwise show an ANR
## dialog while a large level opens.
##
## The construction order is identical to the old synchronous build: gameplay
## placements and decoration placements that have a generated scene become one
## [GDObject]/scene node each, in data order per layer; decorations without a
## generated scene are collected and drawn by [DecorationBatch] nodes appended
## after the layer's real objects; only then does the level apply its data
## fields and deserialize onto the finished tree.

## The level being built. Only fully usable once [member finished] is true.
var level: Level
## True once the whole level has been built and [method Level.use_data] ran.
var finished: bool = false

var _data: Dictionary
var _layers_data: Array
var _drop_decoration: bool
var _layer_index: int = 0
var _object_index: int = 0
var _layer: Layer
var _layer_initialised: bool = false
var _decoration_data: Array = []


func _init(data: Dictionary) -> void:
	_data = data
	level = Level.new()
	_drop_decoration = Config.ldm and not Editor.in_editor
	_layers_data = _data.layers
	if _layers_data.is_empty():
		_finish()


## Builds as much of the level as fits inside [param budget_ms] of main-thread
## work. Cheap to call with a large budget (the editor path does exactly that).
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
	var layer_data: Dictionary = _layers_data[_layer_index]
	var objects: Array = layer_data.objects
	if _object_index < objects.size():
		# One placement per call so the budget check can run between them.
		_place(objects[_object_index])
		_object_index += 1
		return
	_seal_layer()


func _start_next_layer() -> void:
	if _layer_index >= _layers_data.size():
		_finish()
		return
	var layer_data: Dictionary = _layers_data[_layer_index]
	var layer := Layer.new()
	layer.name = layer_data.name
	layer.locked = layer_data.locked
	_layer = layer
	_layer_initialised = true
	_object_index = 0


## Instantiates one level-data entry exactly as the synchronous builder did.
func _place(object_data: Dictionary) -> void:
	if object_data.get("decoration", false):
		if _drop_decoration:
			return
		if Config.use_decoration_batches_in_play and not Editor.in_editor:
			# Play build: every decoration, generated scene or not, is drawn by
			# a shared DecorationBatch (see Config.use_decoration_batches_in_play).
			# Giving each placement its own GDObject node is what ran large
			# levels out of heap.
			_decoration_data.append(object_data)
			return
		var placed: GDObject = Level.instantiate_gd_object(object_data, level)
		if placed != null:
			placed.set_meta(Constants.LAYER_META, _layer)
			_layer.add_child(placed)
		elif not Level.gd_object_entry_has_node(object_data):
			# No generated scene: it is drawn by a fallback batch instead.
			_decoration_data.append(object_data)
		return
	var object: Node2D = Level.instantiate_object_from_data(object_data, level)
	# Null when the object was filtered out by low detail mode.
	if object == null:
		return
	object.set_meta(Constants.LAYER_META, _layer)
	_layer.add_child(object)


## Finishes the current layer (appends its fallback decoration batches) and
## adds it to the level, matching the synchronous builder's order.
func _seal_layer() -> void:
	if not _decoration_data.is_empty():
		for batch: DecorationBatch in GDDecorationLoader.build_batches(
				_decoration_data, GDDecorationLoader.art_scale()
		):
			batch.set_meta(Constants.LAYER_META, _layer)
			_layer.add_child(batch)
		_decoration_data.clear()
	level.layers.append(_layer)
	level.add_child(_layer)
	_layer_initialised = false
	_layer_index += 1


func _finish() -> void:
	level.use_data(_data, true)
	level.ready.connect(level.setup_color_channel_watchers, CONNECT_ONE_SHOT)
	finished = true
