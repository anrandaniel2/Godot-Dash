@icon("res://addons/at-icons/node2d/swatches.svg")
class_name DecorationBatch
extends Node2D
## Draws a set of Geometry Dash decoration objects that share a fate.
##
## A node per object does not survive real levels: a large import is ~170,000
## decoration sprites, and giving each one a [Node2D], an [Area2D] for picking
## and an [HSVWatcher] produces about a million nodes. The engine then spends
## its whole frame on scene-tree and physics bookkeeping.
##
## Drawing everything as one flat pile is equally wrong, though - half of a
## typical level's decoration belongs to a group that a trigger moves, and a
## single pile cannot move in pieces.
##
## So decoration is split into batches that share every property a trigger or
## the renderer cares about:
## [codeblock]
## group set + z layer + blend mode
## [/codeblock]
## On a 170,000 object level that yields roughly 800 batches. Each one is a real
## [Node2D] that joins its Geometry Dash groups, so
## [code]get_nodes_in_group()[/code] finds it and a Move, Rotate, Scale or Alpha
## trigger transforms every object it holds at once - correct behaviour, at
## 1/200th of the node count.
##
## Items are stored in the batch's own local space, so the node's transform is
## applied to all of them by the canvas for free.

## Width of one culling bucket, in local units. Wide enough that the bucket list
## stays short across a long level, narrow enough that a screen only touches a
## couple.
const BUCKET_WIDTH: float = 4096.0

## Margin around the camera rect, so art whose origin is just off-screen but
## whose pixels still overlap is not clipped early.
const CULL_MARGIN: float = 1024.0

## Above this many items, culling is worth its bookkeeping. Small batches - the
## median batch is about 20 items - just draw everything.
const CULL_THRESHOLD: int = 256

## Prefix for the group a batch joins for each colour channel it draws, so a
## channel update can find exactly the batches it affects.
const CHANNEL_GROUP_PREFIX: String = "decobatch_"


## One drawable sprite layer.
##
## A [RefCounted] class rather than a [Dictionary]: typed field access is
## markedly cheaper in a loop that runs over thousands of items each frame.
class Item:
	extends RefCounted

	var texture: Texture2D
	## Region within the atlas page, in atlas pixels.
	var region: Rect2
	## Placement in the batch's local space, including the atlas-to-world scale.
	var transform: Transform2D
	## Imported transform restored between attempts (spin mutates transform).
	var initial_transform: Transform2D
	## Tint from the object's colour channel, including any per-object HSV
	## shift and opacity.
	var modulate: Color = Color.WHITE
	## Alpha the object was imported with, kept separately so a channel update
	## can replace the colour without discarding the object's own opacity.
	var base_alpha: float = 1.0
	## Per-object HSV shift, reapplied whenever the channel colour changes.
	## [code][hue, saturation, value, saturation_additive, value_additive][/code]
	var hsv_shift: PackedFloat32Array = PackedFloat32Array()
	## Sort key within this batch.
	var z_order: int = 0
	## Order among the sprites that make up one object, beneath [member z_order]:
	## negative parts sit behind the object's root sprite, positive in front.
	var draw_order: int = 0
	## Geometry Dash object id, kept for round-tripping and diagnostics.
	var gd_id: int = 0
	## Colour channel group this layer follows; empty when it has none.
	var channel: StringName = &""
	## Which layer of the object this is: "base", "detail", "glow" or "part"
	## (an extra sprite of a multi-sprite object that follows the base colour).
	var layer: String = "base"
	## Local X of the origin, cached for bucketing.
	var origin_x: float = 0.0
	## Degrees per second this item spins, from Geometry Dash's key 97. Zero for
	## the overwhelming majority of objects, which are static.
	var spin: float = 0.0
	## Base items only: whether the object asked for its glow layer (key 96).
	## Saving used to assume every object with a glow frame wanted it drawn,
	## so a re-opened import stacked additive glow over the whole level.
	var wants_glow: bool = false
	## Base items only: the object's detail layer item, when it has one, so its
	## channel and tint survive a save.
	var detail: Item = null
	## Base items only: the object's own transform in the batch's local space,
	## in world units, exactly as it was imported. Saving reads this rather than
	## undoing the sprite placement, which for a multi-sprite object may not
	## even be centred on the object.
	var object_transform: Transform2D = Transform2D.IDENTITY
	## Base items only: the object's imported tint and HSV shift, before any
	## always-black sprite rule was applied to the sprite standing in for it.
	var object_tint: Color = Color.WHITE
	var object_hsv_shift: PackedFloat32Array = PackedFloat32Array()
	## Geometry Dash's "high detail" flag (key 103), kept for saving.
	var high_detail: bool = false
	## Stable final tie-breaker assigned as the item enters its batch.
	var insertion_index: int = 0
	## Runtime-only art for a gameplay root must not serialize as decoration.
	var gameplay_visual: bool = false


