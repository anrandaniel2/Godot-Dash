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
const BUCKET_WIDTH: float = 256.0

## Runtime native culling retains only the viewport's conservative 2D grid
## cells. Godot clips edge-cell quads exactly before rasterization.
const CULL_MARGIN: float = 0.0

## Every runtime batch is spatially filtered. Dense effect levels often have
## thousands of small group-specific batches; exempting batches below 256
## items caused almost the entire level to remain in the Canvas draw list even
## when only one screen was visible. The native canvas makes this cheap.
const CULL_THRESHOLD: int = 1

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
	## Object-space centre shared by every sprite in one composite object. Atlas
	## trimming means an individual half/quarter-saw's sprite origin is not the
	## centre of the completed saw, so spinning each sprite about its own origin
	## tears the reconstructed artwork apart.
	var spin_pivot: Vector2 = Vector2.ZERO
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
	## Position in the native renderer's packed record array, or -1 when the
	## GDScript fallback renderer is active.
	var render_index: int = -1


## One animated monster (Big Beast, Bat, Spikeball...) drawn by this batch:
## its sprites are re-placed from [MonsterAnimations] whenever its current
## animation advances a frame.
class Monster:
	var name: String = ""
	var object_transform: Transform2D = Transform2D.IDENTITY
	var art_scale_factor: float = 1.0
	## Parallel arrays: the item, the animation sprite index it follows, and
	## its atlas trim offset.
	var bound_items: Array[Item] = []
	var sprite_indices: PackedInt32Array = PackedInt32Array()
	var trim_offsets: PackedVector2Array = PackedVector2Array()
	var animation: String = ""
	var frame: int = 0
	var elapsed: float = 0.0


## Every item in this batch.
var items: Array[Item] = []
## When set, [member items] is emptied once the native renderer owns the
## records. Only runtime builds opt in: editor and practice saving read items.
var release_items_after_native: bool = false
## Whether [member items] was emptied after the native renderer took over.
var _items_released: bool = false
## Lowest item z order, cached for [method sort_key] once items are released.
var _sort_key: int = 0
## Animated monsters in this batch; empty for nearly every batch.
var monsters: Array[Monster] = []

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
## Last blend state applied per channel, so repeated colour-trigger refreshes
## do not push the same blend update through the native boundary again.
var _channel_blend: Dictionary[StringName, bool] = { }
var _last_visible := PackedInt32Array()
var _built: bool = false
var _cull: bool = false
## Local-space bounds of every item, used for a cheap whole-batch visibility
## test before any per-bucket work.
var _bounds: Rect2 = Rect2()
## C++ retained draw-command builder. Kept untyped so source/editor builds can
## parse without the optional platform library.
var _native_canvas: Object
var _native_by_channel: Dictionary[StringName, PackedInt32Array] = {}
## Records that a Blending flip may re-route, by channel: the same items as
## [member _native_by_channel] minus the glow layers, which are always
## additive whatever their channel says.
var _native_blend_by_channel: Dictionary[StringName, PackedInt32Array] = {}
## Batches drawing a monster join this group so a restart can reset them.
const MONSTER_BATCH_GROUP: StringName = &"gd_monster_batches"

## Group pulse state for the portable draw path (see apply_group_pulse).
var _pulse_color: Color = Color.WHITE
var _pulse_weight: float = 0.0


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
	# build() normally runs while the level is detached from the SceneTree.
	# queue_redraw() issued there is not retained by CanvasItem, so explicitly
	# request the first draw once the batch has entered a viewport.
	if _native_canvas != null:
		_native_canvas.queue_redraw()
	else:
		queue_redraw()


## Adds an item, returning it so the caller can keep configuring it.
func add_item(item: Item) -> Item:
	items.append(item)
	_built = false
	return item


