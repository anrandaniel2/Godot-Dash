@abstract
class_name GMD
## Low level reader/writer for the `.gmd` file format popularized by the
## [b]GDShare[/b] mod.
##
## A `.gmd` file is an Apple property list (plist) XML document describing a
## single Geometry Dash level. GDShare writes it as a flat [code]<dict>[/code]
## where every entry is a [code]<k>key</k>[/code] element immediately followed
## by its typed value element:
## [codeblock]
## <?xml version="1.0"?>
## <plist version="1.0" gjver="2.0">
##   <dict>
##     <k>k2</k><s>Level Name</s>        <!-- string  -->
##     <k>k4</k><s>H4sIAAAA...</s>       <!-- level string (see below) -->
##     <k>k13</k><t />                   <!-- true, self closing -->
##     <k>k21</k><i>2</i>                <!-- integer -->
##     <k>k45</k><r>1.5</r>              <!-- real    -->
##   </dict>
## </plist>
## [/codeblock]
##
## The interesting key is [code]k4[/code], the [i]level string[/i]. It is
## gzip compressed and then encoded with [b]URL safe[/b] base64 (so `-` and `_`
## instead of `+` and `/`). Some tools strip the padding, so it has to be
## re-added before decoding.
##
## This class only deals with the container. Translating the decompressed level
## string into Godot Dash objects is [GMDConverter]'s job.

## Keys used by Geometry Dash inside the plist dictionary.
const Key := {
	NAME = "k2",
	DESCRIPTION = "k3", # base64 encoded
	LEVEL_STRING = "k4",
	CREATOR = "k5",
	OFFICIAL_SONG = "k8",
	SONG_ID = "k45",
	REVISION = "k46",
	VERSION = "k50",
	ATTEMPTS = "k18",
	LENGTH = "k23",
	BINARY_VERSION = "k50",
}

# The two gzip magic bytes. Kept as plain ints because a PackedByteArray
# constructor isn't a constant expression in GDScript.
const _GZIP_MAGIC_0: int = 0x1F
const _GZIP_MAGIC_1: int = 0x8B
## Official levels are stored without their common gzip header prefix.
const _OFFICIAL_LEVEL_PREFIX := "H4sIAAAAAAAAA"


## Result of reading a `.gmd` file.
class Document:
	extends RefCounted

	## Every plist entry, as [code]key -> value[/code]. Values keep their plist
	## type ([bool], [int], [float] or [String]).
	var entries: Dictionary[String, Variant] = { }
	## The decompressed contents of [code]k4[/code], or an empty string when the
	## file carried no level string.
	var level_string: String = ""

	func get_string(key: String, fallback: String = "") -> String:
		var value: Variant = entries.get(key)
		return str(value) if value != null else fallback

	func get_int(key: String, fallback: int = 0) -> int:
		var value: Variant = entries.get(key)
		return int(value) if value != null and str(value).is_valid_float() else fallback


## Reads a `.gmd` file from disk.
## Returns [code]null[/code] and pushes an error when the file can't be read or
## isn't a plist. Never asserts, so a malformed file can't take the game down.
static func read_file(path: String) -> Document:
	if not FileAccess.file_exists(path):
		push_error("GMD: no file at %s" % path)
		return null
	var text: String = FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("GMD: %s is empty or unreadable (error %d)" % [path, FileAccess.get_open_error()])
		return null
	return parse(text)


