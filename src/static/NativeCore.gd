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
	return _backend


static func available() -> bool:
	return backend() != null