## Every item in this batch.
var items: Array[Item] = []

## Only the items with a non-zero spin, so the per-frame update stays
## proportional to the number of rotating objects rather than the batch size.
var _spinning: Array[Item] = []

## Geometry Dash groups this batch belongs to, mirrored onto the node so
## triggers can find it.
var gd_groups: PackedStringArray = PackedStringArray()

## The Geometry Dash coarse z layer (key 24) every object in this batch shares.
var gd_z_layer: int = 0

## Whether this batch is drawn additively, mirroring Geometry Dash's per-channel
## "blending" flag.
var gd_blending: bool = false

## Bucket index -> items whose origin falls in that column.
var _buckets: Dictionary[int, Array] = { }
## Colour channel -> the items that follow it.
##
## Without this, every channel update scans every item: a level with 171
## channels and 186,000 sprites would do ~32 million comparisons just to finish
## loading, because each channel's watcher fires once on ready.
var _by_channel: Dictionary[StringName, Array] = { }
var _last_visible := PackedInt32Array()
var _built: bool = false
var _cull: bool = false
## Local-space bounds of every item, used for a cheap whole-batch visibility
## test before any per-bucket work.
var _bounds: Rect2 = Rect2()
var _initial_transform: Transform2D = Transform2D.IDENTITY
var _initial_visible: bool = true
static var _native_sorter_instance: Object
static var _native_sorter_checked: bool = false


func _init() -> void:
	# Set here rather than in _ready: a batch is fully configured by
	# GDDecorationLoader before it is ever added to the tree, and _ready would
	# not have run by then.
	#
	# The project default is NEAREST_WITH_MIPMAPS, but the atlases are imported
	# without mipmaps, so that filter makes the GPU minify from a chain that
	# does not exist and everything comes out soft and smeared. Plain LINEAR is
	# also what an atlas wants: mip levels of a packed page average neighbouring
	# frames together.
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR


func _ready() -> void:
	# Item z is baked into draw order within the batch; the batch itself sits at
	# the z of the layer it represents.
	z_as_relative = false


## Adds an item, returning it so the caller can keep configuring it.
func add_item(item: Item) -> Item:
	item.insertion_index = items.size()
	items.append(item)
	_built = false
	return item


static func _native_sorter() -> Object:
	if not _native_sorter_checked:
		_native_sorter_checked = true
		if ClassDB.class_exists(&"GdashNative"):
			_native_sorter_instance = ClassDB.instantiate(&"GdashNative")
	return _native_sorter_instance


func _sort_items_fallback() -> void:
	# Direct item sorting uses far less peak memory than allocating a five-value
	# Variant tuple per sprite. Desktop/editor hosts use this path because the
	# Android-only native extension is intentionally absent there.
	items.sort_custom(func(a: Item, b: Item) -> bool:
		if a.z_order != b.z_order:
			return a.z_order < b.z_order
		if a.draw_order != b.draw_order:
			return a.draw_order < b.draw_order
		var a_texture := a.texture.get_instance_id()
		var b_texture := b.texture.get_instance_id()
		if a_texture != b_texture:
			return a_texture < b_texture
		return a.insertion_index < b.insertion_index
	)


