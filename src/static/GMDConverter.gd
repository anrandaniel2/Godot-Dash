@abstract
class_name GMDConverter
## Converts between Geometry Dash level strings and Godot Dash level data.
##
## The level string carried by a `.gmd` file looks like:
## [codeblock]
## kS38,<colors>,kA13,33,...;1,36,2,495,3,105,57,1;1,8,2,615,3,105;...
## [/codeblock]
## The first [code];[/code] separated chunk is the level header (comma separated
## [code]key,value[/code] pairs), and every chunk after it is one object, also
## comma separated [code]key,value[/code] pairs where key [code]1[/code] is the
## object ID, [code]2[/code] the X position and [code]3[/code] the Y position.
##
## [b]Unsupported objects are skipped, never fatal.[/b] Geometry Dash levels are
## full of decoration objects that this project has no scene for. Rather than
## aborting the whole import, [method import_level_string] records each unknown
## ID in [member ImportReport.skipped_ids] and moves on to the next object. Any
## object that raises while being converted is caught the same way, so a single
## broken object can't freeze or crash the importer.

## Geometry Dash object property keys used during conversion.
const Prop := {
	ID = "1",
	X = "2",
	Y = "3",
	FLIP_X = "4",
	FLIP_Y = "5",
	ROTATION = "6",
	MAIN_COLOR_ID = "21",
	SECONDARY_COLOR_ID = "22",
	SCALE = "32",
	GROUPS = "57",
	MAIN_HSV_ENABLED = "41",
	MAIN_HSV = "43",
	TARGET_GROUP = "51",
	DURATION = "10",
	TEXT = "31",
	SCALE_X = "128",
	SCALE_Y = "129",
	Z_ORDER = "25",
	OPACITY = "35",
	TOUCH_TRIGGERED = "11",
	RED = "7",
	GREEN = "8",
	BLUE = "9",
	MOVE_X = "28",
	MOVE_Y = "29",
	TARGET_COLOR_ID = "23",
	DEGREES = "68",
	SINGLE_GROUP = "33", # legacy single group ID, still used by many objects
	EASING = "30",
	FADE_IN = "45",
	HOLD = "46",
	FADE_OUT = "47",
	TIMES_360 = "69",
	LOCK_OBJECT_ROTATION = "70",
	STRENGTH = "75",
	TIME_MOD = "120",
	Z_LAYER = "24",
	DISABLE_GLOW = "96",
	ACTIVATE_GROUP = "56",
	SPAWN_TRIGGERED = "62",
	SECONDARY_HSV_ENABLED = "42",
	SECONDARY_HSV = "44",
	HIGH_DETAIL = "103",
	ROTATION_SPEED = "97",
	DISABLE_ROTATION = "98",
}

## Geometry Dash's reserved channel IDs that alias a [i]level[/i] colour, mapped
## onto [enum Constants.SpecialColorChannel].
##
## The remaining reserved IDs - 1003 (3DL), 1004 (Obj), 1007 (LBG), 1010
## (Black), 1011 (White), 1012 (Lighter), 1013/1014 (MG) - are literal colours
## rather than level properties. They are synthesised into the channel table by
## [method _resolve_channel_styles] and imported as ordinary static channels, so
## an object bound to them is tinted correctly instead of being left white.
const SPECIAL_CHANNELS: Dictionary[int, int] = {
	1000: Constants.SpecialColorChannel.BACKGROUND,
	1001: Constants.SpecialColorChannel.GROUND,
	1002: Constants.SpecialColorChannel.LINE,
	1005: Constants.SpecialColorChannel.P1,
	1006: Constants.SpecialColorChannel.P2,
	1009: Constants.SpecialColorChannel.GROUND,
}

## Reserved channel IDs, by name, for the code below.
const CHANNEL_BG: int = 1000
const CHANNEL_G1: int = 1001
const CHANNEL_LINE: int = 1002
const CHANNEL_3DL: int = 1003
const CHANNEL_OBJ: int = 1004
const CHANNEL_P1: int = 1005
const CHANNEL_P2: int = 1006
const CHANNEL_LBG: int = 1007
const CHANNEL_G2: int = 1009
const CHANNEL_BLACK: int = 1010
const CHANNEL_WHITE: int = 1011
const CHANNEL_LIGHTER: int = 1012
const CHANNEL_MG: int = 1013
const CHANNEL_MG2: int = 1014

## Colour string (kS38) keys.
const ChannelKey := {
	RED = "1",
	GREEN = "2",
	BLUE = "3",
	PLAYER_COLOR = "4",
	BLENDING = "5",
	ID = "6",
	OPACITY = "7",
	COPIED_ID = "9",
	COPY_HSV = "10",
	COPY_OPACITY = "17",
}

## Header keys.
const HeaderKey := {
	COLORS = "kS38",
	BACKGROUND = "kA6",
	GROUND = "kA7",
	GAMEMODE = "kA2",
	MINI = "kA3",
	SPEED = "kA4",
	DUAL = "kA8",
	START_POS = "kA11",
	SONG_OFFSET = "kA13",
	PLATFORMER = "kA22",
	FLIP_GRAVITY = "kA11",
	LINE_COLOR = "kA17",
}

## The Geometry Dash colour trigger.
const COLOR_TRIGGER_ID: int = 899

## Geometry Dash uses a 30x30 pixel grid, Godot Dash uses [member
## Constants.CELL_SIZE] (128) pixels.
const GD_CELL_SIZE: float = 30.0

## Y=0 in Geometry Dash is the ground line, with Y growing upwards.
##
## Objects are children of the level's root node, which [code]GameScene[/code]
## already positions at the ground (y=925), so object coordinates are [i]local[/i]
## to that. Geometry Dash's ground therefore maps to local Y=0, not to 925 -
## adding 925 here as well pushed every imported level a full screen height into
## the ground.
##
## Only the sign flips, because Godot's Y grows downwards.
const GROUND_Y: float = 0.0

## Geometry Dash speed values, indexed by its speed enum, mapped onto the
## [member Level.START_SPEED] table.
const SPEED_PRESETS: Array[int] = [
	EasedSpeedChangerComponent.SpeedPreset.x1, # 0 -> 1x
	EasedSpeedChangerComponent.SpeedPreset.x05, # 1 -> 0.5x
	EasedSpeedChangerComponent.SpeedPreset.x2, # 2 -> 2x
	EasedSpeedChangerComponent.SpeedPreset.x3, # 3 -> 3x
	EasedSpeedChangerComponent.SpeedPreset.x4, # 4 -> 4x
]

## Geometry Dash gamemode enum -> [enum Player.Gamemode].
const GAMEMODES: Array[int] = [
	Player.Gamemode.CUBE,
	Player.Gamemode.SHIP,
	Player.Gamemode.BALL,
	Player.Gamemode.UFO,
	Player.Gamemode.WAVE,
	Player.Gamemode.ROBOT,
	Player.Gamemode.SPIDER,
	Player.Gamemode.SWING,
]


