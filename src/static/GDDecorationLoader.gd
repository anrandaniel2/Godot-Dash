@abstract
class_name GDDecorationLoader
## Geometry Dash artwork lookups shared by the importer, the per-object scenes
## and the batched fallback renderer.
##
## The editor uses generated per-type scenes in [code]scenes/gd_objects[/code]
## ([GDObject]) so artwork remains selectable. Runtime level construction uses
## [method build_batches] for all decoration, including mapped types with a
## generated scene, to avoid a SceneTree node hierarchy per placement. Both
## paths read the same packed atlas ([GDSpriteSheet]), cached for the lifetime
## of the process.

## Atlas pixels per Geometry Dash grid unit, for the `-hd` sheets.
##
## Measured from known objects rather than assumed. A one-block object spans 30
## grid units, and every one-block frame - `square_01_001` (object 1),
## `spike_01_001` (object 8), `ring_01_001` (object 36) - is 60x60 pixels in the
## `-hd` atlases. So the artwork is authored at 2 pixels per grid unit.
##
## Getting this wrong is immediately visible across a whole level, so it is
## checked against a known object: 60 px art x (128 / 30 / 2) = exactly 128 px,
## one Godot Dash cell.
const HD_ART_UNITS_PER_GRID_UNIT: float = 2.0

## Spacing between Geometry Dash z layers once mapped onto Godot z indices.
## Wide enough that every batch sharing a layer gets a distinct index without
## spilling into the neighbouring layer.
const Z_LAYER_STRIDE: int = 64

## The Geometry Dash layer that corresponds to the gameplay plane.
##
## GD orders its layers B4(-3), B3(-1), B2(1), B1(3), then the player and solid
## objects, then T1(5), T2(7), T3(9), T4(11). Godot Dash puts gameplay objects
## at z_index 0, so layers are shifted to straddle that: everything up to B1
## lands negative and T1 upwards lands positive. Without the shift, layer 0
## decoration drew on top of the player.
const Z_LAYER_GAMEPLAY: int = 4

static var _sheet: GDSpriteSheet.Sheet
static var _loaded: bool = false


## The parsed atlases, loading them on first use.
static func get_sheet() -> GDSpriteSheet.Sheet:
	if not _loaded:
		_loaded = true
		var started: int = Time.get_ticks_msec()
		_sheet = GDSpriteSheet.load_all()
		var elapsed: int = Time.get_ticks_msec() - started
		if _sheet.frames.is_empty():
			push_warning(
					"GDDecorationLoader: no atlas found in %s" % GDSpriteSheet.ATLAS_DIR
			)
		else:
			print("GDDecorationLoader: %d frames from %s in %d ms, %d objects mapped" % [
				_sheet.frames.size(),
				"%d packed page(s)" % _sheet.pages.size() if _sheet.packed else "the cocos2d sheets",
				elapsed,
				GDObjectFrames.count(),
			])
	return _sheet


## Drops the cached atlases and mapping so changes take effect without a
## restart.
static func reset() -> void:
	_sheet = null
	_loaded = false
	GDObjectFrames.reload()


## Scale that converts atlas pixels into Godot Dash world units.
##
## Only the high-resolution atlases ship now, so this is a constant rather than
## something derived from whichever variant happened to load.
static func art_scale() -> float:
	return float(Constants.CELL_SIZE) / GMDConverter.GD_CELL_SIZE / HD_ART_UNITS_PER_GRID_UNIT


## [code]true[/code] when this object ID can be drawn: it must be mapped, and
## its base frame must exist in the loaded atlases.
static func can_draw(gd_id: int) -> bool:
	if not Config.import_gd_decorations:
		return false
	var frames: GDObjectFrames.ObjectFrames = GDObjectFrames.get_frames(gd_id)
	if frames == null:
		return false
	if not get_sheet().has_frame(frames.base):
		_note_bad_frame(gd_id, frames.base)
		return false
	return true


## Mapped IDs whose artwork is missing, reported once each rather than per
## object.
static var _bad_frames: Dictionary[int, String] = { }


static func _note_bad_frame(gd_id: int, frame: String) -> void:
	if _bad_frames.has(gd_id):
		return
	_bad_frames[gd_id] = frame
	push_warning("GDDecorationLoader: object %d maps to '%s', absent from the atlases" % [gd_id, frame])


