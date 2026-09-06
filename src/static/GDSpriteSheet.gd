@abstract
class_name GDSpriteSheet
## Loads the Geometry Dash texture atlases that ship in
## [code]assets/textures/gd_atlas/[/code].
##
## Each atlas is a cocos2d pair - a [code].plist[/code] describing every frame
## and a [code].png[/code] holding the packed pixels:
## [codeblock]
## PixelSheet_01-hd.plist   # 3444 frame definitions
## PixelSheet_01-hd.png     # 2006x1120 packed texture
## [/codeblock]
##
## Frames are described in cocos2d "format 3":
## [codeblock]
## textureRect      {{x,y},{w,h}}   where the frame sits in the png
## textureRotated   <true/>         packed rotated 90 degrees clockwise
## spriteOffset     {dx,dy}         trimmed pixels, relative to the sprite centre
## spriteSourceSize {w,h}           size before transparent edges were trimmed
## [/codeblock]
##
## [b]Trimming matters.[/b] The packer crops transparent borders, so a frame's
## pixels are usually smaller than the original artwork and sit off-centre
## within it. [member Frame.offset] carries that displacement so callers can put
## the sprite back exactly where Geometry Dash would draw it; ignoring it makes
## decoration drift by a few pixels each, which is visible across a whole level.

## Where the atlases live inside the project.
const ATLAS_DIR: String = "res://assets/textures/gd_atlas/"

## Atlas base names, loaded in this order. Earlier sheets win on a name clash.
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
	# rather than level objects, so no object id maps to them; they are loaded
	# so the ground can be textured to match the level.
	"GroundSheet_01",
]

## Quality suffix to prefer. `-hd` is roughly double resolution.
const HD_SUFFIX: String = "-hd"


## One frame: its texture plus the placement data needed to draw it faithfully.
class Frame:
	extends RefCounted

	## Ready-to-use texture, for code that just wants to assign it to a sprite.
	var texture: Texture2D
	## The full atlas page this frame lives on, and the rectangle it occupies.
	##
	## [DecorationBatch] draws with these directly rather than through
	## [member texture]: issuing consecutive draws against one shared atlas is
	## what allows the renderer to batch them, whereas a per-frame
	## [AtlasTexture] would look like a different texture each time.
	var atlas: Texture2D
	var region: Rect2 = Rect2()
	## Displacement of the trimmed pixels from the untrimmed centre, in the
	## atlas's own pixel units.
	var offset: Vector2 = Vector2.ZERO
	## Size of the artwork before trimming.
	var source_size: Vector2 = Vector2.ZERO
	## Which atlas this came from.
	var sheet: String = ""


## A loaded set of atlases.
class Sheet:
	extends RefCounted

	var frames: Dictionary[String, Frame] = { }

	func has_frame(frame_name: String) -> bool:
		return frames.has(frame_name)

	func get_frame(frame_name: String) -> Frame:
		return frames.get(frame_name)

	func get_texture(frame_name: String) -> Texture2D:
		var frame: Frame = frames.get(frame_name)
		return frame.texture if frame != null else null


## Loads every atlas in [constant ATLAS_DIR].
##
## Only the high-resolution [code]-hd[/code] variant is used. The standard
## sheets are exactly half resolution and carry an identical frame list, so they
## added nothing but disk space and a second art scale to keep in step.
##
## A sheet that only ships without the suffix is still loaded - not every atlas
## has an `-hd` twin - but it is then assumed to be authored at the same
## resolution as the rest.
static func load_all() -> Sheet:
	var sheet := Sheet.new()
	for sheet_name: String in SHEET_NAMES:
		for suffix: String in [HD_SUFFIX, ""]:
			var base: String = ATLAS_DIR + sheet_name + suffix
			if not ResourceLoader.exists(base + ".png") and not FileAccess.file_exists(base + ".png"):
				continue
			_load_into(sheet, base + ".plist", base + ".png", sheet_name)
			break
	return sheet


## Parses one atlas and merges its frames into [param sheet].
static func _load_into(sheet: Sheet, plist_path: String, texture_path: String, sheet_name: String) -> void:
	if not FileAccess.file_exists(plist_path):
		push_warning("GDSpriteSheet: missing %s" % plist_path)
		return

	var atlas_texture: Texture2D = load(texture_path)
	if atlas_texture == null:
		push_warning("GDSpriteSheet: couldn't load %s" % texture_path)
		return

	var plist: Variant = parse_plist(FileAccess.get_file_as_string(plist_path))
	if plist is not Dictionary or not plist.has("frames"):
		push_warning("GDSpriteSheet: %s has no frames dictionary" % plist_path)
		return

	# Rotated frames need pixel access to un-rotate, which means pulling the
	# image off the texture. Do it once per atlas, and only if needed.
	var atlas_image: Image = null

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
			# Shared page + region, so batched drawing can group by atlas.
			frame.atlas = atlas_texture
			frame.region = rect
		else:
			if atlas_image == null:
				atlas_image = atlas_texture.get_image()
				if atlas_image == null:
					continue
			frame.texture = _unrotate(atlas_image, rect)
			if frame.texture == null:
				continue
			# An un-rotated frame is its own standalone texture, so it batches
			# only with itself.
			frame.atlas = frame.texture
			frame.region = Rect2(Vector2.ZERO, frame.texture.get_size())

		sheet.frames[frame_name] = frame


## Rebuilds a frame that was packed rotated 90 degrees clockwise.
##
## [AtlasTexture] cannot express rotation, so the pixels are lifted out and
## turned upright once, at load time, rather than every draw.
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