## Summary of what happened during an import, so the UI can tell the creator
## which objects were dropped.
class ImportReport:
	extends RefCounted

	## How many objects were successfully converted.
	var imported: int = 0
	## Geometry Dash object ID -> how many were skipped.
	var skipped_ids: Dictionary[int, int] = { }
	## Objects that raised an error while converting, by ID.
	var failed_ids: Dictionary[int, int] = { }
	## Unsupported block styles that were imported as a plain block instead of
	## being skipped, by Geometry Dash object ID.
	var substituted_block_ids: Dictionary[int, int] = { }
	## Objects instanced from their generated Geometry Dash scene
	## (scenes/gd_objects) or, lacking one, drawn from the atlas, by object ID.
	var decoration_ids: Dictionary[int, int] = { }
	## Group ID -> how many triggers point at it, for groups whose every member
	## object was skipped. Those triggers will warn "target group doesn't
	## contain any objects" when they run.
	var empty_target_groups: Dictionary[String, int] = { }

	var skipped: int:
		get:
			var total: int = 0
			for count: int in skipped_ids.values():
				total += count
			return total

	var failed: int:
		get:
			var total: int = 0
			for count: int in failed_ids.values():
				total += count
			return total

	var substituted_blocks: int:
		get:
			var total: int = 0
			for count: int in substituted_block_ids.values():
				total += count
			return total

	func note_substituted_block(gd_id: int) -> void:
		substituted_block_ids[gd_id] = substituted_block_ids.get(gd_id, 0) + 1

	var decorations: int:
		get:
			var total: int = 0
			for count: int in decoration_ids.values():
				total += count
			return total

	func note_decoration(gd_id: int) -> void:
		decoration_ids[gd_id] = decoration_ids.get(gd_id, 0) + 1

	func note_skipped(gd_id: int) -> void:
		skipped_ids[gd_id] = skipped_ids.get(gd_id, 0) + 1

	func note_failed(gd_id: int) -> void:
		failed_ids[gd_id] = failed_ids.get(gd_id, 0) + 1

	## A one line, human readable summary suitable for a toast.
	func summary() -> String:
		var parts := PackedStringArray(["%d objects imported" % imported])
		if skipped > 0:
			parts.append("%d unsupported skipped (%d kinds)" % [skipped, skipped_ids.size()])
		if decorations > 0:
			parts.append("%d decorations" % decorations)
		if substituted_blocks > 0:
			parts.append("%d unknown blocks imported as plain blocks" % substituted_blocks)
		if failed > 0:
			parts.append("%d failed" % failed)
		if not empty_target_groups.is_empty():
			parts.append("%d trigger target groups left empty" % empty_target_groups.size())
		return ", ".join(parts)

	## The unsupported object IDs, most common first, for the details dialog.
	func skipped_breakdown(limit: int = 12) -> String:
		var ids: Array = skipped_ids.keys()
		ids.sort_custom(func(a: int, b: int): return skipped_ids[a] > skipped_ids[b])
		var lines := PackedStringArray()
		for gd_id: int in ids.slice(0, limit):
			lines.append("  • object %d  ×%d" % [gd_id, skipped_ids[gd_id]])
		if ids.size() > limit:
			lines.append("  • …and %d more object types" % (ids.size() - limit))
		return "\n".join(lines)


#region Import

## Converts a decompressed Geometry Dash level string into a Godot Dash level
## data [Dictionary], the same shape [method Level.from_data] consumes.
##
## [param report] is filled in with per object results. Objects Godot Dash has
## no equivalent for are skipped individually.
static func import_level_string(level_string: String, level_name: String, report: ImportReport = null) -> Dictionary:
	return _import_level_string(level_string, level_name, report, false)


## Server downloads use the bulk C++ parser. Conversion to Godot Dash object
## dictionaries still shares the proven mapping below, but all GD tokenization
## happens in one native call and preserves exact source order.
static func import_online_level_string(level_string: String, level_name: String, report: ImportReport = null) -> Dictionary:
	return _import_level_string(level_string, level_name, report, true)


static func _import_level_string(level_string: String, level_name: String, report: ImportReport, use_online_parser: bool) -> Dictionary:
	if report == null:
		report = ImportReport.new()

	var chunks: PackedStringArray = level_string.split(";", false)
	var header: Dictionary = _parse_pairs(chunks[0]) if chunks.size() > 0 else { }
	var native_objects: Array = []
	var native_validity := PackedByteArray()
	if use_online_parser:
		var native := NativeCore.backend()
		if native != null and native.has_method(&"parse_online_level"):
			var parsed: Dictionary = native.call(&"parse_online_level", level_string)
			header = parsed.get("header", { })
			native_objects = parsed.get("objects", [])
			native_validity = parsed.get("object_validity", PackedByteArray())
			print("[RobTop] C++ parse: chars=%d header_keys=%d chunks=%d valid=%d malformed=%d invalid_numeric=%d odd_pairs=%d duplicate_keys=%d empty_keys=%d x=%s..%s" % [
				level_string.length(), header.size(), int(parsed.get("source_chunks", 0)),
				int(parsed.get("valid_objects", 0)), int(parsed.get("malformed_objects", 0)),
				int(parsed.get("invalid_numeric_objects", 0)), int(parsed.get("odd_pair_chunks", 0)),
				int(parsed.get("duplicate_keys", 0)), int(parsed.get("empty_keys", 0)),
				str(parsed.get("min_x", 0.0)), str(parsed.get("max_x", 0.0)),
			])
			if native_objects.size() != maxi(0, chunks.size() - 1):
				push_warning("Online C++ parser retained %d/%d object chunks" % [native_objects.size(), maxi(0, chunks.size() - 1)])

	# Per-channel appearance: colour, opacity (key 7) and the additive
	# "blending" flag (key 5). This covers every channel an object can name -
	# the ones listed in kS38, the copies they make of each other (key 9) and
	# the reserved 1000+ channels the header never spells out - so no object
	# ends up with a channel the importer cannot colour. An unresolvable
	# channel used to fall back to opaque white, and because most Geometry
	# Dash frames are white masks that only look right once tinted, that is
	# what painted random solid white blocks across imported levels.
	var channel_style: Dictionary[int, Dictionary] = _resolve_channel_styles(
			header.get(HeaderKey.COLORS, "")
	)
	# Which channels the level's objects actually use, filled in as they are
	# converted, so ColorChannelData is only created for channels with a user.
	var used_channels: Dictionary[int, bool] = { }
	var objects: Array[Dictionary] = []
	# Which groups actually ended up with a member object, and which groups
	# triggers point at, so the report can explain empty triggers.
	var populated_groups: Dictionary[String, int] = { }
	var targeted_groups: Dictionary[String, int] = { }

	for chunk_idx in range(1, chunks.size()):
		var chunk: String = chunks[chunk_idx]
		if chunk.strip_edges().is_empty():
			continue
		# Each object is isolated: a malformed or unsupported one is dropped and
		# the loop continues with the next.
		var properties: Dictionary
		if use_online_parser and chunk_idx - 1 < native_objects.size():
			# Native validity is aligned one-to-one with source chunks. Never
			# reinterpret a malformed numeric coordinate as zero or an odd final
			# trigger key as a valid object.
			if chunk_idx - 1 < native_validity.size() and native_validity[chunk_idx - 1] == 0:
				continue
			properties = native_objects[chunk_idx - 1]
		else:
			properties = _parse_pairs(chunk)
		if not properties.has(Prop.ID):
			continue
		var gd_id: int = int(properties[Prop.ID])

		# Remember what every object (supported or not) targets, so an empty
		# trigger can be explained even when its members were skipped.
		var target_group: String = properties.get(Prop.TARGET_GROUP, "")
		if target_group.is_valid_int():
			targeted_groups[target_group] = targeted_groups.get(target_group, 0) + 1

		# Resolution order, best result first:
		#   1. a real Godot Dash scene  - interactive, not just artwork
		#   2. Geometry Dash's own sprite via the atlases
		#   3. a plain block, for solid IDs with neither of the above
		# The plain block deliberately ranks below the atlas sprite: a featureless
		# placeholder is a worse outcome than the object's actual artwork.
		# Never delete grouped artwork based on a toggle near X=0. The documented
		# object string stores toggle state as a runtime action, not an import-time
		# visibility flag; the old heuristic permanently removed every member and
		# could turn effect-heavy 2.2 levels into an empty black screen.
		var object_data: Dictionary = { }
		var kind: int = 0 # 0 = scene, 1 = decoration, 2 = substituted block

		if GMDObjects.MAP.has(gd_id):
			object_data = _object_from_properties(gd_id, properties, chunk_idx, channel_style, used_channels)
		else:
			object_data = _decoration_from_properties(
					gd_id, properties, chunk_idx, channel_style, used_channels
			)
			kind = 1
			if object_data.is_empty() and GMDObjects.is_fallback_block(gd_id):
				object_data = _object_from_properties(gd_id, properties, chunk_idx, channel_style, used_channels)
				kind = 2

		if object_data.is_empty():
			report.note_skipped(gd_id)
			continue

		# A colour trigger needs its target channel to exist at runtime even
		# when no object has been bound to it yet.
		if gd_id == COLOR_TRIGGER_ID:
			var target_color: String = properties.get(Prop.TARGET_COLOR_ID, "").strip_edges()
			if target_color.is_valid_int() and _is_colorable_channel(channel_style, int(target_color)):
				if not SPECIAL_CHANNELS.has(int(target_color)):
					used_channels[int(target_color)] = true

		match kind:
			1:
				report.note_decoration(gd_id)
			2:
				report.note_substituted_block(gd_id)

		# Group membership is tracked for every imported object, whatever its
		# kind, so trigger targets can be reported accurately.
		for group: String in object_data.groups:
			var group_id: String = group.trim_prefix(Constants.GROUP_PREFIX)
			populated_groups[group_id] = populated_groups.get(group_id, 0) + 1

		objects.append(object_data)
		report.imported += 1

	# A trigger whose whole target group was made of unsupported objects will
	# report "no objects" at runtime. Surface that here instead.
	for group_id: String in targeted_groups:
		if not populated_groups.has(group_id):
			report.empty_target_groups[group_id] = targeted_groups[group_id]

	# The runtime channel list. Every channel an imported object is bound to
	# gets a ColorChannelData, including the reserved 1000+ ones, so the
	# watcher that recolours the object at load actually exists. Channels no
	# object uses are left out, as Geometry Dash's own renderer does.
	var color_channels: Array = _build_color_channels(channel_style, used_channels)

	var start_speed_index: int = int(header.get(HeaderKey.SPEED, "0"))
	var start_speed_preset: int = SPEED_PRESETS[start_speed_index] if start_speed_index < SPEED_PRESETS.size() else EasedSpeedChangerComponent.SpeedPreset.x1
	var gamemode_index: int = int(header.get(HeaderKey.GAMEMODE, "0"))
	var gamemode: int = GAMEMODES[gamemode_index] if gamemode_index < GAMEMODES.size() else Player.Gamemode.CUBE

	return {
		"game_version": ProjectSettings.get_setting("application/config/version"),
		"name": level_name,
		"creator": Config.username,
		"description": "",
		"creation_date": int(Time.get_unix_time_from_system()),
		"rating": -1,
		"flashing_lights": false,
		"is_editable": true,
		"song_path": "",
		# kA13 is the creator-authored synchronization offset in seconds.
		# Negative offsets require delayed playback, which Level does not model;
		# preserve every playable (non-negative) offset rather than dropping all
		# online timing information as before.
		"song_start_time": maxf(0.0, float(header.get(HeaderKey.SONG_OFFSET, "0"))),
		"platformer": header.get(HeaderKey.PLATFORMER, "0") == "1",
		"start_position": Constants.DEFAULT_PLAYER_POSITION,
		"start_internal_gamemode": gamemode,
		"start_displayed_gamemode": gamemode,
		"start_freefly": true,
		"start_speed": Level.START_SPEED[clampi(start_speed_preset, 0, Level.START_SPEED.size() - 1)],
		"start_speed_preset": start_speed_preset,
		"start_reverse": false,
		"start_gameplay_rotation_degrees": 0.0,
		"start_gravity_multiplier": 1.0,
		"start_gravity_flip": 1,
		"default_background_color": _background_color(header, color_channels),
		"default_ground_color": _ground_color(header, color_channels),
		"default_line_color": _line_color(header, color_channels),
		"transition_width": 15.0,
		"fade_power": 1.0,
		"move_power": 0.0,
		"scale_power": 0.0,
		"color_channels": color_channels.map(ColorChannelData.to_data),
		"duration": 0.0,
		"layers": [{
			"name": "Imported Layer",
			"objects": objects,
			"locked": false,
		}],
		"active_layer_idx": 0,
		"player_data": {
			"groups": [],
			"hsv": { "hsv_shift": [0.0, 0.0, 0.0], "intensity": 1.0, "alpha": 1.0 },
		},
	}


