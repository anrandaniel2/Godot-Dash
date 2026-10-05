class_name PackedDecorations
extends RefCounted
## Column storage for imported decoration objects.
##
## A downloaded level can hold 300,000 decorations. As one [Dictionary] each
## (about twenty Variant keys plus nested arrays) they cost well over a
## kilobyte apiece, and the import, the saved file, the loaded copy and the
## game's cached copy each held all of them - several GB for ORBIT. Here each
## field is one packed array across every object, about 150 bytes per object,
## and var_to_bytes writes the arrays as flat binary.
##
## A layer stores the table under [constant LAYER_KEY]. Runtime builds feed it
## straight to [method GDDecorationLoader.add_packed]; the editor expands it
## into ordinary decoration entries with [method row].

const LAYER_KEY: String = "packed_decorations"

const FLAG_BLENDING: int = 1
const FLAG_GLOW: int = 2
const FLAG_HIGH_DETAIL: int = 4
const FLAG_BASE_HSV: int = 8
const FLAG_DETAIL_HSV: int = 16

## Floats per row in the transform column (x axis, y axis, origin).
const XFORM_STRIDE: int = 6
## Floats per row in the HSV columns ([hue, sat, val, sat_add, val_add]).
const HSV_STRIDE: int = 5
## Floats per row in the object HSV column ([hue, sat, val]).
const OBJECT_HSV_STRIDE: int = 3

var gd_id := PackedInt32Array()
var source_index := PackedInt32Array()
var xform := PackedFloat32Array()
var z_order := PackedInt32Array()
var z_layer := PackedInt32Array()
var tint := PackedColorArray()
var detail_tint := PackedColorArray()
var base_alpha := PackedFloat32Array()
var spin := PackedFloat32Array()
var flags := PackedByteArray()
## Channel id bound to the base / detail layer, -1 when unbound.
var base_channel := PackedInt32Array()
var detail_channel := PackedInt32Array()
var base_hsv := PackedFloat32Array()
var detail_hsv := PackedFloat32Array()
var object_hsv := PackedFloat32Array()
## Row i's groups are group_ids[group_offsets[i] .. group_offsets[i + 1]).
var group_offsets := PackedInt32Array([0])
var group_ids := PackedInt32Array()


## Appends one decoration entry (the [method GDDecorationLoader.to_data]
## format). Returns false when the entry cannot be packed losslessly, so the
## caller keeps it as a dictionary.
func append_entry(entry: Dictionary, index: int) -> bool:
	var channels: Variant = entry.get("color_channels", { })
	if not channels is Dictionary:
		return false
	var base_id: int = _channel_id((channels as Dictionary).get("base", ""))
	var detail_id: int = _channel_id((channels as Dictionary).get("detail", ""))
	if base_id == -2 or detail_id == -2:
		return false
	var row_groups := PackedInt32Array()
	for group: Variant in entry.get("groups", []):
		var group_id: String = str(group).trim_prefix(Constants.GROUP_PREFIX)
		if not group_id.is_valid_int():
			return false
		row_groups.append(int(group_id))
	var b_hsv: PackedFloat32Array = entry.get("hsv_shift", PackedFloat32Array())
	var d_hsv: PackedFloat32Array = entry.get("detail_hsv_shift", PackedFloat32Array())
	if not (b_hsv.is_empty() or b_hsv.size() == HSV_STRIDE) \
			or not (d_hsv.is_empty() or d_hsv.size() == HSV_STRIDE):
		return false

	var t: Transform2D = entry.get("transform", Transform2D.IDENTITY)
	gd_id.append(int(entry.get("gd_object_id", 0)))
	source_index.append(index)
	xform.append_array(PackedFloat32Array([t.x.x, t.x.y, t.y.x, t.y.y, t.origin.x, t.origin.y]))
	z_order.append(int(entry.get("z_order", 0)))
	z_layer.append(int(entry.get("z_layer", 0)))
	var base_tint: Color = entry.get("tint", Color.WHITE)
	tint.append(base_tint)
	detail_tint.append(entry.get("detail_tint", base_tint))
	base_alpha.append(float(entry.get("base_alpha", 1.0)))
	spin.append(float(entry.get("spin", 0.0)))
	var row_flags: int = 0
	if bool(entry.get("blending", false)):
		row_flags |= FLAG_BLENDING
	if bool(entry.get("glow", false)):
		row_flags |= FLAG_GLOW
	if bool(entry.get("high_detail", false)):
		row_flags |= FLAG_HIGH_DETAIL
	if not b_hsv.is_empty():
		row_flags |= FLAG_BASE_HSV
	if not d_hsv.is_empty():
		row_flags |= FLAG_DETAIL_HSV
	flags.append(row_flags)
	base_channel.append(base_id)
	detail_channel.append(detail_id)
	base_hsv.append_array(b_hsv if not b_hsv.is_empty() else _zeros(HSV_STRIDE))
	detail_hsv.append_array(d_hsv if not d_hsv.is_empty() else _zeros(HSV_STRIDE))
	var hsv: Dictionary = entry.get("hsv", { })
	var shift: Array = hsv.get("hsv_shift", [0.0, 0.0, 0.0])
	for k: int in OBJECT_HSV_STRIDE:
		object_hsv.append(float(shift[k]) if k < shift.size() else 0.0)
	group_ids.append_array(row_groups)
	group_offsets.append(group_ids.size())
	return true


