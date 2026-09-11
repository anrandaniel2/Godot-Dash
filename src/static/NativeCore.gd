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
		if Config.use_native_core and not ClassDB.class_exists(&"GdashNative") and OS.has_feature("android"):
			# Godot 4.7.2 strips [libraries] from .gdextension resources in this
			# Android export. Load an explicitly included, unimported ConfigFile
			# instead; GDExtensionManager accepts any configuration filename.
			var runtime_manifest_path := "res://native/gdash_android_runtime.cfg"
			var runtime_manifest := ConfigFile.new()
			var runtime_manifest_error := runtime_manifest.load(runtime_manifest_path)
			var runtime_library_keys := runtime_manifest.get_section_keys("libraries") if runtime_manifest.has_section("libraries") else PackedStringArray()
			var load_error := ERR_FILE_NOT_FOUND
			if runtime_manifest_error == OK and not runtime_library_keys.is_empty():
				load_error = GDExtensionManager.load_extension(runtime_manifest_path)
			print("[gdash] Android runtime native load manifest_error=%d libraries=%s load_error=%d" % [
				runtime_manifest_error, str(runtime_library_keys), load_error,
			])
		if Config.use_native_core and ClassDB.class_exists(&"GdashNative"):
			_backend = ClassDB.instantiate(&"GdashNative")
		elif Config.use_native_core:
			var manifest := ConfigFile.new()
			var manifest_error := manifest.load("res://native/gdash_native.gdextension")
			var library_keys := manifest.get_section_keys("libraries") if manifest.has_section("libraries") else PackedStringArray()
			print("[gdash] native unavailable diagnostic=v4 manifest_error=%d libraries=%s os=%s arch=%s features(android=%s arm64=%s arm64-v8a=%s debug=%s template_debug=%s)" % [
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