## Builds the serialized object dictionary for one Geometry Dash object.
## Returns an empty [Dictionary] when the object can't be represented, letting
## the caller skip it.
static func _object_from_properties(
		gd_id: int,
		properties: Dictionary,
		index: int,
		channel_style: Dictionary[int, Dictionary],
		used_channels: Dictionary[int, bool],
) -> Dictionary:
	var description: Dictionary = GMDObjects.get_object(gd_id)
	if description.is_empty():
		return { }
	var scene_path: String = description.scene
	# Static gameplay objects (blocks, slopes, spikes, saws) are built from
	# their generated gd scene: it carries the GD atlas artwork, the authored
	# (PRISTINE) collision and the editor selection box, so no placeholder
	# scene or runtime art swap is involved.
	if GMDObjects.is_static_gameplay_object(gd_id):
		var gd_scene: String = GMDObjects.gd_scene_path(gd_id)
		if not gd_scene.is_empty():
			scene_path = gd_scene
	if not ResourceLoader.exists("res://" + scene_path):
		# The map references a scene that isn't in this build. Skip rather than
		# letting `load()` fail later during instantiation.
		push_warning("GMD: no scene at res://%s for object %d, skipping" % [scene_path, gd_id])
		return { }

	var position := Vector2(
			float(properties.get(Prop.X, "0")) / GD_CELL_SIZE * Constants.CELL_SIZE,
			GROUND_Y - float(properties.get(Prop.Y, "0")) / GD_CELL_SIZE * Constants.CELL_SIZE,
	)
	var rotation_degrees: float = float(properties.get(Prop.ROTATION, "0"))
	var uniform_scale: float = float(properties.get(Prop.SCALE, "1"))
	var scale := Vector2(
			float(properties.get(Prop.SCALE_X, str(uniform_scale))),
			float(properties.get(Prop.SCALE_Y, str(uniform_scale))),
	)
	if is_zero_approx(scale.x):
		scale.x = 1.0
	if is_zero_approx(scale.y):
		scale.y = 1.0
	if properties.get(Prop.FLIP_X, "0") == "1":
		scale.x *= -1.0
	if properties.get(Prop.FLIP_Y, "0") == "1":
		scale.y *= -1.0

	var transform := Transform2D(deg_to_rad(rotation_degrees), scale, 0.0, position)

	var object_data: Dictionary = {
		"name": "%s%d" % [description.get("name", "Object"), index],
		"scene_file_path": scene_path,
		# Kept so the artwork swap can find this object's Geometry Dash sprite,
		# and so the object round-trips with its original identity.
		"gd_object_id": gd_id,
		"transform": transform,
		"groups": _groups_from_properties(properties),
		"color_channels": _color_channels_from_properties(
				gd_id, properties, description, channel_style, used_channels
		),
		"hsv": {
			"hsv_shift": _hsv_shift_from_properties(properties),
			"intensity": 1.0,
			"alpha": 1.0,
		},
	}

	var components: Dictionary = _components_from_properties(gd_id, properties, description)
	if not components.is_empty():
		object_data["components"] = components
		object_data["markers"] = []
	return object_data