## Explains why decoration isn't appearing. Empty when all is well.
static func diagnose() -> String:
	if not Config.import_gd_decorations:
		return "decoration import is turned off in Settings"
	if get_sheet().frames.is_empty():
		return "no atlas found in %s (run tools/build_godot_atlas.py)" % GDSpriteSheet.ATLAS_DIR
	if GDObjectFrames.count() == 0:
		return "object_frames.json is missing or empty"
	if not _bad_frames.is_empty():
		return "%d objects reference frames missing from the atlases" % _bad_frames.size()
	return ""


## Level-data entry for one decoration object.
static func to_data(
		gd_id: int,
		object_name: String,
		transform: Transform2D,
		groups: Array,
		color_channels: Variant,
		hsv: Dictionary,
		z_order: int,
		z_layer: int,
		tint: Color = Color.WHITE,
		blending: bool = false,
		glow: bool = false,
		hsv_shift: PackedFloat32Array = PackedFloat32Array(),
		base_alpha: float = 1.0,
		spin: float = 0.0,
		high_detail: bool = false,
		detail_tint: Color = Color.WHITE,
		detail_hsv_shift: PackedFloat32Array = PackedFloat32Array(),
) -> Dictionary:
	return {
		"name": object_name,
		# Flags this entry as scene-less, so Level routes it back here instead
		# of trying to load() a .tscn.
		"decoration": true,
		"scene_file_path": "",
		"gd_object_id": gd_id,
		"z_order": z_order,
		"z_layer": z_layer,
		"tint": tint,
		"blending": blending,
		"glow": glow,
		"hsv_shift": hsv_shift,
		"base_alpha": base_alpha,
		"spin": spin,
		# Geometry Dash's "high detail" flag (key 103). These objects are the
		# first thing the real game drops on low graphics settings.
		"high_detail": high_detail,
		"detail_tint": detail_tint,
		"detail_hsv_shift": detail_hsv_shift,
		"transform": transform,
		"groups": groups,
		"color_channels": color_channels,
		"hsv": hsv,
	}


## Builds the batched decoration nodes for a whole set of objects in one call.
## The whole-level one-shot builder (see DecorationBatch for why objects are
## grouped this way).
static func build_batches(objects: Array, art_scale_factor: float) -> Array[DecorationBatch]:
	var batches := new_batches()
	for object_data: Dictionary in objects:
		add_object(batches, object_data, art_scale_factor)
	return finish_batches(batches)


## An empty batch accumulator for [method add_object].
static func new_batches() -> Dictionary[String, DecorationBatch]:
	# Preserve the typed Dictionary at runtime. Godot 4.7 rejects an untyped
	# Dictionary passed to _batch_for(Dictionary[String, DecorationBatch]); that
	# made every batched object disappear even though all scripts parsed.
	var batches: Dictionary[String, DecorationBatch] = {}
	return batches