## Parses the contents of a `.gmd` file.
static func parse(text: String) -> Document:
	if not text.contains("<plist") and not text.contains("<dict"):
		push_error("GMD: file is not a plist document")
		return null

	var document := Document.new()
	var cursor: int = 0
	# GDShare's dictionary is flat, so a linear scan for <k>...</k> followed by
	# the next value tag is enough. Using a regex-free scan keeps this fast even
	# on the multi-megabyte level strings big levels produce.
	while true:
		var key_start: int = text.find("<k>", cursor)
		if key_start == -1:
			break
		key_start += 3
		var key_end: int = text.find("</k>", key_start)
		if key_end == -1:
			break
		var key: String = text.substr(key_start, key_end - key_start)
		cursor = key_end + 4

		var value_start: int = text.find("<", cursor)
		if value_start == -1:
			break
		var tag_end: int = text.find(">", value_start)
		if tag_end == -1:
			break
		var tag: String = text.substr(value_start + 1, tag_end - value_start - 1).strip_edges()
		var self_closing: bool = tag.ends_with("/")
		var tag_name: String = tag.trim_suffix("/").strip_edges().split(" ")[0]

		if self_closing:
			# <t /> is true, <f /> is false.
			document.entries[key] = tag_name == "t"
			cursor = tag_end + 1
			continue

		var close_tag: String = "</%s>" % tag_name
		var content_end: int = text.find(close_tag, tag_end)
		if content_end == -1:
			push_warning("GMD: unterminated <%s> for key %s, skipping" % [tag_name, key])
			cursor = tag_end + 1
			continue
		var raw: String = text.substr(tag_end + 1, content_end - tag_end - 1)
		cursor = content_end + close_tag.length()

		match tag_name:
			"i":
				document.entries[key] = int(raw)
			"r":
				document.entries[key] = float(raw)
			"s":
				document.entries[key] = _unescape(raw)
			"t":
				document.entries[key] = true
			"f":
				document.entries[key] = false
			_:
				# Unknown value type: keep the raw text instead of failing.
				document.entries[key] = _unescape(raw)

	if document.entries.has(Key.LEVEL_STRING):
		document.level_string = decode_level_string(str(document.entries[Key.LEVEL_STRING]))
	return document


## Decodes the base64 + gzip level string stored under [code]k4[/code].
## Returns an empty string on failure rather than throwing.
static func decode_level_string(encoded: String) -> String:
	var native := NativeCore.backend()
	if native != null:
		var native_result: String = native.call(&"decode_level_string", encoded)
		if not native_result.is_empty() or encoded.strip_edges().is_empty():
			return native_result
		# Malformed input and a native decode failure both return empty. Run the
		# fallback so its detailed validation error reaches the importer log.
	var data: String = encoded.strip_edges()
	if data.is_empty():
		return ""
	# Already plain text (some editors save uncompressed level strings).
	if data.begins_with("kS") or data.begins_with("kA") or data.begins_with("1,") or data.contains(";1,"):
		return data

	# Downloaded user levels contain the complete URL-safe Base64 payload. The
	# H4sIAAAAAAAAA prefix is omitted only by bundled official levels. Decode the
	# payload as supplied first and inspect its binary wrapper; otherwise valid
	# zlib streams and gzip streams with a nonzero timestamp get corrupted.
	var plain := _decode_level_payload(data)
	if not plain.is_empty():
		return plain
	if not data.begins_with("H4sI"):
		plain = _decode_level_payload(_OFFICIAL_LEVEL_PREFIX + data)
	if plain.is_empty():
		push_error("GMD: level data is neither plain text nor valid Base64 zlib/gzip")
	return plain


static func _decode_level_payload(data: String) -> String:
	var bytes: PackedByteArray = Marshalls.base64_to_raw(_to_standard_base64(data))
	if bytes.is_empty():
		return ""
	var inflated := PackedByteArray()
	if bytes.size() >= 2 and bytes[0] == _GZIP_MAGIC_0 and bytes[1] == _GZIP_MAGIC_1:
		inflated = bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	elif bytes.size() >= 2 and (bytes[0] & 0x0f) == 8 and (((bytes[0] << 8) | bytes[1]) % 31) == 0:
		# The documented inflateInit2(15 | 32) accepts either zlib or gzip.
		inflated = bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)
	else:
		inflated = bytes
	if inflated.is_empty():
		return ""
	var plain := inflated.get_string_from_utf8()
	if not plain.begins_with("kS") and not plain.begins_with("kA") and not plain.begins_with("1,") and not plain.contains(";1,"):
		return ""
	return plain


## Encodes a plain level string the way GDShare expects it in [code]k4[/code].
static func encode_level_string(plain: String) -> String:
	var native := NativeCore.backend()
	if native != null:
		var native_result: String = native.call(&"encode_level_string", plain)
		if not native_result.is_empty():
			return native_result
	var raw: PackedByteArray = plain.to_utf8_buffer()
	var compressed: PackedByteArray = raw.compress(FileAccess.COMPRESSION_GZIP)
	# Godot's COMPRESSION_GZIP produces a bare deflate stream in some versions,
	# so make sure a gzip header/trailer is present.
	if compressed.size() < 2 or compressed[0] != _GZIP_MAGIC_0 or compressed[1] != _GZIP_MAGIC_1:
		compressed = _wrap_gzip(raw, compressed)
	return _to_url_safe_base64(Marshalls.raw_to_base64(compressed))