## Finalises the batch: sorts for correct layering and texture locality, then
## buckets for culling. Call once, after all items are added.
func build() -> void:
	# Sorting on a precomputed integer key beats comparing object fields inside
	# the callable, which matters when a batch holds tens of thousands of items.
	#
	# The sprites of one object must stay in their own order (fill, outline,
	# detail), so within a z order the object's draw order comes before texture
	# locality; the stable index keeps equal keys in insertion order.
	var native_sorter: Object = _native_sorter()
	if native_sorter != null and int(native_sorter.call(&"version")) >= 2:
		var primary := PackedInt64Array()
		var secondary := PackedInt64Array()
		var tertiary := PackedInt64Array()
		primary.resize(items.size())
		secondary.resize(items.size())
		tertiary.resize(items.size())
		for index in items.size():
			var item: Item = items[index]
			primary[index] = item.z_order
			secondary[index] = item.draw_order
			tertiary[index] = item.texture.get_instance_id()
		var order: PackedInt32Array = native_sorter.call(
				&"sort_indices", primary, secondary, tertiary
		)
		if order.size() == items.size():
			var unsorted: Array[Item] = items.duplicate()
			for index in order.size():
				items[index] = unsorted[order[index]]
		else:
			_sort_items_fallback()
	else:
		_sort_items_fallback()

	_cull = items.size() >= CULL_THRESHOLD
	_buckets.clear()
	_by_channel.clear()
	_spinning.clear()
	_bounds = Rect2()

	for index in items.size():
		var item: Item = items[index]
		var extent: Vector2 = (item.region.size * 0.5).abs() * item.transform.get_scale().abs()
		var item_rect := Rect2(item.transform.origin - extent, extent * 2.0)
		_bounds = item_rect if index == 0 else _bounds.merge(item_rect)
		if not is_zero_approx(item.spin):
			_spinning.append(item)
		if not item.channel.is_empty():
			if not _by_channel.has(item.channel):
				_by_channel[item.channel] = []
				add_to_group(CHANNEL_GROUP_PREFIX + item.channel)
			_by_channel[item.channel].append(item)
		if _cull:
			var bucket: int = int(floor(item.origin_x / BUCKET_WIDTH))
			if not _buckets.has(bucket):
				_buckets[bucket] = []
			_buckets[bucket].append(item)

	_built = true
	_last_visible = PackedInt32Array()
	set_process(_cull or not _spinning.is_empty())
	queue_redraw()


## Snapshots the state produced by the importer. Called before the batch enters
## the tree; later trigger transforms/toggles and item spin are reversible.
func capture_initial_state() -> void:
	_initial_transform = transform
	_initial_visible = visible
	for item: Item in items:
		item.initial_transform = item.transform


## Restores a batch between attempts without rebuilding or reallocating its
## draw list. This is the batched equivalent of deserializing every GDObject.
func reset_runtime_state() -> void:
	transform = _initial_transform
	visible = _initial_visible
	process_mode = Node.PROCESS_MODE_INHERIT
	var changed := false
	for item: Item in _spinning:
		if item.transform != item.initial_transform:
			item.transform = item.initial_transform
			changed = true
	if changed:
		queue_redraw()


