class_name NativeCore
extends RefCounted
## Optional access to the C++ large-level kernels.
##
## Android bundles the extension. Source/editor builds without its native
## library retain the GDScript paths. Keeping the boundary here avoids repeated
## ClassDB lookup/instantiation in loops that parse hundreds of thousands of
## Geometry Dash objects.

const MANIFEST_PATH := "res://native/bin/gdash_native.gdextension"

static var _checked: bool = false
static var _backend: Object


static func backend() -> Object:
	if not _checked:
		_checked = true
		if Config.use_native_core and ClassDB.class_exists(&"GdashNative"):
			_backend = ClassDB.instantiate(&"GdashNative")
		elif Config.use_native_core and not OS.has_feature("web"):
			var manifest := ConfigFile.new()
			var manifest_error := manifest.load(MANIFEST_PATH)
			var library_keys := manifest.get_section_keys("libraries") if manifest.has_section("libraries") else PackedStringArray()
			print("[gdash] native unavailable diagnostic=v5 manifest_error=%d libraries=%s os=%s arch=%s features(android=%s arm64=%s single=%s debug=%s)" % [
				manifest_error, str(library_keys), OS.get_name(),
				Engine.get_architecture_name(), OS.has_feature("android"),
				OS.has_feature("arm64"), OS.has_feature("single"),
				OS.has_feature("debug"),
			])
	return _backend


static func available() -> bool:
	return backend() != null


static func is_html_error_response(response: String) -> bool:
	var b: Object = backend()
	if b != null and b.has_method(&"is_html_error_response"):
		return bool(b.is_html_error_response(response))
	var s := response.strip_edges().to_lower()
	if s.is_empty():
		return false
	if s.begins_with("<!doctype") or s.begins_with("<html") or s.begins_with("<head"):
		return true
	if s.contains("<html") and (s.contains("522") or s.contains("502") or s.contains("503") or s.contains("500") or s.contains("404") or s.contains("403") or s.contains("cloudflare") or s.contains("error") or s.contains("access denied")):
		return true
	return false


static func extract_level_data_string(payload: String) -> String:
	var b: Object = backend()
	if b != null and b.has_method(&"extract_level_data_string"):
		return str(b.extract_level_data_string(payload))
	return ""


static func extract_level_sfx_ids(level_string: String) -> PackedInt32Array:
	var b: Object = backend()
	if b != null and b.has_method(&"extract_level_sfx_ids"):
		return b.extract_level_sfx_ids(level_string)
	return _extract_sfx_ids_fallback(level_string)


static func resolve_proxy_url(endpoint: String, proxy_prefix: String = "") -> String:
	var b: Object = backend()
	if b != null and b.has_method(&"resolve_proxy_url"):
		return b.resolve_proxy_url(endpoint, proxy_prefix)
	if proxy_prefix.is_empty():
		return endpoint
	var clean := proxy_prefix.strip_edges()
	if clean.contains("allorigins.win/raw?url="):
		return "https://api.allorigins.win/raw?url=" + endpoint.uri_encode()
	if clean.contains("codetabs.com/v1/proxy?quest="):
		return "https://api.codetabs.com/v1/proxy?quest=" + endpoint.uri_encode()
	if clean.ends_with("?url=") or clean.ends_with("?") or clean.ends_with("="):
		return clean + endpoint.uri_encode()
	if clean.ends_with("/"):
		return clean + endpoint
	return clean + "/" + endpoint


static func is_cors_error(result: int, http_status: int, is_web: bool = true) -> bool:
	var b: Object = backend()
	if b != null and b.has_method(&"is_cors_error"):
		return bool(b.is_cors_error(result, http_status, is_web))
	if not is_web:
		return false
	return (result == 2 or result == 4) and http_status == 0


static func is_audio_stream(bytes: PackedByteArray, extension: String = "") -> bool:
	var b: Object = backend()
	if b != null and b.has_method(&"is_audio_stream"):
		return bool(b.is_audio_stream(bytes, extension))
	if bytes.size() < 32:
		return false
	var head := bytes.slice(0, mini(128, bytes.size())).get_string_from_ascii().strip_edges().to_lower()
	if head.begins_with("<!doctype") or head.begins_with("<html") or head.begins_with("<?xml") or head.begins_with("{") or head.begins_with("error"):
		return false
	if extension == "ogg" or (bytes[0] == 0x4f and bytes[1] == 0x67 and bytes[2] == 0x67 and bytes[3] == 0x53):
		return true
	if extension == "wav" or (bytes[0] == 0x52 and bytes[1] == 0x49 and bytes[2] == 0x46 and bytes[3] == 0x46):
		return true
	if bytes[0] == 0x49 and bytes[1] == 0x44 and bytes[2] == 0x33:
		return true
	if bytes[0] == 0xff and (bytes[1] & 0xe0) == 0xe0:
		return true
	if bytes.size() >= 16384:
		return true
	return false



static func _extract_sfx_ids_fallback(level_string: String) -> PackedInt32Array:
	var sfx_ids := PackedInt32Array()
	var data := level_string.strip_edges()
	if data.is_empty():
		return sfx_ids
	var first_chunk := true
	for chunk in data.split(";", false):
		if first_chunk:
			first_chunk = false
			if chunk.begins_with("kS") or chunk.begins_with("kA"):
				continue
		var idx := chunk.find("392,")
		while idx != -1:
			if idx == 0 or chunk[idx - 1] == ",":
				var val_start := idx + 4
				var val_end := chunk.find(",", val_start)
				if val_end == -1:
					val_end = chunk.length()
				var val_str := chunk.substr(val_start, val_end - val_start).strip_edges()
				if val_str.is_valid_int():
					var id := int(val_str.to_int())
					if id > 0 and not sfx_ids.has(id):
						sfx_ids.append(id)
				idx = chunk.find("392,", val_end)
			else:
				idx = chunk.find("392,", idx + 4)
	return sfx_ids