## Builds a decoration entry for an object Godot Dash has no scene for.
##
## Returns an empty [Dictionary] when the object can't be drawn, in which case
## the caller skips it exactly as before.
static func _decoration_from_properties(
		gd_id: int,
		properties: Dictionary,
		index: int,
		channel_style: Dictionary[int, Dictionary],
		used_channels: Dictionary[int, bool],
) -> Dictionary:
	if not GDDecorationLoader.can_draw(gd_id):
		return { }

	var position := Vector2(
			float(properties.get(Prop.X, "0")) / GD_CELL_SIZE * Constants.CELL_SIZE,
			GROUND_Y - float(properties.get(Prop.Y, "0")) / GD_CELL_SIZE * Constants.CELL_SIZE,
	)

	var uniform_scale: float = float(properties.get(Prop.SCALE, "1"))
	var scale := Vector2(
			float(properties.get(Prop.SCALE_X, str(uniform_scale))),
			float(properties.get(Prop.SCALE_Y, str(uniform_scale))),
	)
	if is_zero_approx(scale.x):
		scale.x = 1.0
	if is_zero_approx(scale.y):
		scale.y = 1.0
	if properties.get(Prop.FLIP_X, "0") == "1":
		scale.x *= -1.0
	if properties.get(Prop.FLIP_Y, "0") == "1":
		scale.y *= -1.0
	# The atlas-pixel to world-unit conversion is deliberately NOT applied here.
	# It belongs to the artwork, not the object, and GDDecorationLoader._add_layer
	# folds it in per sprite layer. Doing it in both places squares the factor -
	# 4.55x instead of 2.13x - which renders every decoration at double size and
	# turns overlapping sprites into blurry white slabs.
	#
	# If you are tempted to reinstate this line: don't. Check _add_layer first.

	var transform := Transform2D(
			deg_to_rad(float(properties.get(Prop.ROTATION, "0"))),
			scale,
			0.0,
			position,
	)

	# Resolve the object's starting appearance from its channels, so it is
	# drawn correctly before any trigger runs. The channel comes from key 21
	# when the creator set one and from the object's built-in default when
	# not - most objects in a real level rely on the default, and treating a
	# missing key as "no channel" is exactly what left them opaque white.
	var base_id: int = _base_channel_id(gd_id, properties)
	var detail_id: int = _detail_channel_id(gd_id, properties, base_id)
	var style: Dictionary = _style_for(channel_style, base_id)
	var tint: Color = style.get("color", Color.WHITE)
	# Key 43 is a per-object HSV shift applied on top of the channel colour, and
	# 60% of this level's decoration uses one. Ignoring it leaves large areas
	# the wrong hue, so it is baked into the tint here. Sprites on the Black
	# channel are exempt: Geometry Dash draws them black whatever the shift.
	var base_hsv: PackedFloat32Array = PackedFloat32Array()
	if base_id != CHANNEL_BLACK:
		tint = _apply_hsv_shift(tint, properties, Prop.MAIN_HSV_ENABLED, Prop.MAIN_HSV)
		base_hsv = _hsv_shift_array(properties, Prop.MAIN_HSV_ENABLED, Prop.MAIN_HSV)
	# Channel opacity and the object's own opacity are separate factors. The
	# channel's share is folded in here for the initial draw, but only the
	# object's own share is stored as base_alpha - otherwise a later channel
	# update multiplies the channel alpha in a second time and squares it.
	var own_opacity: float = clampf(float(properties.get(Prop.OPACITY, "1")), 0.0, 1.0)
	tint.a = float(style.get("alpha", 1.0)) * own_opacity
	var blending: bool = bool(style.get("blending", false))

	# The detail layer has its own channel (key 22, or the object's default
	# detail channel) and its own HSV shift (keys 42/44). Without these the
	# overlay inherits the base colour and every two-tone object reads as flat.
	var detail_style: Dictionary = _style_for(channel_style, detail_id)
	var detail_tint: Color = detail_style.get("color", Color.WHITE)
	var detail_hsv: PackedFloat32Array = PackedFloat32Array()
	if detail_id != CHANNEL_BLACK:
		detail_tint = _apply_hsv_shift(
				detail_tint, properties, Prop.SECONDARY_HSV_ENABLED, Prop.SECONDARY_HSV
		)
		detail_hsv = _hsv_shift_array(properties, Prop.SECONDARY_HSV_ENABLED, Prop.SECONDARY_HSV)
	detail_tint.a = float(detail_style.get("alpha", 1.0)) * own_opacity
	# Key 96 is "disable glow". Owning a glow frame is not the same as wanting
	# it drawn - almost every object in a real level sets this - so the glow
	# layer is only emitted when the object actually asks for it.
	var glow: bool = properties.get(Prop.DISABLE_GLOW, "0") != "1"

	return GDDecorationLoader.to_data(
			gd_id,
			"Decoration%d" % index,
			transform,
			_groups_from_properties(properties),
			_decoration_channels(gd_id, base_id, detail_id, channel_style, used_channels),
			{
				"hsv_shift": _hsv_shift_from_properties(properties),
				"intensity": 1.0,
				"alpha": 1.0,
			},
			_z_order_from_properties(properties, gd_id),
			_z_layer_from_properties(properties, gd_id),
			tint,
			blending,
			glow,
			base_hsv,
			own_opacity,
			# Key 97 is degrees per second; key 98 disables the object's
			# built-in rotation entirely.
			0.0 if properties.get(Prop.DISABLE_ROTATION, "0") == "1" \
					else float(properties.get(Prop.ROTATION_SPEED, "0")),
			properties.get(Prop.HIGH_DETAIL, "0") == "1",
			detail_tint,
			detail_hsv,
	)


## Binds a decoration's Base/Detail layers to the level's colour channels,
## mirroring how Geometry Dash colours its two-layer objects.
##
## A layer is bound whenever its channel can be coloured, reserved channels
## included, so a later colour trigger (or the level's live background colour)
## reaches it.
static func _decoration_channels(
		gd_id: int,
		base_id: int,
		detail_id: int,
		channel_style: Dictionary[int, Dictionary],
		used_channels: Dictionary[int, bool],
) -> Dictionary:
	# Only bind a layer that the artwork actually has. Roughly half the mapped
	# objects have no detail sprite, and naming a channel for a layer that isn't
	# there leaves the loader looking up a node that was never created. Sprites
	# Geometry Dash always draws black are not bound at all - the loader paints
	# them black outright - so no "black" binding is emitted either.
	var frames: GDObjectFrames.ObjectFrames = GDObjectFrames.get_frames(gd_id)
	if frames == null:
		return { }

	var channels: Dictionary = { }
	if _is_colorable_channel(channel_style, base_id):
		channels["base"] = Constants.COLOR_CHANNEL_GROUP_PREFIX + str(base_id)
		used_channels[base_id] = true
	if frames.has_detail_layer() and _is_colorable_channel(channel_style, detail_id):
		channels["detail"] = Constants.COLOR_CHANNEL_GROUP_PREFIX + str(detail_id)
		used_channels[detail_id] = true
	return channels


## The base colour channel an object uses: key 21 when set, otherwise the
## object's built-in default. Zero means the artwork is drawn untinted.
##
## Sprites Geometry Dash always draws black - pits, sawblades, the "b" block
## set - resolve to the Black channel whatever key 21 says, as they do in
## the game.
static func _base_channel_id(gd_id: int, properties: Dictionary) -> int:
	if GMDDefaultChannels.is_base_black(gd_id):
		return CHANNEL_BLACK
	var raw: String = properties.get(Prop.MAIN_COLOR_ID, "").strip_edges()
	if raw.is_valid_int() and int(raw) > 0:
		return int(raw)
	return GMDDefaultChannels.base_channel(gd_id)


## The detail colour channel an object uses: key 22 when set, otherwise the
## object's built-in default. Objects whose whole artwork is a "detail" sprite
## follow the base channel, as they do in Geometry Dash.
static func _detail_channel_id(gd_id: int, properties: Dictionary, base_id: int) -> int:
	if GMDDefaultChannels.is_detail_black(gd_id):
		return CHANNEL_BLACK
	var raw: String = properties.get(Prop.SECONDARY_COLOR_ID, "").strip_edges()
	if raw.is_valid_int() and int(raw) > 0:
		return int(raw)
	# Untinted artwork (coins, portals) stays untinted on both layers.
	var default_id: int = GMDDefaultChannels.detail_channel(gd_id)
	if default_id == 0 or base_id == 0:
		return base_id
	return default_id


## Plain white, opaque, not blending: what Geometry Dash uses for a channel
## the header never defines, and for "untinted" (channel 0) artwork.
const DEFAULT_STYLE: Dictionary = { "color": Color.WHITE, "alpha": 1.0, "blending": false }


## [code]true[/code] when a layer on [param channel_id] should be bound to a
## colour channel group. Custom channels the header never defined are created
## on first use, in their default white, so a colour trigger can still reach
## them later - Geometry Dash treats an undefined channel exactly that way.
static func _is_colorable_channel(channel_style: Dictionary[int, Dictionary], channel_id: int) -> bool:
	if channel_id <= 0:
		return false
	if channel_style.has(channel_id):
		return true
	if channel_id < CHANNEL_BG:
		channel_style[channel_id] = DEFAULT_STYLE.duplicate()
		return true
	return false


## The resolved style of [param channel_id]. Channel zero (untinted), an
## undefined custom channel and an unknown reserved channel all resolve to
## plain white, as in Geometry Dash.
static func _style_for(channel_style: Dictionary[int, Dictionary], channel_id: int) -> Dictionary:
	if _is_colorable_channel(channel_style, channel_id):
		return channel_style[channel_id]
	return DEFAULT_STYLE


