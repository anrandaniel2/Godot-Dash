@abstract
class_name GDSpriteSheet
## Loads the Geometry Dash artwork atlas.
##
## The artwork ships as a Godot-native atlas built by
## [code]tools/build_godot_atlas.py[/code]: one or more square PNG pages under
## [constant ATLAS_DIR] plus [constant ATLAS_JSON], which records where every
## frame sits on its page along with the trim offset and untrimmed size the
## original cocos2d [code].plist[/code] carried. Rotated frames were turned
## upright when the pages were packed, so every frame is a plain
## [AtlasTexture] region and the whole sheet loads in a single pass - no plist
## parsing and no per-frame image surgery at startup.
##
## The original cocos2d sheets are kept in [constant SOURCE_DIR] as the input of
## that tool. The folder carries a [code].gdignore[/code], so Godot neither
## imports nor exports them. If the packed atlas is missing (a checkout where the
## tool hasn't been run), they are parsed directly as a fallback so the game
## still draws in the editor, just more slowly on first load.

const ATLAS_DIR: String = "res://assets/textures/gd_atlas/"
const ATLAS_JSON: String = ATLAS_DIR + "gd_objects_atlas.json"
const SOURCE_DIR: String = ATLAS_DIR + "source/"

## Sheets of the cocos2d fallback, in lookup priority order (the packing tool
## uses the same order, so both agree on which sheet wins a duplicated name).
const SHEET_NAMES: PackedStringArray = [
	"PixelSheet_01",
	"GJ_GameSheet02",
	"GJ_GameSheet",
	"GJ_GameSheet03",
	"GJ_GameSheet04",
	"GJ_GameSheetGlow",
	"GJ_ParticleSheet",
	# Fire, beast and ambient particle artwork.
	"FireSheet_01",
	# Ground and background tiles from Geometry Dash 2.2. These are scenery
	# rather than level objects, so no object id maps to them.
	"GroundSheet_01",
]

const HD_SUFFIX: String = "-hd"


## One frame of the atlas.
class Frame:
	extends RefCounted

	## Ready-to-use texture: an [AtlasTexture] region of the page.
	var texture: Texture2D
	## The page this frame lives on, and the rectangle it occupies there.
	var atlas: Texture2D
	var region: Rect2 = Rect2()
	## Displacement of the trimmed pixels from the untrimmed centre, in atlas
	## pixels, y up (as cocos2d stores it).
	var offset: Vector2 = Vector2.ZERO
	## Size of the artwork before trimming.
	var source_size: Vector2 = Vector2.ZERO
	## Which cocos2d sheet this came from.
	var sheet: String = ""


## A loaded atlas.
class Sheet:
	extends RefCounted

	var frames: Dictionary[String, Frame] = { }
	## The page textures, in the order the JSON lists them.
	var pages: Array[Texture2D] = []
	## [code]true[/code] when loaded from the packed atlas rather than the
	## cocos2d sheets.
	var packed: bool = false

	func has_frame(frame_name: String) -> bool:
		return frames.has(frame_name)

	func get_frame(frame_name: String) -> Frame:
		return frames.get(frame_name)

	func get_texture(frame_name: String) -> Texture2D:
		var frame: Frame = frames.get(frame_name)
		return frame.texture if frame != null else null


## Loads the atlas: the packed pages when present, the cocos2d sheets otherwise.
static func load_all() -> Sheet:
	var sheet := Sheet.new()
	if _load_packed(sheet):
		return sheet
	push_warning(
			"GDSpriteSheet: packed atlas %s not found, parsing the cocos2d sheets in %s instead "
			+ "(run tools/build_godot_atlas.py to build it)"
			% [ATLAS_JSON, SOURCE_DIR]
	)
	for sheet_name: String in SHEET_NAMES:
		for suffix: String in [HD_SUFFIX, ""]:
			var base: String = SOURCE_DIR + sheet_name + suffix
			if FileAccess.file_exists(base + ".plist"):
				_load_cocos_into(sheet, base + ".plist", base + ".png", sheet_name)
				break
	return sheet


#region Packed atlas