## Recolours every item bound to [param channel].
##
## This replaces the per-object [HSVWatcher] a node-based approach needs: one
## pass over an array instead of thousands of signal callbacks.
func apply_channel_color(channel: StringName, color: Color) -> void:
	# Only the items on this channel are touched, via the index built in
	# build(); scanning the whole batch per channel does not scale.
	var affected: Array = _by_channel.get(channel, [])
	if affected.is_empty():
		return
	var changed: bool = false
	for item: Item in affected:
		# The channel supplies the base colour; the object's own HSV shift and
		# opacity are reapplied on top so a channel update refines the tint
		# rather than flattening every object to the same value.
		var tinted: Color = color
		if item.hsv_shift.size() >= 3:
			tinted = Color.from_hsv(
					fposmod(tinted.h + item.hsv_shift[0], 1.0),
					clampf(
							tinted.s + item.hsv_shift[1] if item.hsv_shift[3] > 0.5 else tinted.s * item.hsv_shift[1],
							0.0, 1.0,
					),
					clampf(
							tinted.v + item.hsv_shift[2] if item.hsv_shift[4] > 0.5 else tinted.v * item.hsv_shift[2],
							0.0, 1.0,
					),
			)
		# color.a already carries the channel's opacity; base_alpha is only the
		# object's own. Multiplying the channel alpha in twice squares it and
		# makes faint scenery vanish.
		tinted.a = color.a * item.base_alpha
		item.modulate = tinted
		changed = true
	if changed:
		queue_redraw()


## Local-space bounds of the whole batch, for editor selection and culling.
func get_bounds() -> Rect2:
	return _bounds


## Draw-order key for this batch as a whole: the lowest z order it contains.
##
## Used to rank batches that share a Geometry Dash layer, so a batch is never
## placed in front of one whose contents all sit behind it.
func sort_key() -> int:
	if items.is_empty():
		return 0
	# build() has already sorted items by z order, so the first is the lowest.
	return items[0].z_order


func _process(delta: float) -> void:
	if not _built:
		return

	# Rotating objects - sawblades and the like - carry a degrees-per-second
	# speed in Geometry Dash's key 97.
	if not _spinning.is_empty():
		for item: Item in _spinning:
			item.transform = item.transform.rotated_local(deg_to_rad(item.spin * delta))
		queue_redraw()

	if not _cull:
		return
	var visible_buckets: PackedInt32Array = _visible_buckets()
	if visible_buckets != _last_visible:
		_last_visible = visible_buckets
		queue_redraw()


## Bucket indices overlapping the current camera view.
func _visible_buckets() -> PackedInt32Array:
	var result := PackedInt32Array()
	var camera: Camera2D = get_viewport().get_camera_2d() if is_inside_tree() else null
	if camera == null:
		var all: Array = _buckets.keys()
		all.sort()
		for bucket: int in all:
			result.append(bucket)
		return result

	var half: Vector2 = get_viewport_rect().size * 0.5 / camera.zoom
	var centre: Vector2 = to_local(camera.get_screen_center_position())
	var first: int = int(floor((centre.x - half.x - CULL_MARGIN) / BUCKET_WIDTH))
	var last: int = int(floor((centre.x + half.x + CULL_MARGIN) / BUCKET_WIDTH))
	for bucket in range(first, last + 1):
		if _buckets.has(bucket):
			result.append(bucket)
	return result


func _draw() -> void:
	if items.is_empty():
		return

	if not _cull:
		for item: Item in items:
			_draw_item(item)
		draw_set_transform_matrix(Transform2D.IDENTITY)
		return

	var buckets: PackedInt32Array = _last_visible
	if buckets.is_empty():
		buckets = _visible_buckets()
	for bucket: int in buckets:
		for item: Item in _buckets.get(bucket, []):
			_draw_item(item)
	draw_set_transform_matrix(Transform2D.IDENTITY)


func _draw_item(item: Item) -> void:
	draw_set_transform_matrix(item.transform)
	# Geometry Dash positions objects by their centre, so the quad is drawn
	# centred on the transform origin rather than from its top-left corner.
	draw_texture_rect_region(
			item.texture,
			Rect2(-item.region.size * 0.5, item.region.size),
			item.region,
			item.modulate,
	)