## Finalises the batch: sorts for correct layering and texture locality, then
## buckets for culling. Call once, after all items are added.
func build() -> void:
	# Sorting on a precomputed integer key beats comparing object fields inside
	# the callable, which matters when a batch holds tens of thousands of items.
	#
	# The sprites of one object must stay in their own order (fill, outline,
	# detail), so within a z order the object's draw order comes before texture
	# locality; the stable index keeps equal keys in insertion order.
	var native := NativeCore.backend()
	if native != null and items.size() > 1:
		var z_orders := PackedInt32Array()
		var draw_orders := PackedInt32Array()
		var texture_ids := PackedInt64Array()
		z_orders.resize(items.size())
		draw_orders.resize(items.size())
		texture_ids.resize(items.size())
		for index in items.size():
			var item: Item = items[index]
			z_orders[index] = item.z_order
			draw_orders[index] = item.draw_order
			texture_ids[index] = item.texture.get_instance_id()
		var order: PackedInt32Array = native.call(
				&"sort_decoration_indices", z_orders, draw_orders, texture_ids
		)
		var sorted: Array[Item] = []
		sorted.resize(items.size())
		for index in order.size():
			sorted[index] = items[order[index]]
		items = sorted
	else:
		var keyed: Array = []
		keyed.resize(items.size())
		for index in items.size():
			var item: Item = items[index]
			keyed[index] = [item.z_order, item.draw_order, item.texture.get_instance_id(), index, item]
		keyed.sort_custom(
				func(a: Array, b: Array) -> bool:
					if a[0] != b[0]:
						return a[0] < b[0]
					if a[1] != b[1]:
						return a[1] < b[1]
					if a[2] != b[2]:
						return a[2] < b[2]
					return a[3] < b[3]
		)
		for index in keyed.size():
			items[index] = keyed[index][4]

	_cull = items.size() >= CULL_THRESHOLD
	_buckets.clear()
	_by_channel.clear()
	_channel_blend.clear()
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
		if _cull and native == null:
			var bucket: int = int(floor(item.origin_x / BUCKET_WIDTH))
			if not _buckets.has(bucket):
				_buckets[bucket] = []
			_buckets[bucket].append(item)

	_build_native_canvas(native)
	if _native_canvas != null:
		# Native channel indices supersede the Item-reference arrays. Retaining
		# both duplicates one reference for every coloured sprite layer.
		_by_channel.clear()
		_release_items()
	_built = true
	_last_visible = PackedInt32Array()
	# Native canvases poll their camera in C++; keep this GDScript callback only
	# when individual spinning records need transform updates.
	set_process(not _spinning.is_empty() if _native_canvas != null else _cull or not _spinning.is_empty())
	_request_redraw()


## Takes over a renderer that NativePackedDecorationBuilder already filled:
## this batch never holds Items, and [method build] is not called for it.
## [param info] is the builder's batch_info.
func adopt_native_canvas(canvas: Object, info: Dictionary) -> void:
	_native_canvas = canvas
	_items_released = true
	_bounds = info.get("bounds", Rect2())
	_sort_key = int(info.get("sort_key", 0))
	_native_by_channel = _channel_index_lists(info.get("channels", { }))
	_native_blend_by_channel = _channel_index_lists(info.get("blend_channels", { }))
	for channel: StringName in _native_by_channel:
		add_to_group(CHANNEL_GROUP_PREFIX + channel)
	_built = true
	set_process(false)
	_request_redraw()


## Channel id -> record indices, keyed by the channel's group name.
static func _channel_index_lists(lists: Dictionary) -> Dictionary[StringName, PackedInt32Array]:
	var result: Dictionary[StringName, PackedInt32Array] = { }
	for channel_id: int in lists:
		result[StringName(Constants.COLOR_CHANNEL_GROUP_PREFIX + str(channel_id))] = lists[channel_id]
	return result


## Drops every [DecorationBatch.Item] once the native renderer holds the same
## data in packed records. A huge level carries hundreds of thousands of them,
## each a RefCounted object with its own arrays.
func _release_items() -> void:
	if not release_items_after_native or not monsters.is_empty() or items.is_empty():
		return
	_sort_key = items[0].z_order
	items = []
	_spinning.clear()
	_items_released = true


