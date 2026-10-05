class_name PackedTriggers
extends RefCounted
## Column storage for imported native-only trigger records.
##
## A modern effect level carries tens of thousands of triggers that only the
## C++ NativeTriggerRuntime executes. As Dictionaries each one held the object
## entry plus a full copy of its raw Geometry Dash properties, a few KB apiece,
## and the level kept two copies (layer objects and the side index). Here each
## field is one packed array across every record; the raw properties are
## integer keys with their values in one UTF-8 blob. The runtime registers the
## table directly (NativeTriggerRuntime.register_packed_table) and the editor or
## a non-native build expands rows back into ordinary entries with [method row].
##
## Level data stores the table under [constant DATA_KEY].

const DATA_KEY: String = "packed_trigger_records"

## Floats per row in the transform column (x axis, y axis, origin).
const XFORM_STRIDE: int = 6
## color_channels encodings.
const CHANNELS_NONE: int = 0
const CHANNELS_SINGLE: int = 1
const CHANNELS_LAYERS: int = 2

## Every key a native-only trigger entry carries, in the importer's order.
const ENTRY_KEYS: Array[String] = [
	"name", "scene_file_path", "gd_object_id", "transform", "groups", "color_channels",
	"z_order", "z_layer", "hsv", "native_only_trigger", "gd_trigger_flags",
	"gd_source_order", "gd_properties", "hidden",
]

var gd_id := PackedInt32Array()
var source_order := PackedInt32Array()
var flags := PackedByteArray()
var hidden := PackedByteArray()
var xform := PackedFloat32Array()
var scene_index := PackedInt32Array()
var scenes := PackedStringArray()
var z_order := PackedInt32Array()
var z_layer := PackedInt32Array()
var object_hsv := PackedFloat64Array()
var channel_mode := PackedByteArray()
## Channel id per layer, -1 when that layer is unbound.
var base_channel := PackedInt32Array()
var detail_channel := PackedInt32Array()
## Row i's groups are group_ids[group_offsets[i] .. group_offsets[i + 1]).
var group_offsets := PackedInt32Array([0])
var group_ids := PackedInt32Array()
## Row i's properties are prop_keys[prop_offsets[i] .. prop_offsets[i + 1]);
## property k's value is value_bytes[value_offsets[k] .. value_offsets[k + 1])
## as UTF-8.
var prop_offsets := PackedInt32Array([0])
var prop_keys := PackedInt32Array()
var value_offsets := PackedInt32Array([0])
var value_bytes := PackedByteArray()

var _scene_lookup: Dictionary[String, int] = { }


## Appends one native-only trigger entry. Returns false, leaving the table
## unchanged, when the entry cannot be rebuilt exactly by [method row]; the
## caller then keeps it as a Dictionary.
func append_entry(entry: Dictionary) -> bool:
	if entry.size() != ENTRY_KEYS.size():
		return false
	for key: String in ENTRY_KEYS:
		if not entry.has(key):
			return false
	if not bool(entry.native_only_trigger):
		return false
	var id: int = int(entry.gd_object_id)
	var order: int = int(entry.gd_source_order)
	if str(entry.name) != _entry_name(id, order):
		return false
	var hsv: Dictionary = entry.hsv
	var shift: Array = hsv.get("hsv_shift", [])
	if hsv.size() != 3 or shift.size() != 3 or float(hsv.get("intensity", 0.0)) != 1.0 or float(hsv.get("alpha", 0.0)) != 1.0:
		return false
	var row_groups := PackedInt32Array()
	for group: Variant in entry.groups:
		var group_id := _canonical_int(str(group).trim_prefix(Constants.GROUP_PREFIX))
		if group_id < 0 or str(group) != Constants.GROUP_PREFIX + str(group_id):
			return false
		row_groups.append(group_id)
	var mode: int = CHANNELS_NONE
	var base: int = -1
	var detail: int = -1
	var channels: Variant = entry.color_channels
	if channels is String:
		mode = CHANNELS_SINGLE
		base = _channel_id(channels)
		if base < 0:
			return false
	elif channels is Dictionary:
		for key: Variant in channels:
			if key != "base" and key != "detail":
				return false
		if not (channels as Dictionary).is_empty():
			mode = CHANNELS_LAYERS
			if channels.has("base"):
				base = _channel_id(channels.base)
				if base < 0:
					return false
			if channels.has("detail"):
				detail = _channel_id(channels.detail)
				if detail < 0:
					return false
	else:
		return false
	var properties: Dictionary = entry.gd_properties
	var keys := PackedInt32Array()
	var values: Array[PackedByteArray] = []
	for key: Variant in properties:
		var number := _canonical_int(str(key)) if key is String else -1
		var value: Variant = properties[key]
		if number < 0 or not value is String:
			return false
		keys.append(number)
		values.append((value as String).to_utf8_buffer())

	var t: Transform2D = entry.transform
	gd_id.append(id)
	source_order.append(order)
	flags.append(int(entry.gd_trigger_flags))
	hidden.append(1 if bool(entry.hidden) else 0)
	xform.append_array(PackedFloat32Array([t.x.x, t.x.y, t.y.x, t.y.y, t.origin.x, t.origin.y]))
	var scene: String = entry.scene_file_path
	if not _scene_lookup.has(scene):
		_scene_lookup[scene] = scenes.size()
		scenes.append(scene)
	scene_index.append(_scene_lookup[scene])
	z_order.append(int(entry.z_order))
	z_layer.append(int(entry.z_layer))
	object_hsv.append_array(PackedFloat64Array([float(shift[0]), float(shift[1]), float(shift[2])]))
	channel_mode.append(mode)
	base_channel.append(base)
	detail_channel.append(detail)
	group_ids.append_array(row_groups)
	group_offsets.append(group_ids.size())
	prop_keys.append_array(keys)
	for bytes: PackedByteArray in values:
		value_bytes.append_array(bytes)
		value_offsets.append(value_bytes.size())
	prop_offsets.append(prop_keys.size())
	return true