## Serializes a document back into `.gmd` text.
static func build(entries: Dictionary, level_string: String) -> String:
	var builder := PackedStringArray()
	builder.append("<?xml version=\"1.0\"?><plist version=\"1.0\" gjver=\"2.0\"><dict>")
	for key: String in entries:
		var value: Variant = entries[key]
		builder.append("<k>%s</k>" % key)
		match typeof(value):
			TYPE_BOOL:
				builder.append("<t />" if value else "<f />")
			TYPE_INT:
				builder.append("<i>%d</i>" % value)
			TYPE_FLOAT:
				builder.append("<r>%s</r>" % str(value))
			_:
				builder.append("<s>%s</s>" % _escape(str(value)))
	if not level_string.is_empty():
		builder.append("<k>%s</k><s>%s</s>" % [Key.LEVEL_STRING, encode_level_string(level_string)])
	builder.append("</dict></plist>")
	return "".join(builder)


## Writes a `.gmd` file to disk. Returns an [enum Error].
static func write_file(path: String, entries: Dictionary, level_string: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		return FileAccess.get_open_error()
	file.store_string(build(entries, level_string))
	file.close()
	return OK


static func _to_standard_base64(data: String) -> String:
	var standard: String = data.replace("-", "+").replace("_", "/")
	var padding: int = (4 - standard.length() % 4) % 4
	return standard + "=".repeat(padding)


static func _to_url_safe_base64(data: String) -> String:
	return data.replace("+", "-").replace("/", "_")


static func _escape(text: String) -> String:
	return text \
			.replace("&", "&amp;") \
			.replace("<", "&lt;") \
			.replace(">", "&gt;")


static func _unescape(text: String) -> String:
	return text \
			.replace("&lt;", "<") \
			.replace("&gt;", ">") \
			.replace("&quot;", "\"") \
			.replace("&apos;", "'") \
			.replace("&amp;", "&")


## Adds a gzip header and trailer around a raw deflate stream.
static func _wrap_gzip(original: PackedByteArray, deflated: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF])
	out.append_array(deflated)
	var crc: int = _crc32(original)
	for shift in [0, 8, 16, 24]:
		out.append((crc >> shift) & 0xFF)
	var size: int = original.size()
	for shift in [0, 8, 16, 24]:
		out.append((size >> shift) & 0xFF)
	return out


static var _crc_table: PackedInt64Array


static func _crc32(bytes: PackedByteArray) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for i in 256:
			var c: int = i
			for _bit in 8:
				c = (0xEDB88320 ^ (c >> 1)) if c & 1 else (c >> 1)
			_crc_table[i] = c
	var crc: int = 0xFFFFFFFF
	for byte in bytes:
		crc = _crc_table[(crc ^ byte) & 0xFF] ^ (crc >> 8)
	return crc ^ 0xFFFFFFFF


#region GMD2

## `.gmd2` is a ZIP archive rather than plain text. GDShare's GMD-API writes
## exactly three kinds of entry:
## [codeblock]
## level.data   # the same plist XML a .gmd file contains
## level.meta   # JSON: { "song-file": "12345.mp3", "song-is-custom": 12345 }
## 12345.mp3    # the song itself, only when the level was exported with it
## [/codeblock]
## The song entry is optional, and [code]level.meta[/code] may be an empty JSON
## object when no song was included.
const GMD2_LEVEL_ENTRY: String = "level.data"
const GMD2_META_ENTRY: String = "level.meta"

## Extra data a `.gmd2` carries alongside the level itself.
class Gmd2Extras:
	extends RefCounted

	## File name of the song inside the archive, e.g. [code]12345.mp3[/code].
	var song_file: String = ""
	## Newgrounds/music library song ID, or 0 for a non-custom song.
	var song_id: int = 0
	## Raw bytes of the song, empty when the archive didn't include one.
	var song_bytes: PackedByteArray = PackedByteArray()