## Reads [constant ATLAS_JSON] and its pages. Returns [code]false[/code] when
## the packed atlas isn't available.
static func _load_packed(sheet: Sheet) -> bool:
	if not FileAccess.file_exists(ATLAS_JSON):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ATLAS_JSON))
	if parsed is not Dictionary or not parsed.has("frames") or not parsed.has("pages"):
		push_warning("GDSpriteSheet: %s is malformed" % ATLAS_JSON)
		return false

	for page_name: Variant in parsed.pages:
		var page_path: String = ATLAS_DIR + str(page_name)
		var page: Texture2D = load(page_path) as Texture2D
		if page == null:
			push_warning("GDSpriteSheet: atlas page %s failed to load" % page_path)
			return false
		sheet.pages.append(page)

	var sheet_names: Array = parsed.get("sheets", [])
	var table: Dictionary = parsed.frames
	for frame_name: String in table:
		var record: Variant = table[frame_name]
		# [page, x, y, w, h, offset_x, offset_y, source_w, source_h, sheet]
		if record is not Array or record.size() < 9:
			continue
		var page_index: int = int(record[0])
		if page_index < 0 or page_index >= sheet.pages.size():
			continue
		var frame := Frame.new()
		frame.atlas = sheet.pages[page_index]
		frame.region = Rect2(
				float(record[1]), float(record[2]), float(record[3]), float(record[4])
		)
		frame.offset = Vector2(float(record[5]), float(record[6]))
		frame.source_size = Vector2(float(record[7]), float(record[8]))
		if record.size() > 9:
			var sheet_index: int = int(record[9])
			if sheet_index >= 0 and sheet_index < sheet_names.size():
				frame.sheet = str(sheet_names[sheet_index])
		var texture := AtlasTexture.new()
		texture.atlas = frame.atlas
		texture.region = frame.region
		frame.texture = texture
		sheet.frames[frame_name] = frame
	sheet.packed = true
	return true

#endregion


#region cocos2d fallback

static func _load_cocos_into(sheet: Sheet, plist_path: String, texture_path: String, sheet_name: String) -> void:
	if not FileAccess.file_exists(plist_path):
		push_warning("GDSpriteSheet: missing %s" % plist_path)
		return

	# The source folder is ignored by the importer, so the PNG is read as a
	# plain file rather than as an imported resource.
	var atlas_image: Image = Image.load_from_file(ProjectSettings.globalize_path(texture_path))
	if atlas_image == null:
		push_warning("GDSpriteSheet: couldn't load %s" % texture_path)
		return
	var atlas_texture: Texture2D = ImageTexture.create_from_image(atlas_image)
	sheet.pages.append(atlas_texture)

	var plist: Variant = parse_plist(FileAccess.get_file_as_string(plist_path))
	if plist is not Dictionary or not plist.has("frames"):
		push_warning("GDSpriteSheet: %s has no frames dictionary" % plist_path)
		return

	for frame_name: String in plist.frames:
		if sheet.frames.has(frame_name):
			continue
		var entry: Variant = plist.frames[frame_name]
		if entry is not Dictionary:
			continue

		var rect: Rect2 = _parse_rect(str(entry.get("textureRect", entry.get("frame", ""))))
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue

		var frame := Frame.new()
		frame.sheet = sheet_name
		frame.offset = parse_vector2(str(entry.get("spriteOffset", entry.get("offset", "{0,0}"))))
		frame.source_size = parse_vector2(
				str(entry.get("spriteSourceSize", entry.get("sourceSize", "{0,0}")))
		)
		if frame.source_size == Vector2.ZERO:
			frame.source_size = rect.size

		var rotated: bool = bool(entry.get("textureRotated", entry.get("rotated", false)))
		if not rotated:
			var atlas := AtlasTexture.new()
			atlas.atlas = atlas_texture
			atlas.region = rect
			frame.texture = atlas
			frame.atlas = atlas_texture
			frame.region = rect
		else:
			frame.texture = _unrotate(atlas_image, rect)
			if frame.texture == null:
				continue
			# An un-rotated frame is its own standalone texture.
			frame.atlas = frame.texture
			frame.region = Rect2(Vector2.ZERO, frame.texture.get_size())

		sheet.frames[frame_name] = frame


## Rebuilds a frame that was packed rotated 90 degrees clockwise.
static func _unrotate(atlas_image: Image, rect: Rect2) -> Texture2D:
	# A rotated frame occupies a region whose width and height are swapped.
	var packed := Rect2i(
			int(rect.position.x), int(rect.position.y),
			int(rect.size.y), int(rect.size.x),
	)
	if packed.size.x <= 0 or packed.size.y <= 0:
		return null
	if packed.position.x < 0 or packed.position.y < 0:
		return null
	if packed.position.x + packed.size.x > atlas_image.get_width():
		return null
	if packed.position.y + packed.size.y > atlas_image.get_height():
		return null

	var region: Image = atlas_image.get_region(packed)
	region.rotate_90(COUNTERCLOCKWISE)
	return ImageTexture.create_from_image(region)