## Feeds one object's decoration into [param batches]. The batch set is a
## plain Dictionary, so callers may add objects one at a time or the whole
## array at once (build_batches) and the grouping result is
## identical - a batch is keyed by the properties a trigger or the renderer
## cares about:
## [codeblock]
## group set + z layer + blend mode
## [/codeblock]
## Group set comes first because it is what makes movement work: a batch joins
## those Geometry Dash groups itself, so a Move or Rotate trigger calling
## [code]get_nodes_in_group()[/code] finds the batch and transforms every object
## inside it at once. Objects that move together are therefore always in the
## same batch, and objects that move differently are never merged.
##
## Blend mode has to split batches too, because it is a property of the
## [CanvasItem] rather than of an individual draw call.
##
## Objects whose artwork is unavailable are skipped; the caller need not handle
## nulls.
static func add_object(batches: Dictionary, object_data: Dictionary, art_scale_factor: float) -> void:
	if not object_data.get("decoration", false):
		return
	var sheet: GDSpriteSheet.Sheet = get_sheet()
	var gd_id: int = int(object_data.get("gd_object_id", 0))
	var frames: GDObjectFrames.ObjectFrames = GDObjectFrames.get_frames(gd_id)
	if frames == null:
		return

	var transform: Transform2D = object_data.get("transform", Transform2D.IDENTITY)
	var z_order: int = int(object_data.get("z_order", 0))
	var z_layer: int = int(object_data.get("z_layer", 0))
	var channels: Variant = object_data.get("color_channels", { })
	var groups: Array = object_data.get("groups", [])
	var tint: Color = object_data.get("tint", Color.WHITE)
	# A channel flagged for blending is drawn additively, which is what
	# gives Geometry Dash levels their glow.
	var blending: bool = bool(object_data.get("blending", false))
	# Most objects explicitly disable their glow (key 96); drawing it anyway
	# stacked thousands of additive white sprites over the level.
	var wants_glow: bool = bool(object_data.get("glow", false))
	# Low detail mode drops the objects Geometry Dash itself marks as
	# decoration-only, which is what key 103 means.
	if Config.ldm and bool(object_data.get("high_detail", false)):
		return
	var hsv_shift: PackedFloat32Array = object_data.get("hsv_shift", PackedFloat32Array())
	var spin: float = float(object_data.get("spin", 0.0))
	var base_alpha: float = float(object_data.get("base_alpha", 1.0))
	var detail_tint: Color = object_data.get("detail_tint", tint)
	var detail_hsv: PackedFloat32Array = object_data.get("detail_hsv_shift", PackedFloat32Array())

	# Sorted so that two objects with the same groups in a different order
	# still land in the same batch.
	var group_key: Array = groups.duplicate()
	group_key.sort()
	var batch: DecorationBatch = _batch_for(batches, group_key, z_layer, blending)

	# Geometry Dash draws an object as a small tree of sprites: the parts
	# with a negative order behind the root sprite, then the root, then the
	# rest. The order is kept as a sub-key beneath the object's z order so
	# a fill never lands on top of the outline it belongs under.
	var base_item: DecorationBatch.Item = null
	var detail_item: DecorationBatch.Item = null
	# The first part that follows the base colour, and the first part of any
	# colour: one of them stands in for the object when its root sprite is
	# Geometry Dash's empty frame. Tracked here rather than searched for
	# afterwards, since the batch may already hold an identical neighbour.
	var first_base_part: DecorationBatch.Item = null
	var first_part: DecorationBatch.Item = null
	var root_drawn: bool = false
	for part: Dictionary in frames.parts:
		var order: int = int(part.get("order", 0))
		if order >= 0 and not root_drawn:
			base_item = _add_root(
					batch, sheet, frames, transform, z_order, gd_id, channels,
					art_scale_factor, tint, hsv_shift, base_alpha, spin,
			)
			root_drawn = true
		var part_item: DecorationBatch.Item = _add_part(
				batch, sheet, part, transform, z_order, gd_id, channels,
				art_scale_factor, tint, hsv_shift, detail_tint, detail_hsv,
				base_alpha, spin,
		)
		if part_item == null:
			continue
		if first_part == null:
			first_part = part_item
		if part_item.layer == "detail":
			if detail_item == null:
				detail_item = part_item
		elif first_base_part == null and str(part.get("color", GDObjectFrames.COLOR_BASE)) == GDObjectFrames.COLOR_BASE:
			first_base_part = part_item
	if not root_drawn:
		base_item = _add_root(
				batch, sheet, frames, transform, z_order, gd_id, channels,
				art_scale_factor, tint, hsv_shift, base_alpha, spin,
		)

	# An object with no visible root sprite is still one object when saved
	# and recoloured, so one of its parts stands in for it: preferably one
	# on the base colour, so the saved channel binding is the right one.
	if base_item == null:
		base_item = first_base_part if first_base_part != null else first_part
		if base_item != null:
			base_item.layer = "base"
	if base_item == null:
		return
	# The object's own placement and colour, kept verbatim so saving does
	# not have to reverse-engineer them from a sprite that may sit off the
	# object's centre or be one of its always-black parts.
	base_item.object_transform = transform
	base_item.object_tint = tint
	base_item.object_hsv_shift = hsv_shift
	base_item.wants_glow = wants_glow
	base_item.high_detail = bool(object_data.get("high_detail", false))

	if frames.has_detail():
		# The detail layer follows the SECONDARY colour channel and its own
		# HSV shift (keys 22/42/44). Passing the base tint here - as an
		# earlier revision did - painted both layers the same colour and
		# flattened every two-tone object in the level.
		detail_item = _add_layer(
				batch, sheet, frames.detail, transform, z_order, gd_id,
				_channel_for(channels, "detail"), "detail", art_scale_factor,
				detail_tint, detail_hsv, base_alpha, spin,
				DRAW_ORDER_DETAIL,
		)
	base_item.detail = detail_item
	if frames.has_glow() and wants_glow:
		# Glow layers are always additive, whatever the channel says, and
		# sit behind the object.
		_add_layer(
				_batch_for(batches, group_key, z_layer, true),
				sheet, frames.glow, transform, z_order, gd_id,
				_channel_for(channels, "base"), "glow", art_scale_factor, tint, hsv_shift, base_alpha,
				spin, DRAW_ORDER_GLOW,
		)

