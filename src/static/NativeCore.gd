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
	return RobTopLevels.extract_k4_fallback(payload)