## Parses cocos2d's brace notation [code]{{x,y},{w,h}}[/code].
static func _parse_rect(text: String) -> Rect2:
	var numbers: Array[float] = _parse_numbers(text)
	if numbers.size() < 4:
		return Rect2()
	return Rect2(numbers[0], numbers[1], numbers[2], numbers[3])


## Parses cocos2d's brace notation [code]{x,y}[/code].
static func parse_vector2(text: String) -> Vector2:
	var numbers: Array[float] = _parse_numbers(text)
	if numbers.size() < 2:
		return Vector2.ZERO
	return Vector2(numbers[0], numbers[1])


static func _parse_numbers(text: String) -> Array[float]:
	var numbers: Array[float] = []
	for part: String in text.replace("{", " ").replace("}", " ").split(",", false):
		var trimmed: String = part.strip_edges()
		if trimmed.is_valid_float():
			numbers.append(float(trimmed))
	return numbers


#region Plist

## Minimal recursive parser for Apple property list XML.
##
## Godot has no plist support and these atlases are genuinely nested documents,
## so the tags are walked directly. Malformed input yields [code]null[/code]
## instead of asserting.
static func parse_plist(text: String) -> Variant:
	var cursor: int = text.find("<plist")
	if cursor == -1:
		cursor = 0
	else:
		cursor = text.find(">", cursor) + 1
	var result: Array = _parse_value(text, cursor)
	return result[0] if not result.is_empty() else null


## Returns [code][value, next_cursor][/code].
static func _parse_value(text: String, cursor: int) -> Array:
	var tag_start: int = _next_tag(text, cursor)
	if tag_start == -1:
		return []
	var tag_end: int = text.find(">", tag_start)
	if tag_end == -1:
		return []
	var raw_tag: String = text.substr(tag_start + 1, tag_end - tag_start - 1).strip_edges()
	var self_closing: bool = raw_tag.ends_with("/")
	var tag: String = raw_tag.trim_suffix("/").strip_edges().split(" ")[0]

	match tag:
		"dict":
			if self_closing:
				return [{ }, tag_end + 1]
			return _parse_dict(text, tag_end + 1)
		"array":
			if self_closing:
				return [[], tag_end + 1]
			return _parse_array(text, tag_end + 1)
		"true":
			return [true, tag_end + 1]
		"false":
			return [false, tag_end + 1]
		"string", "integer", "real", "key":
			if self_closing:
				return ["", tag_end + 1]
			var close: int = text.find("</%s>" % tag, tag_end)
			if close == -1:
				return []
			var raw: String = text.substr(tag_end + 1, close - tag_end - 1)
			var next: int = close + tag.length() + 3
			match tag:
				"integer":
					return [int(raw), next]
				"real":
					return [float(raw), next]
				_:
					return [_unescape(raw), next]
		_:
			return [null, tag_end + 1]


static func _parse_dict(text: String, cursor: int) -> Array:
	var dict: Dictionary = { }
	while true:
		var tag_start: int = _next_tag(text, cursor)
		if tag_start == -1:
			break
		if text.substr(tag_start, 7) == "</dict>":
			return [dict, tag_start + 7]
		var key_result: Array = _parse_value(text, tag_start)
		if key_result.is_empty():
			break
		var value_result: Array = _parse_value(text, key_result[1])
		if value_result.is_empty():
			break
		dict[str(key_result[0])] = value_result[0]
		cursor = value_result[1]
	return [dict, cursor]


static func _parse_array(text: String, cursor: int) -> Array:
	var array: Array = []
	while true:
		var tag_start: int = _next_tag(text, cursor)
		if tag_start == -1:
			break
		if text.substr(tag_start, 8) == "</array>":
			return [array, tag_start + 8]
		var value_result: Array = _parse_value(text, tag_start)
		if value_result.is_empty():
			break
		array.append(value_result[0])
		cursor = value_result[1]
	return [array, cursor]


## Index of the next `<` that opens a real tag, skipping comments/declarations.
static func _next_tag(text: String, cursor: int) -> int:
	while true:
		var index: int = text.find("<", cursor)
		if index == -1:
			return -1
		var following: String = text.substr(index + 1, 3)
		if following.begins_with("!") or following.begins_with("?"):
			var close: int = text.find(">", index)
			if close == -1:
				return -1
			cursor = close + 1
			continue
		return index
	return -1


static func _unescape(text: String) -> String:
	return text \
			.replace("&lt;", "<") \
			.replace("&gt;", ">") \
			.replace("&quot;", "\"") \
			.replace("&apos;", "'") \
			.replace("&amp;", "&")

#endregion

#endregion