## Packs the sorted item records once and hands them to the retained C++
## CanvasItem. Trigger transforms remain on this parent; only command emission
## and spatial rejection move native, so behaviour is unchanged.
func _build_native_canvas(native: Object) -> void:
	_native_by_channel.clear()
	_native_blend_by_channel.clear()
	# Dropping the Ref frees its RenderingServer RID immediately; no child Node is
	# created or queued for deletion.
	_native_canvas = null
	for item: Item in items:
		item.render_index = -1
	if native == null or not ClassDB.class_exists(&"NativeDecorationRenderer"):
		return
	_native_canvas = ClassDB.instantiate(&"NativeDecorationRenderer")
	if _native_canvas == null:
		return
	var textures: Array = []
	var regions: Array = []
	var transforms: Array = []
	var colors := PackedColorArray()
	var origins := PackedFloat32Array()
	var base_alphas := PackedFloat32Array()
	var hsv_data := PackedFloat32Array()
	var spins := PackedFloat32Array()
	var spin_pivots := PackedFloat32Array()
	textures.resize(items.size())
	regions.resize(items.size())
	transforms.resize(items.size())
	colors.resize(items.size())
	origins.resize(items.size())
	base_alphas.resize(items.size())
	hsv_data.resize(items.size() * 5)
	spins.resize(items.size())
	spin_pivots.resize(items.size() * 2)
	hsv_data.fill(-1.0)
	for index in items.size():
		var item: Item = items[index]
		item.render_index = index
		textures[index] = item.texture
		regions[index] = item.region
		transforms[index] = item.transform
		colors[index] = item.modulate
		origins[index] = item.origin_x
		base_alphas[index] = item.base_alpha
		spins[index] = item.spin
		spin_pivots[index * 2] = item.spin_pivot.x
		spin_pivots[index * 2 + 1] = item.spin_pivot.y
		if item.hsv_shift.size() >= 5:
			for component in 5:
				hsv_data[index * 5 + component] = item.hsv_shift[component]
		if not item.channel.is_empty():
			var channel_indices: PackedInt32Array = _native_by_channel.get(item.channel, PackedInt32Array())
			channel_indices.append(index)
			_native_by_channel[item.channel] = channel_indices
			# Glow layers never re-route on a Blending flip; the flip list
			# therefore carries every other layer only.
			if item.layer != "glow":
				var blend_indices: PackedInt32Array = _native_blend_by_channel.get(item.channel, PackedInt32Array())
				blend_indices.append(index)
				_native_blend_by_channel[item.channel] = blend_indices
	_native_canvas.call(
			&"configure", self, textures, regions, transforms, colors, origins,
			# Keep culling explicit for every node-free renderer, including tiny
			# group-addressable batches common in Thinking Space II.
			base_alphas, hsv_data, spins, spin_pivots,
			not items.is_empty(), BUCKET_WIDTH, CULL_MARGIN,
	)


func _request_redraw() -> void:
	if _native_canvas != null:
		_native_canvas.queue_redraw()
	else:
		queue_redraw()


## Recolours every item bound to [param channel].
##
## This replaces the per-object [HSVWatcher] a node-based approach needs: one
## pass over an array instead of thousands of signal callbacks.
func apply_channel_color(channel: StringName, color: Color) -> void:
	# Native records use packed integer channel indices; do not retain or consult
	# a parallel Array of Item references in that path.
	if _native_canvas != null:
		if _native_by_channel.has(channel):
			_native_canvas.call(&"apply_channel_color", _native_by_channel[channel], color)
		return
	# GDScript fallback: only items on this channel are touched.
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
			# An all-zero shift with multiplicative sliders is Geometry
			# Dash's "HSV enabled but untouched" encoding; multiplying by
			# those zeros paints the item black (GDRweb's shiftColor guard).
			var is_zero_shift: bool = (
				is_zero_approx(item.hsv_shift[0])
				and is_zero_approx(item.hsv_shift[1])
				and is_zero_approx(item.hsv_shift[2])
			)
			var is_neutral_shift: bool = (
				is_zero_approx(item.hsv_shift[0])
				and is_equal_approx(item.hsv_shift[1], 0.0 if item.hsv_shift[3] > 0.5 else 1.0)
				and is_equal_approx(item.hsv_shift[2], 0.0 if item.hsv_shift[4] > 0.5 else 1.0)
			)
			if not is_zero_shift and not is_neutral_shift:
				var sat_val: float = tinted.s + item.hsv_shift[1] if item.hsv_shift[3] > 0.5 else tinted.s * item.hsv_shift[1]
				var val_val: float = tinted.v + item.hsv_shift[2] if item.hsv_shift[4] > 0.5 else tinted.v * item.hsv_shift[2]
				tinted = Color.from_hsv(
					fposmod(tinted.h + item.hsv_shift[0], 1.0),
					clampf(sat_val, 0.0, 1.0),
					clampf(val_val, 0.0, 1.0),
				)
		# color.a already carries the channel's opacity; base_alpha is only the
		# object's own. Multiplying the channel alpha in twice squares it and
		# makes faint scenery vanish.
		tinted.a = color.a * item.base_alpha
		item.modulate = tinted
		if _native_canvas != null and item.render_index >= 0:
			_native_canvas.call(&"set_item_color", item.render_index, tinted)
		changed = true
	if changed:
		_request_redraw()


