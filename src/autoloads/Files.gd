extends Node

signal file_loaded(path: String)
signal files_loaded(paths: PackedStringArray)

enum {
	NONE = 0,
	SINGLE_FILE = 1 << 0,
}

@export var load_dialog: FileDialog
@export var import_and_load_dialog: FileDialog
@export var corrupted_level_dialog: AcceptDialog


func load(filters: PackedStringArray, root: String) -> void:
	load_dialog.filters = filters
	load_dialog.root_subfolder = root
	load_dialog.show()
	NodeUtils.disconnect_all(load_dialog.canceled)
	NodeUtils.disconnect_all(load_dialog.file_selected)
	load_dialog.canceled.connect(func(): file_loaded.emit(""))
	load_dialog.file_selected.connect(func(path): file_loaded.emit(path))


func import_and_load(filters: PackedStringArray, root: String, import_to: String, options: int) -> void:
	import_and_load_dialog.filters = filters
	import_and_load_dialog.root_subfolder = root
	import_and_load_dialog.show()
	NodeUtils.disconnect_all(import_and_load_dialog.canceled)
	NodeUtils.disconnect_all(import_and_load_dialog.file_selected)
	NodeUtils.disconnect_all(import_and_load_dialog.files_selected)
	import_and_load_dialog.canceled.connect(func(): file_loaded.emit(""))
	if options & SINGLE_FILE:
		import_and_load_dialog.file_selected.connect(
			func(path: String) -> void:
				_import(PackedStringArray([path]), import_to)
				file_loaded.emit(path)
		)
	else:
		import_and_load_dialog.files_selected.connect(
			func(paths: PackedStringArray) -> void:
				_import(paths, import_to)
				files_loaded.emit(paths)
		)


func show_corrupted_level_warning(error_message: String) -> void:
	corrupted_level_dialog.dialog_text = """This Geometry Dash level file is invalid and can't be imported.
Error:
%s""" % error_message
	corrupted_level_dialog.popup_centered()


func _import(file_paths: PackedStringArray, import_to: String) -> void:
	for path in file_paths:
		if not DirAccess.dir_exists_absolute(import_to):
			DirAccess.make_dir_absolute(import_to)
		DirAccess.copy_absolute(path, import_to + path.get_file())