func count() -> int:
	return gd_id.size()


## The table as plain packed arrays, ready to store in level data.
func to_data() -> Dictionary:
	return {
		"gd_id": gd_id,
		"source_order": source_order,
		"flags": flags,
		"hidden": hidden,
		"xform": xform,
		"scene_index": scene_index,
		"scenes": scenes,
		"z_order": z_order,
		"z_layer": z_layer,
		"object_hsv": object_hsv,
		"channel_mode": channel_mode,
		"base_channel": base_channel,
		"detail_channel": detail_channel,
		"group_offsets": group_offsets,
		"group_ids": group_ids,
		"prop_offsets": prop_offsets,
		"prop_keys": prop_keys,
		"value_offsets": value_offsets,
		"value_bytes": value_bytes,
	}


## Number of rows in a stored table.
static func size_of(table: Dictionary) -> int:
	var ids: PackedInt32Array = table.get("gd_id", PackedInt32Array())
	return ids.size()


## Rebuilds row [param i] of a stored table as the entry the importer made.
static func row(table: Dictionary, i: int) -> Dictionary:
	var id: int = (table.gd_id as PackedInt32Array)[i]
	var order: int = (table.source_order as PackedInt32Array)[i]
	var xf: PackedFloat32Array = table.xform
	var o: int = i * XFORM_STRIDE
	var groups: Array = []
	var offsets: PackedInt32Array = table.group_offsets
	var ids: PackedInt32Array = table.group_ids
	for g: int in range(offsets[i], offsets[i + 1]):
		groups.append(Constants.GROUP_PREFIX + str(ids[g]))
	var channels: Variant = { }
	var base: int = (table.base_channel as PackedInt32Array)[i]
	var detail: int = (table.detail_channel as PackedInt32Array)[i]
	match int((table.channel_mode as PackedByteArray)[i]):
		CHANNELS_SINGLE:
			channels = Constants.COLOR_CHANNEL_GROUP_PREFIX + str(base)
		CHANNELS_LAYERS:
			var layers: Dictionary = { }
			if base >= 0:
				layers["base"] = Constants.COLOR_CHANNEL_GROUP_PREFIX + str(base)
			if detail >= 0:
				layers["detail"] = Constants.COLOR_CHANNEL_GROUP_PREFIX + str(detail)
			channels = layers
	var hsv: PackedFloat64Array = table.object_hsv
	var properties: Dictionary = { }
	var prop_offsets_column: PackedInt32Array = table.prop_offsets
	var keys: PackedInt32Array = table.prop_keys
	var value_offsets_column: PackedInt32Array = table.value_offsets
	var bytes: PackedByteArray = table.value_bytes
	for k: int in range(prop_offsets_column[i], prop_offsets_column[i + 1]):
		properties[str(keys[k])] = bytes.slice(value_offsets_column[k], value_offsets_column[k + 1]).get_string_from_utf8()
	return {
		"name": _entry_name(id, order),
		"scene_file_path": (table.scenes as PackedStringArray)[(table.scene_index as PackedInt32Array)[i]],
		"gd_object_id": id,
		"transform": Transform2D(Vector2(xf[o], xf[o + 1]), Vector2(xf[o + 2], xf[o + 3]), Vector2(xf[o + 4], xf[o + 5])),
		"groups": groups,
		"color_channels": channels,
		"z_order": (table.z_order as PackedInt32Array)[i],
		"z_layer": (table.z_layer as PackedInt32Array)[i],
		"hsv": { "hsv_shift": [hsv[i * 3], hsv[i * 3 + 1], hsv[i * 3 + 2]], "intensity": 1.0, "alpha": 1.0 },
		"native_only_trigger": true,
		"gd_trigger_flags": int((table.flags as PackedByteArray)[i]),
		"gd_source_order": order,
		"gd_properties": properties,
		"hidden": (table.hidden as PackedByteArray)[i] != 0,
	}


## Every row of [param table] as entries, for builds that need trigger nodes.
static func rows(table: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for i: int in size_of(table):
		result.append(row(table, i))
	return result


## The importer's entry name ("<object name><source index>").
static func _entry_name(id: int, order: int) -> String:
	return "%s%d" % [GMDObjects.get_object(id).get("name", "Object"), order]


## The value of a canonical non-negative integer string ("7", not "07" or
## "+7"), otherwise -1.
static func _canonical_int(text: String) -> int:
	if not text.is_valid_int() or text.begins_with("+") or text.begins_with("-"):
		return -1
	var value: int = int(text)
	return value if str(value) == text else -1


## The id of a "c_<id>" channel group name, -1 when it is not one.
static func _channel_id(value: Variant) -> int:
	var text: String = str(value)
	if not text.begins_with(Constants.COLOR_CHANNEL_GROUP_PREFIX):
		return -1
	return _canonical_int(text.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX))