## Finalises a batch set accumulated by [method add_object]: sorts each
## batch's items, drops empty batches (freeing their nodes) and assigns the
## cross-batch draw order, exactly as build_batches always did. Returns the
## finished [DecorationBatch] nodes ready to be added to a layer.
static func finish_batches(batches: Dictionary) -> Array[DecorationBatch]:
	var result: Array[DecorationBatch] = []
	for batch: DecorationBatch in batches.values():
		if batch.items.is_empty():
			continue
		batch.build()
		result.append(batch)
	finalise_batch_order(result)
	return result


## Assigns cross-batch draw order (distinct z indices per shared layer) to a
## list of already-built batches. Kept separate from finish_batches so a
## caller can order batches after building them without re-running build work.
static func finalise_batch_order(batches: Array[DecorationBatch]) -> void:
	_finalise_batch_order(batches)


## Sub-order of the sprites making up one object, within its z order. Parts
## keep their own order from the sprite tree; these are the fixed slots.
const DRAW_ORDER_GLOW: int = -1000
const DRAW_ORDER_ROOT: int = 0
const DRAW_ORDER_DETAIL: int = 1000


## Adds the object's root sprite, or nothing when it is Geometry Dash's empty
## frame (an object drawn entirely from its parts).
static func _add_root(
		batch: DecorationBatch,
		sheet: GDSpriteSheet.Sheet,
		frames: GDObjectFrames.ObjectFrames,
		transform: Transform2D,
		z_order: int,
		gd_id: int,
		channels: Variant,
		art_scale_factor: float,
		tint: Color,
		hsv_shift: PackedFloat32Array,
		base_alpha: float,
		spin: float,
) -> DecorationBatch.Item:
	if not frames.has_visible_root():
		return null
	var root_tint: Color = tint
	var root_channel: StringName = _channel_for(channels, "base")
	var root_hsv: PackedFloat32Array = hsv_shift
	if frames.color == GDObjectFrames.COLOR_BLACK:
		# Sawblades, pits, the "b" block set: black whatever the channel says,
		# so the sprite is not bound to a channel at all - a channel update
		# would otherwise repaint it in the object's colour.
		root_tint = Color(0.0, 0.0, 0.0, tint.a)
		root_channel = &""
		root_hsv = PackedFloat32Array()
	root_tint.a *= frames.opacity
	return _add_layer(
			batch, sheet, frames.base, transform, z_order, gd_id, root_channel, "base",
			art_scale_factor, root_tint, root_hsv, base_alpha * frames.opacity, spin,
			DRAW_ORDER_ROOT,
	)


## Adds one part of a multi-sprite object, placed relative to the object.
static func _add_part(
		batch: DecorationBatch,
		sheet: GDSpriteSheet.Sheet,
		part: Dictionary,
		transform: Transform2D,
		z_order: int,
		gd_id: int,
		channels: Variant,
		art_scale_factor: float,
		tint: Color,
		hsv_shift: PackedFloat32Array,
		detail_tint: Color,
		detail_hsv: PackedFloat32Array,
		base_alpha: float,
		spin: float,
) -> DecorationBatch.Item:
	var frame_name: String = str(part.get("frame", ""))
	var frame: GDSpriteSheet.Frame = sheet.get_frame(frame_name)
	if frame == null:
		return null

	var color_class: String = str(part.get("color", GDObjectFrames.COLOR_BASE))
	var part_tint: Color = tint
	var part_hsv: PackedFloat32Array = hsv_shift
	var channel: StringName = _channel_for(channels, "base")
	var layer: String = "part"
	match color_class:
		GDObjectFrames.COLOR_DETAIL:
			part_tint = detail_tint
			part_hsv = detail_hsv
			channel = _channel_for(channels, "detail")
			layer = "detail"
		GDObjectFrames.COLOR_BLACK:
			# A black fill under an outline. Left unbound: following the
			# object's channel would turn the fill white on the first update.
			part_tint = Color(0.0, 0.0, 0.0, tint.a)
			part_hsv = PackedFloat32Array()
			channel = &""
	var opacity: float = clampf(float(part.get("opacity", 1.0)), 0.0, 1.0)
	part_tint.a *= opacity

	# The part's placement, in Geometry Dash units around the object's centre
	# (30 units to a cell, y up), converted to world units. Its own trim offset
	# is handled by _add_layer, like every other sprite. The anchor shifts the
	# sprite by a fraction of its own size, in its own local frame.
	var gd_to_world: float = float(Constants.CELL_SIZE) / GMDConverter.GD_CELL_SIZE
	var scale := Vector2(float(part.get("sx", 1.0)), float(part.get("sy", 1.0)))
	var rotation: float = -deg_to_rad(float(part.get("rot", 0.0)))
	var anchor := Vector2(float(part.get("ax", 0.0)), float(part.get("ay", 0.0)))
	var local := Transform2D(
			rotation,
			scale,
			0.0,
			Vector2(float(part.get("x", 0.0)), -float(part.get("y", 0.0))) * gd_to_world,
	)
	if anchor != Vector2.ZERO:
		var shift: Vector2 = Vector2(-anchor.x, anchor.y) * frame.region.size * art_scale_factor
		local = local.translated_local(shift)

	return _add_layer(
			batch, sheet, frame_name, transform * local, z_order, gd_id, channel, layer,
			art_scale_factor, part_tint, part_hsv, base_alpha * opacity, spin,
			int(part.get("order", 0)),
	)