## Fine ordering within a Geometry Dash z layer (key 25).
##
## The coarse layer (key 24) is carried separately rather than being packed into
## the same integer: combining them meant a negative fine order could push an
## object into the layer below, which visibly scrambled the draw order.
static func _z_order_from_properties(properties: Dictionary, gd_id: int = 0) -> int:
	if properties.has(Prop.Z_ORDER):
		return clampi(int(properties.get(Prop.Z_ORDER, "0")), -9999, 9999)
	# Geometry Dash omits the key when the object sits at its built-in order.
	var frames: GDObjectFrames.ObjectFrames = GDObjectFrames.get_frames(gd_id)
	if frames != null and frames.default_z_order != GDObjectFrames.Z_UNKNOWN:
		return frames.default_z_order
	return 0


## The coarse z layer (key 24), or the object's built-in layer when the level
## string omits it: Geometry Dash only writes the key for objects moved off
## their default layer, so a missing key does not mean layer 0.
static func _z_layer_from_properties(properties: Dictionary, gd_id: int = 0) -> int:
	if properties.has(Prop.Z_LAYER):
		return int(properties.get(Prop.Z_LAYER, "0"))
	var frames: GDObjectFrames.ObjectFrames = GDObjectFrames.get_frames(gd_id)
	if frames != null and frames.default_z_layer != GDObjectFrames.Z_UNKNOWN:
		return frames.default_z_layer
	return 0


## Reads the group IDs an object belongs to.
##
## Modern levels store these in key [code]57[/code] as a dot separated list,
## while older ones use the single group key [code]33[/code]. Both are read, so
## a trigger doesn't end up pointing at a group that looks empty just because
## its members used the legacy key.
static func _groups_from_properties(properties: Dictionary) -> Array:
	var group_ids: Array[String] = []
	for group_id: String in properties.get(Prop.GROUPS, "").split(".", false):
		group_ids.append(group_id.strip_edges())
	var single_group: String = properties.get(Prop.SINGLE_GROUP, "").strip_edges()
	if not single_group.is_empty():
		group_ids.append(single_group)

	var groups: Array = []
	for group_id: String in group_ids:
		if not group_id.is_valid_int() or int(group_id) <= 0:
			continue
		var group_name: String = Constants.GROUP_PREFIX + group_id
		if group_name not in groups:
			groups.append(group_name)
	return groups


## Links the object to the imported color channels via key [code]21[/code] /
## [code]22[/code], or the object's built-in defaults when those are absent.
##
## Every channel that can be coloured is bound - reserved channels included -
## so a plain block on the default Obj channel is tinted at load like it is in
## Geometry Dash, instead of keeping its scene's white placeholder texture.
static func _color_channels_from_properties(
		gd_id: int,
		properties: Dictionary,
		description: Dictionary,
		channel_style: Dictionary[int, Dictionary],
		used_channels: Dictionary[int, bool],
) -> Variant:
	var base_id: int = _base_channel_id(gd_id, properties)
	var detail_id: int = _detail_channel_id(gd_id, properties, base_id)

	if not description.get("colorable", false):
		# Objects without Base/Detail carry the channel group directly, which
		# tints the whole scene. Hazards follow their Geometry Dash default
		# (spikes on Obj, sawblades on Black); orbs, pads, portals, triggers
		# and text ship their own coloured artwork, so those are only tinted
		# when the creator explicitly set key 21.
		var scene: String = description.get("scene", "")
		var explicit: String = properties.get(Prop.MAIN_COLOR_ID, "").strip_edges()
		var channel_id: int = base_id
		if not scene.begins_with(GMDObjects.HAZARDS):
			channel_id = int(explicit) if explicit.is_valid_int() else 0
		if _is_colorable_channel(channel_style, channel_id):
			used_channels[channel_id] = true
			return Constants.COLOR_CHANNEL_GROUP_PREFIX + str(channel_id)
		return { }

	var channels: Dictionary = { }
	if _is_colorable_channel(channel_style, base_id):
		channels["base"] = Constants.COLOR_CHANNEL_GROUP_PREFIX + str(base_id)
		used_channels[base_id] = true
	if _is_colorable_channel(channel_style, detail_id):
		channels["detail"] = Constants.COLOR_CHANNEL_GROUP_PREFIX + str(detail_id)
		used_channels[detail_id] = true
	return channels


## The raw HSV shift as
## [code][hue, saturation, value, saturation_additive, value_additive][/code],
## so a batch can reapply it when its channel colour changes. Empty when the
## object has no shift.
static func _hsv_shift_array(
		properties: Dictionary,
		enabled_key: String,
		hsv_key: String,
) -> PackedFloat32Array:
	if properties.get(enabled_key, "0") != "1":
		return PackedFloat32Array()
	var parts: PackedStringArray = properties.get(hsv_key, "").split("a", false)
	if parts.size() < 3:
		return PackedFloat32Array()
	return PackedFloat32Array([
		float(parts[0]) / 360.0,
		float(parts[1]),
		float(parts[2]),
		1.0 if parts.size() > 3 and parts[3] == "1" else 0.0,
		1.0 if parts.size() > 4 and parts[4] == "1" else 0.0,
	])


## Applies a Geometry Dash HSV shift to [param color].
##
## The string is [code]h a s a v a s_checked a v_checked[/code], where the
## checked flags say whether saturation and value are [i]added[/i] or
## [i]multiplied[/i] - Geometry Dash offers both and they look very different.
static func _apply_hsv_shift(
		color: Color,
		properties: Dictionary,
		enabled_key: String,
		hsv_key: String,
) -> Color:
	if properties.get(enabled_key, "0") != "1":
		return color
	var parts: PackedStringArray = properties.get(hsv_key, "").split("a", false)
	if parts.size() < 3:
		return color

	var hue: float = float(parts[0]) / 360.0
	var saturation: float = float(parts[1])
	var value: float = float(parts[2])
	var saturation_additive: bool = parts.size() > 3 and parts[3] == "1"
	var value_additive: bool = parts.size() > 4 and parts[4] == "1"

	var shifted := Color.from_hsv(
			fposmod(color.h + hue, 1.0),
			clampf(color.s + saturation if saturation_additive else color.s * saturation, 0.0, 1.0),
			clampf(color.v + value if value_additive else color.v * value, 0.0, 1.0),
			color.a,
	)
	return shifted


## Parses key [code]43[/code], the [code]h a s a v a s_checked a v_checked[/code]
## HSV string.
static func _hsv_shift_from_properties(properties: Dictionary) -> Array:
	if properties.get(Prop.MAIN_HSV_ENABLED, "0") != "1":
		return [0.0, 0.0, 0.0]
	var raw: String = properties.get(Prop.MAIN_HSV, "")
	var parts: PackedStringArray = raw.split("a", false)
	if parts.size() < 3:
		return [0.0, 0.0, 0.0]
	# Geometry Dash stores hue in degrees.
	return [float(parts[0]) / 360.0, float(parts[1]), float(parts[2])]


## Translates Geometry Dash's easing enum (key [code]30[/code]) into the
## [Tween] ease type and transition [EasingComponent] uses.
static func _easing_from_property(easing: int) -> Array:
	match easing:
		0: return [Tween.EASE_IN_OUT, Tween.TRANS_LINEAR]
		1: return [Tween.EASE_IN_OUT, Tween.TRANS_QUAD]
		2: return [Tween.EASE_IN, Tween.TRANS_QUAD]
		3: return [Tween.EASE_OUT, Tween.TRANS_QUAD]
		4: return [Tween.EASE_IN_OUT, Tween.TRANS_ELASTIC]
		5: return [Tween.EASE_IN, Tween.TRANS_ELASTIC]
		6: return [Tween.EASE_OUT, Tween.TRANS_ELASTIC]
		7: return [Tween.EASE_IN_OUT, Tween.TRANS_BOUNCE]
		8: return [Tween.EASE_IN, Tween.TRANS_BOUNCE]
		9: return [Tween.EASE_OUT, Tween.TRANS_BOUNCE]
		10: return [Tween.EASE_IN_OUT, Tween.TRANS_EXPO]
		11: return [Tween.EASE_IN, Tween.TRANS_EXPO]
		12: return [Tween.EASE_OUT, Tween.TRANS_EXPO]
		13: return [Tween.EASE_IN_OUT, Tween.TRANS_SINE]
		14: return [Tween.EASE_IN, Tween.TRANS_SINE]
		15: return [Tween.EASE_OUT, Tween.TRANS_SINE]
		16: return [Tween.EASE_IN_OUT, Tween.TRANS_BACK]
		17: return [Tween.EASE_IN, Tween.TRANS_BACK]
		18: return [Tween.EASE_OUT, Tween.TRANS_BACK]
		_: return [Tween.EASE_IN_OUT, Tween.TRANS_LINEAR]