## Reads either GDShare level format, deciding by [i]content[/i] rather than by
## file extension.
##
## This matters because extensions lie in practice: the GDShare mod always names
## its exports `.gmd`, so a ZIP archive can arrive with a `.gmd` name, and a
## plain plist can arrive renamed to `.gmd2`. A ZIP always starts with the bytes
## [code]PK[/code], which plist XML never does, so sniffing is reliable.
static func read_any_file(path: String, extras: Gmd2Extras = null) -> Document:
	if not FileAccess.file_exists(path):
		push_error("GMD: no file at %s" % path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		push_error("GMD: can't open %s (error %d)" % [path, FileAccess.get_open_error()])
		return null
	var magic: PackedByteArray = file.get_buffer(2)
	file.close()
	if magic.size() < 2:
		push_error("GMD: %s is too small to be a level" % path)
		return null
	# 0x50 0x4B == "PK", the zip local file header signature.
	if magic[0] == 0x50 and magic[1] == 0x4B:
		return read_gmd2_file(path, extras)
	# A gzip header means the obsolete `.lvl` variant: the same plist, deflated.
	if magic[0] == _GZIP_MAGIC_0 and magic[1] == _GZIP_MAGIC_1:
		return read_lvl_file(path)
	return read_file(path)


## Reads the obsolete `.lvl` format: the plist document gzipped as a whole,
## with no base64 layer. GDShare still imports these, so we accept them too.
static func read_lvl_file(path: String) -> Document:
	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		push_error("GMD: %s is empty or unreadable" % path)
		return null
	var inflated: PackedByteArray = bytes.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if inflated.is_empty():
		push_error("GMD: failed to gunzip %s" % path)
		return null
	return parse(inflated.get_string_from_utf8())


## Reads a `.gmd2` archive. Returns the parsed level [Document], or
## [code]null[/code] if the archive or its [code]level.data[/code] is unusable.
## When [param extras] is supplied it receives the song metadata and bytes.
static func read_gmd2_file(path: String, extras: Gmd2Extras = null) -> Document:
	var reader := ZIPReader.new()
	if reader.open(path) != OK:
		push_error("GMD2: %s isn't a readable zip archive" % path)
		return null

	var files: PackedStringArray = reader.get_files()
	if GMD2_LEVEL_ENTRY not in files:
		push_error("GMD2: %s has no %s entry" % [path, GMD2_LEVEL_ENTRY])
		reader.close()
		return null

	var level_text: String = reader.read_file(GMD2_LEVEL_ENTRY).get_string_from_utf8()

	if extras != null and GMD2_META_ENTRY in files:
		var meta_text: String = reader.read_file(GMD2_META_ENTRY).get_string_from_utf8()
		var meta: Variant = JSON.parse_string(meta_text)
		if meta is Dictionary:
			extras.song_file = str(meta.get("song-file", ""))
			extras.song_id = int(meta.get("song-is-custom", 0))
			# Only trust the name if it's a bare file name. A path like
			# `../../evil.mp3` would otherwise escape the songs directory when
			# written out, which is the same hole GDShare guards against.
			if _is_safe_song_name(extras.song_file):
				if extras.song_file in files:
					extras.song_bytes = reader.read_file(extras.song_file)
			else:
				push_warning("GMD2: ignoring unsafe song file name '%s'" % extras.song_file)
				extras.song_file = ""

	reader.close()
	return parse(level_text)


## Writes a `.gmd2` archive. [param song_path] is optional; when it points at a
## readable file it's stored in the archive and referenced from the metadata.
static func write_gmd2_file(
		path: String,
		entries: Dictionary,
		level_string: String,
		song_path: String = "",
		song_id: int = 0,
) -> Error:
	var packer := ZIPPacker.new()
	var error: Error = packer.open(path)
	if error != OK:
		return error

	var meta: Dictionary = { }
	if not song_path.is_empty() and FileAccess.file_exists(song_path):
		var song_name: String = song_path.get_file()
		if _is_safe_song_name(song_name):
			var song_bytes: PackedByteArray = FileAccess.get_file_as_bytes(song_path)
			if not song_bytes.is_empty():
				packer.start_file(song_name)
				packer.write_file(song_bytes)
				packer.close_file()
				meta["song-file"] = song_name
				meta["song-is-custom"] = song_id

	packer.start_file(GMD2_META_ENTRY)
	packer.write_file(JSON.stringify(meta).to_utf8_buffer())
	packer.close_file()

	packer.start_file(GMD2_LEVEL_ENTRY)
	packer.write_file(build(entries, level_string).to_utf8_buffer())
	packer.close_file()

	packer.close()
	return OK


## Rejects anything that isn't a plain file name, so a malicious archive can't
## write outside the songs directory.
static func _is_safe_song_name(name: String) -> bool:
	if name.is_empty() or name != name.get_file():
		return false
	if name.contains("..") or name.contains("/") or name.contains("\\") or name.contains(":"):
		return false
	return name.get_extension().to_lower() in ["mp3", "wav", "ogg"]

#endregion