## Gives batches that share a z layer distinct z indices.
##
## Sorting inside a batch only orders that batch's own items. Two batches on the
## same layer - a moving group and static scenery, say - would otherwise draw in
## whatever order they sit in the scene tree, letting background pieces land on
## top of foreground ones. That reads as objects heaped in the wrong place.
static func _finalise_batch_order(batches: Array[DecorationBatch]) -> void:
	var by_layer: Dictionary[int, Array] = { }
	for batch: DecorationBatch in batches:
		if not by_layer.has(batch.gd_z_layer):
			by_layer[batch.gd_z_layer] = []
		by_layer[batch.gd_z_layer].append(batch)

	for layer: int in by_layer:
		var group: Array = by_layer[layer]
		# Rank by the batch's own draw order, keyed on its lowest item so a
		# batch never jumps ahead of one whose contents all sit behind it.
		group.sort_custom(
				func(a: DecorationBatch, b: DecorationBatch) -> bool:
					return a.sort_key() < b.sort_key()
		)
		# Additive batches go last within the layer: glow reads as light cast
		# over the scenery rather than something hidden behind it.
		var ordered: Array = (
				group.filter(func(b: DecorationBatch): return not b.gd_blending)
				+ group.filter(func(b: DecorationBatch): return b.gd_blending)
		)

		var span: int = maxi(1, ordered.size())
		for index in ordered.size():
			ordered[index].z_index = clampi(
					(layer - Z_LAYER_GAMEPLAY) * Z_LAYER_STRIDE
					+ int(float(index) / float(span) * float(Z_LAYER_STRIDE - 1)),
					-4096, 4096,
			)


## Fetches or creates the batch for one (group set, z layer, blend) combination.
static func _batch_for(
		batches: Dictionary[String, DecorationBatch],
		group_key: Array,
		z_layer: int,
		additive: bool,
) -> DecorationBatch:
	# The coarse layer decides the batch; ordering within a layer is handled by
	# sorting inside the batch.
	var key: String = "%s|%d|%d" % [",".join(PackedStringArray(group_key)), z_layer, int(additive)]
	if batches.has(key):
		return batches[key]

	var batch := DecorationBatch.new()
	batch.name = "DecorationBatch%d" % batches.size()
	batch.gd_z_layer = z_layer
	batch.gd_blending = additive
	# Geometry Dash layers run B4..T3 as -3..9. They are spread far apart so
	# gameplay objects at the default z of 0 land between the background and
	# foreground layers, and so batches sharing a layer can be ordered against
	# each other (see _finalise_batch_order) without spilling into the next.
	batch.z_index = clampi((z_layer - Z_LAYER_GAMEPLAY) * Z_LAYER_STRIDE, -4096, 4096)
	batch.gd_groups = PackedStringArray(group_key)
	# Joining the groups is what lets triggers move this batch.
	for group: String in group_key:
		batch.add_to_group(group)
	if additive:
		var material := CanvasItemMaterial.new()
		material.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		batch.material = material

	batches[key] = batch
	return batch