## Fills in the public components of triggers and interactables that Godot Dash
## understands.
##
## Only components the target scene actually owns are written (the lists live in
## [member GMDObjects.MAP]), because [method Interactable.use_component_data]
## looks each one up by node name. Properties with no clear Geometry Dash
## equivalent keep their scene defaults.
static func _components_from_properties(
		gd_id: int,
		properties: Dictionary,
		description: Dictionary,
) -> Dictionary:
	var supported: Array = description.get("components", [])
	if supported.is_empty():
		return { }
	var components: Dictionary = { }

	# Target group, shared by every group based trigger.
	var target_group: String = properties.get(Prop.TARGET_GROUP, "").strip_edges()
	if "TargetGroupComponent" in supported and target_group.is_valid_int() and int(target_group) > 0:
		components["TargetGroupComponent"] = { "target_group": Constants.GROUP_PREFIX + target_group }

	# Easing, shared by every timed trigger.
	if "EasingComponent" in supported:
		var easing: Array = _easing_from_property(int(properties.get(Prop.EASING, "0")))
		var easing_data: Dictionary = {
			"duration": maxf(0.0, float(properties.get(Prop.DURATION, "0"))),
			"easing_type": easing[0],
			"easing_transition": easing[1],
		}
		# Pulse style triggers carry a fade in / hold / fade out envelope.
		if properties.has(Prop.FADE_IN) or properties.has(Prop.HOLD) or properties.has(Prop.FADE_OUT):
			easing_data["action"] = EasingComponent.Action.PULSE
			easing_data["fade_in_duration"] = maxf(0.0, float(properties.get(Prop.FADE_IN, "0")))
			easing_data["hold_duration"] = maxf(0.0, float(properties.get(Prop.HOLD, "0")))
			easing_data["fade_out_duration"] = maxf(0.0, float(properties.get(Prop.FADE_OUT, "0")))
		components["EasingComponent"] = easing_data

	match gd_id:
		899: # Color trigger
			if "ColorChannelChangerComponent" in supported:
				components["ColorChannelChangerComponent"] = {
					"color": Color8(
							int(properties.get(Prop.RED, "255")),
							int(properties.get(Prop.GREEN, "255")),
							int(properties.get(Prop.BLUE, "255")),
					),
					"alpha": clampf(float(properties.get(Prop.OPACITY, "1")), 0.0, 1.0),
				}
			if "TargetColorChannelComponent" in supported:
				var target_color: String = properties.get(Prop.TARGET_COLOR_ID, "").strip_edges()
				if target_color.is_valid_int():
					var channel_id: int = int(target_color)
					# 1000+ are the level's own background / ground / line
					# channels, which Godot Dash models as a separate type.
					var special: int = SPECIAL_CHANNELS.get(channel_id, -1)
					if special != -1:
						components["TargetColorChannelComponent"] = {
							"channel_type": TargetColorChannelComponent.Type.LEVEL,
							"target_level_channel": special,
						}
					elif channel_id > 0:
						# Custom channels, and the reserved literal-colour
						# channels (Obj, LBG, Lighter...) that are imported as
						# ordinary channels of their own.
						components["TargetColorChannelComponent"] = {
							"channel_type": TargetColorChannelComponent.Type.CUSTOM,
							"target_color_channel": Constants.COLOR_CHANNEL_GROUP_PREFIX + target_color,
						}
		901: # Move trigger
			if "PositionChangerComponent" in supported:
				components["PositionChangerComponent"] = {
					"mode": PositionChangerComponent.Mode.ADD,
					# Move offsets are in Geometry Dash units; Godot Dash's
					# position is in cells.
					"position": Vector2(
							float(properties.get(Prop.MOVE_X, "0")) / GD_CELL_SIZE,
							float(properties.get(Prop.MOVE_Y, "0")) / GD_CELL_SIZE,
					),
				}
		1007: # Alpha trigger
			if "AlphaChangerComponent" in supported:
				components["AlphaChangerComponent"] = {
					"mode": AlphaChangerComponent.Mode.SET,
					"alpha": clampf(float(properties.get(Prop.OPACITY, "1")), 0.0, 1.0),
				}
		1049: # Toggle trigger
			if "ToggleComponent" in supported and target_group.is_valid_int() and int(target_group) > 0:
				components["ToggleComponent"] = {
					"toggled_groups": [{
						"group": StringName(target_group),
						"state": ToggledGroup.ToggleState.ON if properties.get(Prop.ACTIVATE_GROUP, "0") == "1" else ToggledGroup.ToggleState.OFF,
					}],
				}
		1346: # Rotate trigger
			if "RotationChangerComponent" in supported:
				# Full turns (key 69) are stored separately from the remainder.
				var degrees: float = float(properties.get(Prop.DEGREES, "0"))
				degrees += float(properties.get(Prop.TIMES_360, "0")) * 360.0
				components["RotationChangerComponent"] = {
					"mode": RotationChangerComponent.Mode.ADD,
					"rotation": degrees,
					"rotate_around_self": properties.get(Prop.LOCK_OBJECT_ROTATION, "0") != "1",
				}
		1520: # Shake trigger
			if "CameraShakeComponent" in supported:
				components["CameraShakeComponent"] = {
					"strength": maxf(0.01, float(properties.get(Prop.STRENGTH, "5"))),
				}
		1916: # Camera offset trigger
			if "CameraOffsetChangerComponent" in supported:
				components["CameraOffsetChangerComponent"] = {
					"mode": CameraOffsetChangerComponent.Mode.SET,
					"offset": Vector2(
							float(properties.get(Prop.MOVE_X, "0")) / GD_CELL_SIZE,
							float(properties.get(Prop.MOVE_Y, "0")) / GD_CELL_SIZE,
					),
				}
		2015: # Camera rotate trigger
			if "CameraRotationChangerComponent" in supported:
				components["CameraRotationChangerComponent"] = {
					"mode": CameraRotationChangerComponent.Mode.ADD,
					"rotation_degrees": float(properties.get(Prop.DEGREES, "0")),
				}
		1935: # Timewarp trigger
			if "TimescaleChangerComponent" in supported:
				var time_mod: float = float(properties.get(Prop.TIME_MOD, "1"))
				components["TimescaleChangerComponent"] = {
					"time_scale": clampf(time_mod if time_mod > 0.0 else 1.0, 0.01, 10.0),
				}
		914: # Text object
			if "TextComponent" in supported:
				var encoded: String = properties.get(Prop.TEXT, "")
				var decoded := Marshalls.base64_to_utf8(encoded.replace("-", "+").replace("_", "/")) if not encoded.is_empty() else ""
				components["TextComponent"] = { "text": decoded }

	return components