## Group pulse (1006, key 52 = 1) on this batch: every item lerps from its
## own tint towards [param pulse] by [param weight]. A batch holds one group
## set, so the pulse is batch-wide; weight 0 releases it.
func apply_group_pulse(pulse: Color, weight: float) -> void:
	if _native_canvas != null:
		_native_canvas.call(&"set_group_pulse", pulse, weight)
		return
	var clamped: float = clampf(weight, 0.0, 1.0)
	if is_equal_approx(clamped, _pulse_weight) and (is_zero_approx(clamped) or pulse == _pulse_color):
		return
	_pulse_color = pulse
	_pulse_weight = clamped
	_request_redraw()


## Registers a monster whose sprites this batch draws. [param sprites] holds
## one [code]{item, frame, rest}[/code] dictionary per sprite (atlas frame
## name and Geometry Dash rest position) so each can be bound to the
## animation sprite it follows.
func register_monster(monster_name: String, object_transform: Transform2D, art_scale_factor: float, sprites: Array[Dictionary]) -> void:
	var definition: Dictionary = MonsterAnimations.monster(monster_name)
	var default_animation: String = str(definition.get("default", ""))
	var frames: Array = definition.get("animations", {}).get(default_animation, {}).get("frames", [])
	if frames.is_empty():
		return
	var monster := Monster.new()
	monster.name = monster_name
	monster.object_transform = object_transform
	monster.art_scale_factor = art_scale_factor
	monster.animation = default_animation
	var sheet: GDSpriteSheet.Sheet = GDDecorationLoader.get_sheet()
	for sprite: Dictionary in sprites:
		var item: Item = sprite.get("item")
		var frame_name: String = str(sprite.get("frame", ""))
		var index: int = MonsterAnimations.bind_sprite(frames[0], frame_name, sprite.get("rest", Vector2.ZERO))
		var atlas_frame: GDSpriteSheet.Frame = sheet.get_frame(frame_name) if sheet != null else null
		if item == null or index == -1 or atlas_frame == null:
			continue
		monster.bound_items.append(item)
		monster.sprite_indices.append(index)
		monster.trim_offsets.append(atlas_frame.offset)
	if not monster.bound_items.is_empty():
		monsters.append(monster)
		add_to_group(MONSTER_BATCH_GROUP)


## Animate trigger (1585): plays animation [param animation_id] (key 76) on
## every monster in this batch that has it.
func play_monster_animation(animation_id: int) -> void:
	for monster: Monster in monsters:
		var animation: String = MonsterAnimations.name_for_id(monster.name, animation_id)
		if not animation.is_empty():
			_start_animation(monster, animation)


## Restart: every monster returns to its default animation.
func reset_monster_animations() -> void:
	for monster: Monster in monsters:
		_start_animation(monster, str(MonsterAnimations.monster(monster.name).get("default", "")))


func _start_animation(monster: Monster, animation: String) -> void:
	monster.animation = animation
	monster.frame = 0
	monster.elapsed = 0.0
	_place_monster(monster)


func _advance_monsters(delta: float) -> void:
	for monster: Monster in monsters:
		var animation: Dictionary = MonsterAnimations.monster(monster.name).get("animations", {}).get(monster.animation, {})
		var delay: float = maxf(float(animation.get("delay", 0.05)), 0.001)
		var frame_count: int = animation.get("frames", []).size()
		if frame_count == 0:
			continue
		monster.elapsed += delta
		var advanced: bool = false
		while monster.elapsed >= delay:
			monster.elapsed -= delay
			advanced = true
			monster.frame += 1
			if monster.frame < frame_count:
				continue
			if bool(animation.get("loop", false)):
				monster.frame = 0
				continue
			var following: String = str(animation.get("next", ""))
			if following.is_empty():
				following = str(MonsterAnimations.monster(monster.name).get("default", ""))
			monster.animation = following
			monster.frame = 0
			animation = MonsterAnimations.monster(monster.name).get("animations", {}).get(following, {})
			delay = maxf(float(animation.get("delay", 0.05)), 0.001)
			frame_count = maxi(animation.get("frames", []).size(), 1)
		if advanced:
			_place_monster(monster)


func _place_monster(monster: Monster) -> void:
	var frames: Array = MonsterAnimations.monster(monster.name).get("animations", {}).get(monster.animation, {}).get("frames", [])
	if monster.frame >= frames.size():
		return
	var sprites: Array = frames[monster.frame]
	for i: int in monster.bound_items.size():
		var index: int = monster.sprite_indices[i]
		if index >= sprites.size():
			continue
		var item: Item = monster.bound_items[i]
		item.transform = MonsterAnimations.placement(
				monster.object_transform * MonsterAnimations.sprite_local(sprites[index]),
				monster.art_scale_factor,
				monster.trim_offsets[i],
		)
		if _native_canvas != null and item.render_index >= 0:
			_native_canvas.call(&"set_item_transform", item.render_index, item.transform)
	_request_redraw()