## Appends one sprite layer to [param batch], returning the item, or
## [code]null[/code] when the frame cannot be drawn.
##
## Every sprite is drawn at its [i]own[/i] pixel size and trim offset, at the
## one atlas-to-world scale. An earlier revision stretched detail and glow
## layers to the width of the base frame instead; the atlases trim every frame
## to its opaque pixels, so a 5x6 px accent on a 60x60 block was blown up
## twelvefold into a solid white square over the block.
static func _add_layer(
		batch: DecorationBatch,
		sheet: GDSpriteSheet.Sheet,
		frame_name: String,
		object_transform: Transform2D,
		z_order: int,
		gd_id: int,
		channel: StringName,
		layer: String,
		art_scale_factor: float,
		tint: Color = Color.WHITE,
		hsv_shift: PackedFloat32Array = PackedFloat32Array(),
		base_alpha: float = 1.0,
		spin: float = 0.0,
		draw_order: int = 0,
) -> DecorationBatch.Item:
	var frame: GDSpriteSheet.Frame = sheet.get_frame(frame_name)
	if frame == null or frame.atlas == null:
		return null

	var item := DecorationBatch.Item.new()
	item.texture = frame.atlas
	item.region = frame.region
	item.gd_id = gd_id
	item.z_order = z_order
	item.draw_order = draw_order
	item.channel = channel
	item.layer = layer
	item.modulate = tint
	item.hsv_shift = hsv_shift
	item.base_alpha = base_alpha
	item.spin = spin

	# The object transform is in world units and the art is in atlas pixels, so
	# the conversion is folded in here rather than paid at draw time. The trim
	# offset is applied through the basis so it rotates with the object.
	var placement := object_transform
	placement.x *= art_scale_factor
	placement.y *= art_scale_factor
	placement.origin = object_transform.origin + object_transform.basis_xform(
			Vector2(frame.offset.x, -frame.offset.y) * art_scale_factor
	)
	item.transform = placement
	item.origin_x = placement.origin.x

	return batch.add_item(item)


## Colour channel group bound to [param layer], or empty when there is none.
static func _channel_for(channels: Variant, layer: String) -> StringName:
	if channels is Dictionary and channels.has(layer):
		return StringName(str(channels[layer]))
	if (channels is String or channels is StringName) and layer == "base":
		return StringName(str(channels))
	return &""


## Expands a [DecorationBatch] back into one level-data entry per object.
##
## A batch holds one item per sprite [i]layer[/i], so only base layers produce a
## record; detail and glow are implied by the object id when it is rebuilt.
##
## The batch's own transform is folded back in, so decoration that a trigger has
## moved saves at the position it is actually in.
static func serialize_batch(batch: DecorationBatch, art_scale_factor: float) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var groups: Array = []
	for group: String in batch.gd_groups:
		groups.append(group)

	var sheet: GDSpriteSheet.Sheet = get_sheet()

	for item: DecorationBatch.Item in batch.items:
		# Only the base layer stands for the object itself.
		if item.layer != "base":
			continue
		var frames: GDObjectFrames.ObjectFrames = GDObjectFrames.get_frames(item.gd_id)
		if frames == null:
			continue

		# The batch transform is reapplied so any trigger movement is preserved.
		var object_transform: Transform2D = batch.transform * item.object_transform

		var channels: Dictionary = { }
		if not item.channel.is_empty():
			channels["base"] = str(item.channel)
		if item.detail != null and not item.detail.channel.is_empty():
			channels["detail"] = str(item.detail.channel)

		var data: Dictionary = {
			"name": "Decoration%d" % result.size(),
			"decoration": true,
			"scene_file_path": "",
			"gd_object_id": item.gd_id,
			"z_order": item.z_order,
			"z_layer": batch.gd_z_layer,
			"transform": object_transform,
			"groups": groups.duplicate(),
			"color_channels": channels,
			# Appearance is restored from the object's own tint. A channel
			# update repaints the sprites that follow it, so a recoloured level
			# saves the way it currently looks; black parts never leak in.
			"tint": batch.render_color(item) if not item.channel.is_empty() else item.object_tint,
			"blending": batch.gd_blending,
			# Only objects that asked for their glow get it back. Emitting it
			# for every object with a glow frame, as before, buried a reloaded
			# level under additive white.
			"glow": frames.has_glow() and item.wants_glow,
			"hsv_shift": item.object_hsv_shift,
			"base_alpha": item.base_alpha,
			"spin": item.spin,
			"high_detail": item.high_detail,
			"hsv": { "hsv_shift": [0.0, 0.0, 0.0], "intensity": 1.0, "alpha": 1.0 },
		}
		# The detail layer keeps its own colour; without this a reloaded
		# two-tone object came back flattened to its base tint.
		if item.detail != null:
			data["detail_tint"] = batch.render_color(item.detail)
			data["detail_hsv_shift"] = item.detail.hsv_shift
		result.append(data)
	return result
