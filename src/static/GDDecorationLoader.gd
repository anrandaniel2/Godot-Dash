@abstract
class_name GDDecorationLoader
## Builds [Decoration] nodes from the bundled Geometry Dash atlases.
##
## The atlases total several thousand frames, so the parsed sheet is cached for
## the lifetime of the process and shared by every import and every level load.

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
					"GDDecorationLoader: no atlases found in %s" % GDSpriteSheet.ATLAS_DIR
			)
		else:
			print("GDDecorationLoader: %d frames from %d atlases in %d ms, %d objects mapped" % [
				_sheet.frames.size(),
				GDSpriteSheet.SHEET_NAMES.size(),
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
		return "no atlases found in %s" % GDSpriteSheet.ATLAS_DIR
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


## Builds the batched decoration nodes for a whole layer.
##
## Objects are grouped into batches that share everything a trigger or the
## renderer cares about:
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
static func build_batches(objects: Array, art_scale_factor: float) -> Array[DecorationBatch]:
	var sheet: GDSpriteSheet.Sheet = get_sheet()
	# batch key -> DecorationBatch
	var batches: Dictionary[String, DecorationBatch] = { }

	for object_data: Dictionary in objects:
		if not object_data.get("decoration", false):
			continue
		var gd_id: int = int(object_data.get("gd_object_id", 0))
		var frames: GDObjectFrames.ObjectFrames = GDObjectFrames.get_frames(gd_id)
		if frames == null:
			continue

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
			continue
		var hsv_shift: PackedFloat32Array = object_data.get("hsv_shift", PackedFloat32Array())
		var spin: float = float(object_data.get("spin", 0.0))

		# The base frame's drawn size, so detail and glow layers authored at a
		# different resolution can be scaled to cover it.
		var base_frame: GDSpriteSheet.Frame = sheet.get_frame(frames.base)
		var base_size: Vector2 = base_frame.region.size if base_frame != null else Vector2.ZERO
		var base_alpha: float = float(object_data.get("base_alpha", 1.0))

		# Sorted so that two objects with the same groups in a different order
		# still land in the same batch.
		var group_key: Array = groups.duplicate()
		group_key.sort()

		var base_item: DecorationBatch.Item = _add_layer(
				_batch_for(batches, group_key, z_layer, blending),
				sheet, frames.base, transform, z_order, gd_id,
				_channel_for(channels, "base"), "base", art_scale_factor, tint, hsv_shift, base_alpha,
				base_size, spin,
		)
		if base_item != null:
			base_item.wants_glow = wants_glow
			base_item.high_detail = bool(object_data.get("high_detail", false))
		if frames.has_detail():
			# The detail layer follows the SECONDARY colour channel and its own
			# HSV shift (keys 22/42/44). Passing the base tint here - as an
			# earlier revision did - painted both layers the same colour and
			# flattened every two-tone object in the level.
			var detail_item: DecorationBatch.Item = _add_layer(
					_batch_for(batches, group_key, z_layer, blending),
					sheet, frames.detail, transform, z_order, gd_id,
					_channel_for(channels, "detail"), "detail", art_scale_factor,
					object_data.get("detail_tint", tint),
					object_data.get("detail_hsv_shift", PackedFloat32Array()),
					base_alpha, base_size, spin,
			)
			if base_item != null:
				base_item.detail = detail_item
		if frames.has_glow() and wants_glow:
			# Glow layers are always additive, whatever the channel says.
			_add_layer(
					_batch_for(batches, group_key, z_layer, true),
					sheet, frames.glow, transform, z_order, gd_id,
					_channel_for(channels, "base"), "glow", art_scale_factor, tint, hsv_shift, base_alpha,
				base_size, spin,
			)

	var result: Array[DecorationBatch] = []
	for batch: DecorationBatch in batches.values():
		if batch.items.is_empty():
			continue
		batch.build()
		result.append(batch)
	_finalise_batch_order(result)
	return result


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
		base_region_size: Vector2 = Vector2.ZERO,
		spin: float = 0.0,
) -> DecorationBatch.Item:
	var frame: GDSpriteSheet.Frame = sheet.get_frame(frame_name)
	if frame == null or frame.atlas == null:
		return null

	# A detail or glow layer is not always authored at the base layer's
	# resolution - several are half size - so it is scaled to cover the base
	# rather than drawn at its own pixel size.
	var layer_scale: float = 1.0
	if layer != "base" and base_region_size.x > 0.0 and frame.region.size.x > 0.0:
		layer_scale = base_region_size.x / frame.region.size.x

	var item := DecorationBatch.Item.new()
	item.texture = frame.atlas
	item.region = frame.region
	item.gd_id = gd_id
	item.z_order = z_order
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
	placement.x *= art_scale_factor * layer_scale
	placement.y *= art_scale_factor * layer_scale
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

		# Undo the atlas-pixel scaling folded in at build time, then reapply the
		# batch transform so any trigger movement is preserved.
		var object_transform := item.transform
		object_transform.x /= art_scale_factor
		object_transform.y /= art_scale_factor

		var frame: GDSpriteSheet.Frame = sheet.get_frame(frames.base)
		if frame != null:
			object_transform.origin = item.transform.origin - object_transform.basis_xform(
					Vector2(frame.offset.x, -frame.offset.y) * art_scale_factor
			)
		object_transform = batch.transform * object_transform

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
			# Appearance is restored from the item itself, so a level that has
			# been recoloured or faded saves the way it currently looks.
			"tint": item.modulate,
			"blending": batch.gd_blending,
			# Only objects that asked for their glow get it back. Emitting it
			# for every object with a glow frame, as before, buried a reloaded
			# level under additive white.
			"glow": frames.has_glow() and item.wants_glow,
			"hsv_shift": item.hsv_shift,
			"base_alpha": item.base_alpha,
			"spin": item.spin,
			"high_detail": item.high_detail,
			"hsv": { "hsv_shift": [0.0, 0.0, 0.0], "intensity": 1.0, "alpha": 1.0 },
		}
		# The detail layer keeps its own colour; without this a reloaded
		# two-tone object came back flattened to its base tint.
		if item.detail != null:
			data["detail_tint"] = item.detail.modulate
			data["detail_hsv_shift"] = item.detail.hsv_shift
		result.append(data)
	return result


## Serializes a [Decoration] back into level data.
static func serialize(decoration: Decoration) -> Dictionary:
	var data: Dictionary = {
		"name": decoration.name,
		"decoration": true,
		"scene_file_path": "",
		"gd_object_id": decoration.gd_object_id,
		"z_order": decoration.z_index,
		"transform": decoration.transform,
		"groups": decoration.get_groups(),
		"color_channels": { },
		"hsv": decoration.get_meta(Constants.HSV_WATCHER_META).to_data() \
				if decoration.has_meta(Constants.HSV_WATCHER_META) \
				else { "hsv_shift": [0.0, 0.0, 0.0], "intensity": 1.0, "alpha": 1.0 },
	}

	var channels: Dictionary = { }
	for layer_name: String in ["Base", "Detail"]:
		var layer: Node2D = decoration.get_node_or_null(NodePath(layer_name))
		if layer == null:
			continue
		var watcher: HSVWatcher = BaseDetailHandler.use_hsv_watcher(layer)
		if watcher == null:
			continue
		for group: StringName in watcher.get_groups():
			if str(group).begins_with(Constants.COLOR_CHANNEL_GROUP_PREFIX):
				channels[layer_name.to_lower()] = str(group)
				break
	if not channels.is_empty():
		data.color_channels = channels
	return data
