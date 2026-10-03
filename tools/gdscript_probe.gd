extends Node
## CI diagnostic that surfaces ROOT GDScript parse/analyze errors.
##
## Scripts that are only referenced as global classes (never loaded as a
## resource themselves) fail through the analyzer's external-parser cache:
## dependents report "Could not resolve class X, because of a parser error"
## and "Failed to compile depended scripts" while the actual error in X is
## counted but never printed. Loading every script here forces each one's
## own reload, so the real file:line error appears in the log.
##
## Runs as a scene (with autoloads up, like the real game). "PROBE LOAD" is
## printed BEFORE each load() so the last printed line names the script a
## hang or crash died on.


func _ready() -> void:
	print("PROBE SCENE READY")
	var paths: PackedStringArray = []
	_collect("res://src", paths)
	_collect("res://tools", paths)
	var failed: PackedStringArray = []
	for path: String in paths:
		print("PROBE LOAD ", path)
		# Plain assignment on purpose: load() returns Variant, and `:=`
		# inference from Variant is an error-level GDScript warning.
		var script = load(path)
		# load() returns a non-null GDScript resource even when the script
		# failed to parse/compile, so success needs the validity check:
		# compilable scripts are instantiable, except @abstract ones.
		if script == null or not (script.can_instantiate() or script.is_abstract()):
			failed.append(path)
			print("PROBE FAIL ", path)
		else:
			print("PROBE OK ", path)
	print("PROBE_SUMMARY total=", paths.size(), " failed=", failed.size())
	get_tree().quit(1 if not failed.is_empty() else 0)


func _collect(dir_path: String, into: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		print("PROBE SKIP missing ", dir_path)
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_collect(dir_path.path_join(entry), into)
		elif entry.ends_with(".gd"):
			into.append(dir_path.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()