## Resolves the appearance of every colour channel a level can reference.
##
## The [code]kS38[/code] colour string is [code]|[/code] separated, each entry
## being [code]key_value[/code] pairs. Beyond the literal RGB (keys 1-3) an
## entry may [i]copy[/i] another channel (key 9, with an HSV shift in key 10 and
## optionally that channel's opacity via key 17) or take a player colour
## (key 4). Both were previously ignored, which left every copying channel at
## its default of white.
##
## The reserved channels (1000+) are seeded with their level defaults first,
## then overridden by whatever the header says, so an object bound to one is
## always colourable even when the header omits it - which it does for 1004,
## 1007, 1010, 1011 and 1012 in every level Geometry Dash writes.
static func _resolve_channel_styles(raw: String) -> Dictionary[int, Dictionary]:
	var styles: Dictionary[int, Dictionary] = { }
	var entries: Dictionary[int, Dictionary] = { }
	for entry: String in raw.split("|", false):
		var values: Dictionary[String, String] = _parse_channel_entry(entry)
		var channel_id: String = values.get(ChannelKey.ID, "")
		if not channel_id.is_valid_int() or int(channel_id) <= 0:
			continue
		entries[int(channel_id)] = values

	# Level defaults for the reserved channels.
	var background: Color = _literal_channel_color(entries, CHANNEL_BG, Constants.DEFAULT_BACKGROUND_COLOR)
	var ground: Color = _literal_channel_color(entries, CHANNEL_G1, Constants.DEFAULT_GROUND_COLOR)
	var p1: Color = Config.primary_color
	var p2: Color = Config.secondary_color
	var defaults: Dictionary[int, Color] = {
		CHANNEL_BG: background,
		CHANNEL_G1: ground,
		CHANNEL_LINE: _literal_channel_color(entries, CHANNEL_LINE, Constants.DEFAULT_LINE_COLOR),
		CHANNEL_3DL: Color.WHITE,
		CHANNEL_OBJ: Color.WHITE,
		CHANNEL_P1: p1,
		CHANNEL_P2: p2,
		CHANNEL_LBG: _lighter_background(background, p1),
		CHANNEL_G2: _literal_channel_color(entries, CHANNEL_G2, ground),
		CHANNEL_BLACK: Color.BLACK,
		CHANNEL_WHITE: Color.WHITE,
		CHANNEL_LIGHTER: Color.WHITE,
		CHANNEL_MG: Color.WHITE,
		CHANNEL_MG2: Color.WHITE,
	}
	for channel_id: int in defaults:
		styles[channel_id] = {
			"color": defaults[channel_id],
			"alpha": 1.0,
			# Geometry Dash always draws the line channel additively.
			"blending": channel_id == CHANNEL_LINE,
		}
	# The player colours are not stored in the level, so any header entry for
	# them is really the copy/HSV settings on top of the local player colour.
	var pinned: PackedInt32Array = [
		CHANNEL_BLACK, CHANNEL_WHITE, CHANNEL_P1, CHANNEL_P2, CHANNEL_LBG,
	]

	# Literal colours first, so that copies made below have something to copy.
	for channel_id: int in entries:
		var values: Dictionary[String, String] = entries[channel_id]
		var style: Dictionary = {
			"color": _entry_color(values, styles.get(channel_id, { }).get("color", Color.WHITE)),
			"alpha": clampf(float(values.get(ChannelKey.OPACITY, "1")), 0.0, 1.0),
			"blending": values.get(ChannelKey.BLENDING, "0") == "1" or channel_id == CHANNEL_LINE,
		}
		if pinned.has(channel_id):
			style["color"] = defaults[channel_id]
		var player: int = int(values.get(ChannelKey.PLAYER_COLOR, "-1"))
		if player == 1:
			style["color"] = p1
		elif player == 2:
			style["color"] = p2
		styles[channel_id] = style

	# Copies. A copy can itself copy another copy, so resolve in passes; the
	# pass count is bounded so a cycle cannot hang the import.
	for _pass in 8:
		var changed: bool = false
		for channel_id: int in entries:
			var values: Dictionary[String, String] = entries[channel_id]
			var source_id: int = int(values.get(ChannelKey.COPIED_ID, "0"))
			if source_id <= 0 or source_id == channel_id or not styles.has(source_id):
				continue
			var source: Dictionary = styles[source_id]
			var color: Color = _shift_hsv_string(source.get("color", Color.WHITE), values.get(ChannelKey.COPY_HSV, ""))
			var alpha: float = float(styles[channel_id].get("alpha", 1.0))
			if values.get(ChannelKey.COPY_OPACITY, "0") == "1":
				alpha = float(source.get("alpha", 1.0))
			var current: Dictionary = styles[channel_id]
			if current.get("color", Color.WHITE) != color or not is_equal_approx(float(current.get("alpha", 1.0)), alpha):
				current["color"] = color
				current["alpha"] = alpha
				changed = true
			current["copied_from"] = source_id
			current["copy_plain"] = _hsv_string_is_neutral(values.get(ChannelKey.COPY_HSV, ""))
		if not changed:
			break

	# Lighter is derived from Obj, which the header may have recoloured.
	if not entries.has(CHANNEL_LIGHTER):
		styles[CHANNEL_LIGHTER]["color"] = _lighten(styles[CHANNEL_OBJ].get("color", Color.WHITE))
	return styles


## The runtime [ColorChannelData] list for every channel an object uses.
##
## Channels that alias a level colour (background, ground, line, players) are
## created as [i]copy[/i] channels so they follow the live level colour and any
## trigger that changes it. Everything else is a static colour.
static func _build_color_channels(
		channel_style: Dictionary[int, Dictionary],
		used_channels: Dictionary[int, bool],
) -> Array:
	var channels: Array = []
	var ids: Array = used_channels.keys()
	ids.sort()
	for channel_id: int in ids:
		if not channel_style.has(channel_id):
			continue
		var style: Dictionary = channel_style[channel_id]
		var channel := ColorChannelData.new()
		channel.associated_group = Constants.COLOR_CHANNEL_GROUP_PREFIX + str(channel_id)
		channel.alpha = float(style.get("alpha", 1.0))
		channel.color = style.get("color", Color.WHITE)
		# A channel that is, or plainly copies, a level colour follows that
		# colour live. A copy with an HSV shift keeps its resolved colour
		# instead, since the runtime copy has no equivalent shift.
		var source_id: int = _copy_source(channel_style, channel_id)
		if SPECIAL_CHANNELS.has(source_id):
			channel.copy = true
			channel.copied_channel = SPECIAL_CHANNELS[source_id] as Constants.SpecialColorChannel
		channels.append(channel)
	return channels


## Follows a chain of plain (unshifted) copies back to its origin.
static func _copy_source(channel_style: Dictionary[int, Dictionary], channel_id: int) -> int:
	var current: int = channel_id
	for _step in 8:
		var style: Dictionary = channel_style.get(current, { })
		if not style.has("copied_from") or not bool(style.get("copy_plain", false)):
			break
		current = int(style["copied_from"])
	return current


## The literal RGB of a header entry, or [param fallback] when it has none.
static func _entry_color(values: Dictionary[String, String], fallback: Color) -> Color:
	if not (values.has(ChannelKey.RED) or values.has(ChannelKey.GREEN) or values.has(ChannelKey.BLUE)):
		return fallback
	return Color8(
			int(values.get(ChannelKey.RED, "255")),
			int(values.get(ChannelKey.GREEN, "255")),
			int(values.get(ChannelKey.BLUE, "255")),
	)


static func _literal_channel_color(entries: Dictionary[int, Dictionary], channel_id: int, fallback: Color) -> Color:
	if not entries.has(channel_id):
		return fallback
	return _entry_color(entries[channel_id], fallback)


## Geometry Dash's LBG channel: the background desaturated a little, blended
## towards the player colour as the background darkens.
static func _lighter_background(background: Color, player: Color) -> Color:
	var shifted := Color.from_hsv(
			background.h,
			maxf(background.s - 0.2, 0.0),
			background.v,
	)
	return player.lerp(shifted, background.v)


## The "Lighter" channel: a brightened, slightly desaturated copy of [param color].
static func _lighten(color: Color) -> Color:
	return Color.from_hsv(color.h, maxf(color.s - 0.2, 0.0), minf(color.v + 0.2, 1.0), color.a)


## [code]true[/code] when an HSV string leaves a colour unchanged.
static func _hsv_string_is_neutral(hsv: String) -> bool:
	var parts: PackedStringArray = hsv.split("a", false)
	if parts.size() < 3:
		return true
	var saturation_additive: bool = parts.size() > 3 and parts[3] == "1"
	var value_additive: bool = parts.size() > 4 and parts[4] == "1"
	return (
			is_zero_approx(fposmod(float(parts[0]), 360.0))
			and is_equal_approx(float(parts[1]), 0.0 if saturation_additive else 1.0)
			and is_equal_approx(float(parts[2]), 0.0 if value_additive else 1.0)
	)


## Applies a [code]h a s a v a s_checked a v_checked[/code] HSV string to a colour.
static func _shift_hsv_string(color: Color, hsv: String) -> Color:
	var parts: PackedStringArray = hsv.split("a", false)
	if parts.size() < 3:
		return color
	var saturation_additive: bool = parts.size() > 3 and parts[3] == "1"
	var value_additive: bool = parts.size() > 4 and parts[4] == "1"
	var saturation: float = float(parts[1])
	var value: float = float(parts[2])
	return Color.from_hsv(
			fposmod(color.h + float(parts[0]) / 360.0, 1.0),
			clampf(color.s + saturation if saturation_additive else color.s * saturation, 0.0, 1.0),
			clampf(color.v + value if value_additive else color.v * value, 0.0, 1.0),
			color.a,
	)