## Flips every item on [param channel] between normal and additive blending.
##
## Geometry Dash colour triggers toggle a channel's Blending state at fire
## time; the glow in modern effect levels comes from those flips, not from
## classic glow sprites. The native renderer owns per-record blend modes, so
## this only forwards the affected indices; the portable path can switch a
## single material per node, which is only correct when the whole batch sits
## on the one channel - mixed batches there keep their import-time blend.
func apply_channel_blending(channel: StringName, additive: bool) -> void:
	if _channel_blend.has(channel) and _channel_blend[channel] == additive:
		return
	_channel_blend[channel] = additive
	# Glow layers are always additive whatever the channel says, so they are
	# excluded from the flip; only base/detail/other items re-route.
	if _native_canvas != null:
		# The native renderer owns the records, and _by_channel is dropped
		# once it takes over (see build), so the flip must address records
		# through the configure-time index list. Reading _by_channel here
		# addressed an empty list and the flip silently did nothing: every
		# mid-level Blending change left whole channels stuck in their
		# import blend, so trigger-faded dark colours rendered as opaque
		# black shapes instead of additive glow.
		if _native_blend_by_channel.has(channel):
			_native_canvas.call(&"set_channel_blending", _native_blend_by_channel[channel], additive)
		return
	var uniform := not items.is_empty()
	for item: Item in items:
		if item.layer == "glow" or item.channel != channel:
			uniform = false
			break
	if uniform:
		material = GDObject._additive_material() if additive else null


## Current rendered tint, including native channel animations. Serialization
## uses this accessor so moving channel updates to C++ does not stale saves or
## practice snapshots.
func render_color(item: Item) -> Color:
	if _native_canvas != null and item.render_index >= 0:
		return _native_canvas.call(&"get_item_color", item.render_index)
	return item.modulate


## Local-space bounds of the whole batch, for editor selection and culling.
func get_bounds() -> Rect2:
	return _bounds


## Draw-order key for this batch as a whole: the lowest z order it contains.
##
## Used to rank batches that share a Geometry Dash layer, so a batch is never
## placed in front of one whose contents all sit behind it.
func sort_key() -> int:
	if _items_released:
		return _sort_key
	if items.is_empty():
		return 0
	# build() has already sorted items by z order, so the first is the lowest.
	return items[0].z_order


func _process(delta: float) -> void:
	if not _built:
		return
	if not monsters.is_empty():
		_advance_monsters(delta)

	# Rotating objects - sawblades and the like - carry a degrees-per-second
	# speed in Geometry Dash's key 97.
	# Native renderers retain spin state and advance the dense animated index in
	# C++; do not cross the Variant boundary once per sprite per frame.
	if _native_canvas == null and not _spinning.is_empty():
		for item: Item in _spinning:
			var angle := deg_to_rad(item.spin * delta)
			var old_origin := item.transform.origin
			item.transform = item.transform.rotated_local(angle)
			# Rotate the trimmed sprite's placement around the complete object's
			# centre as well as rotating its basis. This keeps all duplicated saw
			# wedges locked together around one shared axle.
			item.transform.origin = item.spin_pivot + (old_origin - item.spin_pivot).rotated(angle)
		_request_redraw()

	if _native_canvas != null or not _cull:
		return
	var visible_buckets: PackedInt32Array = _visible_buckets()
	if visible_buckets != _last_visible:
		_last_visible = visible_buckets
		if _native_canvas != null:
			var first: int = visible_buckets[0] if not visible_buckets.is_empty() else 1
			var last: int = visible_buckets[-1] if not visible_buckets.is_empty() else 0
			_native_canvas.call(&"set_visible_buckets", first, last)
		else:
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
	# The child owns the retained command list on native builds. Keeping this
	# method as the fallback preserves editor/source compatibility.
	if _native_canvas != null or items.is_empty():
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
			_pulsed(item.modulate),
	)


func _pulsed(tint: Color) -> Color:
	if _pulse_weight <= 0.0:
		return tint
	var pulsed: Color = tint.lerp(_pulse_color, _pulse_weight)
	pulsed.a = tint.a
	return pulsed
