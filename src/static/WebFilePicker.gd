class_name WebFilePicker
extends RefCounted
## Opens the browser's own file picker (an <input type="file">) so web builds
## can import files from the device's storage; Godot's FileDialog only sees
## the browser's virtual filesystem. The picked file is copied into user://
## and its path is handed to the callback.

const IMPORT_DIR := "user://web_imports"

# JavaScript callbacks must stay referenced or the browser drops them.
static var _js_callback: JavaScriptObject
static var _on_picked: Callable
static var _file_name: String = ""


static func is_available() -> bool:
	return OS.has_feature("web") and JavaScriptBridge != null


## accept is the input's accept attribute, e.g. ".gdr".
## on_picked receives the user:// path of the copied file.
static func pick(accept: String, on_picked: Callable) -> void:
	_on_picked = on_picked
	_js_callback = JavaScriptBridge.create_callback(_on_file_read)
	var window: JavaScriptObject = JavaScriptBridge.get_interface("window")
	window.godotDashPickedFile = _js_callback
	JavaScriptBridge.eval("""
(function () {
	const input = document.createElement("input");
	input.type = "file";
	input.accept = %s;
	input.onchange = function () {
		const file = input.files && input.files[0];
		if (!file) return;
		const reader = new FileReader();
		reader.onload = function () {
			const url = String(reader.result);
			window.godotDashPickedFile(file.name, url.substring(url.indexOf(",") + 1));
		};
		reader.readAsDataURL(file);
	};
	input.click();
})();
""" % JSON.stringify(accept), true)


static func _on_file_read(args: Array) -> void:
	if args.size() < 2:
		return
	var file_name: String = str(args[0]).get_file()
	if file_name.is_empty():
		file_name = "imported"
	var bytes: PackedByteArray = Marshalls.base64_to_raw(str(args[1]))
	DirAccess.make_dir_recursive_absolute(IMPORT_DIR)
	var path: String = IMPORT_DIR.path_join(file_name)
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		Toasts.error("Could not read the picked file.")
		return
	file.store_buffer(bytes)
	file.close()
	if _on_picked.is_valid():
		_on_picked.call(path)
