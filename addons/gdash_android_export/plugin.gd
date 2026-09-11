@tool
extends EditorPlugin
## Work around Godot 4.7's Android resource-export path serializing our
## .gdextension with [configuration] intact but [libraries] removed.
##
## The Android build already packages libgdash_native.so as a Gradle JNI
## library. Keeping the original manifest lets GDExtensionLibraryLoader select
## its `android` entry; OS_Android then resolves the res:// path by its basename
## through Android's native library loader.

var _export_plugin: EditorExportPlugin


func _enter_tree() -> void:
	_export_plugin = AndroidNativeManifestExport.new()
	add_export_plugin(_export_plugin)


func _exit_tree() -> void:
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null


class AndroidNativeManifestExport extends EditorExportPlugin:
	const MANIFEST_PATH := "res://native/gdash_native.gdextension"
	var _android_export := false

	func _get_name() -> String:
		return "GodotDashAndroidNativeManifest"

	func _export_begin(
			features: PackedStringArray,
			_is_debug: bool,
			_path: String,
			_flags: int,
	) -> void:
		_android_export = features.has("android")

	func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
		if not _android_export or path != MANIFEST_PATH:
			return
		var bytes := FileAccess.get_file_as_bytes(MANIFEST_PATH)
		if bytes.is_empty():
			push_error("Could not read %s for Android export" % MANIFEST_PATH)
			return
		# Add the exact text instead of the resource pipeline's stripped copy.
		add_file(MANIFEST_PATH, bytes, true)
		skip()
		print("[gdash export] preserved raw GDExtension manifest (%d bytes)" % bytes.size())
