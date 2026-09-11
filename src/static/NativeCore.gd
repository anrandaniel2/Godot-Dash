class_name NativeCore
extends RefCounted
## Optional access to the C++ large-level kernels.
##
## The Android build always bundles the extension. Source/editor builds that do
## not have a matching native library transparently retain the GDScript paths.
## Keeping the boundary here avoids repeated ClassDB lookup/instantiation in
## loops that parse hundreds of thousands of Geometry Dash objects.

static var _checked: bool = false
static var _backend: Object


static func backend() -> Object:
	if not _checked:
		_checked = true
		if Config.use_native_core and ClassDB.class_exists(&"GdashNative"):
			_backend = ClassDB.instantiate(&"GdashNative")
		elif Config.use_native_core:
			# This runs after the startup loader error and records what the exported
			# application can actually see. It distinguishes a stale/missing
			# manifest from a feature-selection failure without dumping user data.
			var manifest := ConfigFile.new()
			var manifest_error := manifest.load("res://native/gdash_native.gdextension")
			var library_keys := manifest.get_section_keys("libraries") if manifest.has_section("libraries") else PackedStringArray()
			print("[gdash] native unavailable diagnostic=v3 manifest_error=%d libraries=%s os=%s arch=%s features(android=%s arm64=%s arm64-v8a=%s debug=%s template_debug=%s)" % [
				manifest_error,
				str(library_keys),
				OS.get_name(), Engine.get_architecture_name(),
				OS.has_feature("android"), OS.has_feature("arm64"),
				OS.has_feature("arm64-v8a"), OS.has_feature("debug"),
				OS.has_feature("template_debug"),
			])
	return _backend


static func available() -> bool:
	return backend() != null