func count() -> int:
	return gd_id.size()


## The table as plain packed arrays, ready to store in level data.
func to_data() -> Dictionary:
	return {
		"gd_id": gd_id,
		"source_index": source_index,
		"xform": xform,
		"z_order": z_order,
		"z_layer": z_layer,
		"tint": tint,
		"detail_tint": detail_tint,
		"base_alpha": base_alpha,
		"spin": spin,
		"flags": flags,
		"base_channel": base_channel,
		"detail_channel": detail_channel,
		"base_hsv": base_hsv,
		"detail_hsv": detail_hsv,
		"object_hsv": object_hsv,
		"group_offsets": group_offsets,
		"group_ids": group_ids,
	}


## Number of rows in a stored table.
static func size_of(table: Dictionary) -> int:
	var ids: PackedInt32Array = table.get("gd_id", PackedInt32Array())
	return ids.size()


## Rebuilds row [param i] of a stored table as an ordinary decoration entry,
## identical to what the importer used to keep.
static func row(table: Dictionary, i: int) -> Dictionary:
	var xf: PackedFloat32Array = table.xform
	var o: int = i * XFORM_STRIDE
	var transform := Transform2D(
			Vector2(xf[o], xf[o + 1]), Vector2(xf[o + 2], xf[o + 3]), Vector2(xf[o + 4], xf[o + 5])
	)
	var offsets: PackedInt32Array = table.group_offsets
	var ids: PackedInt32Array = table.group_ids
	var groups: Array = []
	for g: int in range(offsets[i], offsets[i + 1]):
		groups.append(Constants.GROUP_PREFIX + str(ids[g]))
	var channels: Dictionary = { }
	var base_id: int = (table.base_channel as PackedInt32Array)[i]
	var detail_id: int = (table.detail_channel as PackedInt32Array)[i]
	if base_id >= 0:
		channels["base"] = Constants.COLOR_CHANNEL_GROUP_PREFIX + str(base_id)
	if detail_id >= 0:
		channels["detail"] = Constants.COLOR_CHANNEL_GROUP_PREFIX + str(detail_id)
	var row_flags: int = (table.flags as PackedByteArray)[i]
	var b_hsv := PackedFloat32Array()
	if row_flags & FLAG_BASE_HSV:
		b_hsv = (table.base_hsv as PackedFloat32Array).slice(i * HSV_STRIDE, (i + 1) * HSV_STRIDE)
	var d_hsv := PackedFloat32Array()
	if row_flags & FLAG_DETAIL_HSV:
		d_hsv = (table.detail_hsv as PackedFloat32Array).slice(i * HSV_STRIDE, (i + 1) * HSV_STRIDE)
	var oh: PackedFloat32Array = table.object_hsv
	var h: int = i * OBJECT_HSV_STRIDE
	return GDDecorationLoader.to_data(
			(table.gd_id as PackedInt32Array)[i],
			"Decoration%d" % (table.source_index as PackedInt32Array)[i],
			transform,
			groups,
			channels,
			{ "hsv_shift": [oh[h], oh[h + 1], oh[h + 2]], "intensity": 1.0, "alpha": 1.0 },
			(table.z_order as PackedInt32Array)[i],
			(table.z_layer as PackedInt32Array)[i],
			(table.tint as PackedColorArray)[i],
			bool(row_flags & FLAG_BLENDING),
			bool(row_flags & FLAG_GLOW),
			b_hsv,
			(table.base_alpha as PackedFloat32Array)[i],
			(table.spin as PackedFloat32Array)[i],
			bool(row_flags & FLAG_HIGH_DETAIL),
			(table.detail_tint as PackedColorArray)[i],
			d_hsv,
	)


## -1 for no binding, the channel id for "c_<id>", -2 when unparseable.
static func _channel_id(value: Variant) -> int:
	var text: String = str(value)
	if text.is_empty():
		return -1
	var id_text: String = text.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX)
	if id_text == text or not id_text.is_valid_int():
		return -2
	return int(id_text)


static func _zeros(n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	return out