static func _parse_channel_entry(entry: String) -> Dictionary[String, String]:
	var fields: PackedStringArray = entry.split("_", false)
	var values: Dictionary[String, String] = { }
	for i in range(0, fields.size() - 1, 2):
		values[fields[i]] = fields[i + 1]
	return values


static func _special_channel_color(raw: String, channel_id: int, fallback: Color) -> Color:
	for entry: String in raw.split("|", false):
		var values: Dictionary[String, String] = _parse_channel_entry(entry)
		if int(values.get(ChannelKey.ID, "-1")) == channel_id:
			return _entry_color(values, fallback)
	return fallback


static func _background_color(header: Dictionary, _channels: Array) -> Color:
	return _special_channel_color(header.get(HeaderKey.COLORS, ""), 1000, Constants.DEFAULT_BACKGROUND_COLOR)


static func _ground_color(header: Dictionary, _channels: Array) -> Color:
	return _special_channel_color(header.get(HeaderKey.COLORS, ""), 1001, Constants.DEFAULT_GROUND_COLOR)


static func _line_color(header: Dictionary, _channels: Array) -> Color:
	return _special_channel_color(header.get(HeaderKey.COLORS, ""), 1002, Constants.DEFAULT_LINE_COLOR)


static func _parse_pairs(chunk: String) -> Dictionary:
	var native := NativeCore.backend()
	if native != null:
		return native.call(&"parse_gd_pairs", chunk)
	var pairs: Dictionary[String, String] = { }
	var fields: PackedStringArray = chunk.split(",", false)
	for i in range(0, fields.size() - 1, 2):
		pairs[fields[i]] = fields[i + 1]
	return pairs

#endregion


#region Export

## Converts Godot Dash level data back into a Geometry Dash level string.
## Objects with no Geometry Dash counterpart are skipped and counted in
## [param report].
static func export_level_string(level_data: Dictionary, report: ImportReport = null) -> String:
	if report == null:
		report = ImportReport.new()

	var chunks := PackedStringArray([_build_header(level_data)])

	for layer_data: Dictionary in level_data.get("layers", []):
		for object_data: Dictionary in layer_data.get("objects", []):
			# Pure decoration has no Geometry Dash gameplay identity and is not
			# exported (Godot Dash saves it separately); anything else is one
			# of the supported gameplay objects. The gd_object_id recorded at
			# import is authoritative when present (static objects now live in
			# per-ID generated scenes); scene paths only resolve older entries.
			if object_data.get("decoration", false):
				report.note_skipped(0)
				continue
			var gd_id: int = -1
			var object_id: Variant = object_data.get("gd_object_id", null)
			if object_id != null:
				gd_id = int(object_id)
			else:
				gd_id = GMDObjects.get_gd_id(str(object_data.get("scene_file_path", "")))
			if gd_id <= 0:
				report.note_skipped(0)
				continue
			var chunk: String = _object_to_chunk(gd_id, object_data)
			if chunk.is_empty():
				report.note_failed(gd_id)
				continue
			chunks.append(chunk)
			report.imported += 1

	return ";".join(chunks) + ";"


static func _build_header(level_data: Dictionary) -> String:
	var colors := PackedStringArray()
	var background: Color = level_data.get("default_background_color", Constants.DEFAULT_BACKGROUND_COLOR)
	var ground: Color = level_data.get("default_ground_color", Constants.DEFAULT_GROUND_COLOR)
	var line: Color = level_data.get("default_line_color", Constants.DEFAULT_LINE_COLOR)
	colors.append(_color_channel_entry(1000, background, 1.0))
	colors.append(_color_channel_entry(1001, ground, 1.0))
	colors.append(_color_channel_entry(1002, line, 1.0))

	for channel_data: Dictionary in level_data.get("color_channels", []):
		var group: String = str(channel_data.get("associated_group", ""))
		var channel_id: String = group.trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX)
		if not channel_id.is_valid_int() or int(channel_id) <= 0:
			continue
		# Reserved channels are Geometry Dash's own; the background, ground
		# and line are written above and the rest must not be redefined.
		if int(channel_id) >= 1000:
			continue
		colors.append(_color_channel_entry(
				int(channel_id),
				channel_data.get("color", Color.WHITE),
				float(channel_data.get("alpha", 1.0)),
		))

	var speed_preset: int = int(level_data.get("start_speed_preset", EasedSpeedChangerComponent.SpeedPreset.x1))
	var gd_speed: int = maxi(0, SPEED_PRESETS.find(speed_preset))
	var gamemode: int = maxi(0, GAMEMODES.find(int(level_data.get("start_internal_gamemode", Player.Gamemode.CUBE))))

	return ",".join(PackedStringArray([
		HeaderKey.COLORS, "|".join(colors),
		HeaderKey.GAMEMODE, str(gamemode),
		HeaderKey.SPEED, str(gd_speed),
		HeaderKey.PLATFORMER, "1" if level_data.get("platformer", false) else "0",
		"kA13", "0",
		"kA15", "0",
		"kA16", "0",
		"kA18", "0",
		"kS39", "0",
	]))


static func _color_channel_entry(channel_id: int, color: Color, alpha: float) -> String:
	return "_".join(PackedStringArray([
		"1", str(int(color.r8)),
		"2", str(int(color.g8)),
		"3", str(int(color.b8)),
		"6", str(channel_id),
		"7", str(snappedf(alpha, 0.001)),
		"8", "1",
		"11", "255", "12", "255", "13", "255",
		"4", "-1",
		"15", "1",
		"18", "0",
	]))


static func _object_to_chunk(gd_id: int, object_data: Dictionary) -> String:
	var transform: Transform2D = object_data.get("transform", Transform2D.IDENTITY)
	var position: Vector2 = transform.origin
	var scale: Vector2 = transform.get_scale()

	var fields := PackedStringArray([
		Prop.ID, str(gd_id),
		Prop.X, str(snappedf(position.x / Constants.CELL_SIZE * GD_CELL_SIZE, 0.001)),
		Prop.Y, str(snappedf((GROUND_Y - position.y) / Constants.CELL_SIZE * GD_CELL_SIZE, 0.001)),
	])

	var rotation_degrees: float = rad_to_deg(transform.get_rotation())
	if not is_zero_approx(rotation_degrees):
		fields.append_array([Prop.ROTATION, str(snappedf(rotation_degrees, 0.01))])
	if not is_equal_approx(absf(scale.x), 1.0) or not is_equal_approx(absf(scale.y), 1.0):
		fields.append_array([
			Prop.SCALE_X, str(snappedf(absf(scale.x), 0.001)),
			Prop.SCALE_Y, str(snappedf(absf(scale.y), 0.001)),
		])
	if scale.x < 0.0:
		fields.append_array([Prop.FLIP_X, "1"])
	if scale.y < 0.0:
		fields.append_array([Prop.FLIP_Y, "1"])

	var group_ids := PackedStringArray()
	for group: String in object_data.get("groups", []):
		var group_id: String = group.trim_prefix(Constants.GROUP_PREFIX)
		if group_id.is_valid_int():
			group_ids.append(group_id)
	if not group_ids.is_empty():
		fields.append_array([Prop.GROUPS, ".".join(group_ids)])

	var color_channels: Variant = object_data.get("color_channels", { })
	if color_channels is String or color_channels is StringName:
		var channel_id: String = str(color_channels).trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX)
		if channel_id.is_valid_int():
			fields.append_array([Prop.MAIN_COLOR_ID, channel_id])
	elif color_channels is Dictionary:
		if "base" in color_channels:
			var base_id: String = str(color_channels.base).trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX)
			if base_id.is_valid_int():
				fields.append_array([Prop.MAIN_COLOR_ID, base_id])
		if "detail" in color_channels:
			var detail_id: String = str(color_channels.detail).trim_prefix(Constants.COLOR_CHANNEL_GROUP_PREFIX)
			if detail_id.is_valid_int():
				fields.append_array([Prop.SECONDARY_COLOR_ID, detail_id])

	return ",".join(fields)

#endregion
