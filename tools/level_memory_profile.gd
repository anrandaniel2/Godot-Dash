extends Node
## Measures memory and time for every stage of opening a downloaded level,
## following the game's own path: decode -> import -> save -> load -> build.
## Decorations count as "packed" when they live in a PackedDecorations table.
##
## Run by .github/workflows/level-profile.yml against a real level file (for
## example ORBIT, 310k objects). Reads the GDHistory download from the path in
## GDASH_PROFILE_LEVEL. Grep "LEVEL_PROFILE" in the log.

const _SAVE_PATH := "user://level_memory_profile.bin"

var _started_ms: int = 0


func _ready() -> void:
	var path := OS.get_environment("GDASH_PROFILE_LEVEL")
	_mark("start (native %s)" % ("yes" if NativeCore.available() else "no"))
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		print("LEVEL_PROFILE error: could not read %s" % path)
		get_tree().quit(1)
		return
	_mark("read download (%d chars)" % text.length())

	var encoded := RobTopLevels._extract_k4(text)
	text = ""
	var level_string := GMD.decode_level_string(encoded)
	encoded = ""
	_mark("decoded level string (%d chars)" % level_string.length())

	var report := GMDConverter.ImportReport.new()
	var level_data := GMDConverter.import_online_level_string(level_string, "Profile", report)
	level_string = ""
	var objects: Array = level_data.layers[0].objects
	var decorations := 0
	for object_data: Variant in objects:
		if object_data is Dictionary and object_data.get("decoration", false):
			decorations += 1
	_mark("imported (%d objects, %d decorations, %d packed) %s" % [
		objects.size(), decorations, _packed_count(level_data), report.summary()])

	var bytes := var_to_bytes(level_data)
	_mark("var_to_bytes (%d bytes)" % bytes.size())
	bytes = PackedByteArray()

	LevelOperationsHandler.write_level_and_meta(_SAVE_PATH, level_data)
	level_data = { }
	objects = []
	_mark("saved and released import")

	var loaded := LevelOperationsHandler.load_level_data_from_path(_SAVE_PATH)
	_mark("loaded from disk")
	if not _check_native_packed_parity(loaded):
		get_tree().quit(1)
		return

	var job := LevelBuildJob.new(loaded)
	while not job.finished:
		job.step(0x7fffffff)
	var level: Level = job.level
	var batches := 0
	var items := 0
	var nodes := 0
	for layer: Node in level.layers:
		for child: Node in layer.get_children():
			nodes += 1
			if child is DecorationBatch:
				batches += 1
				items += _sprite_count(child as DecorationBatch)
	_mark("built (%d layer children, %d batches, %d sprites)" % [nodes, batches, items])

	add_child(level)
	await get_tree().process_frame
	await get_tree().process_frame
	_mark("in tree, two frames drawn")
	print("LEVEL_PROFILE done peak=%.1f MB" % (OS.get_static_memory_peak_usage() / 1048576.0))
	get_tree().quit(0)


func _packed_count(level_data: Dictionary) -> int:
	var total := 0
	for layer: Dictionary in level_data.get("layers", []):
		total += PackedDecorations.size_of(layer.get(PackedDecorations.LAYER_KEY, { }))
	return total


func _sprite_count(batch: DecorationBatch) -> int:
	if batch.items.is_empty() and batch._native_canvas != null:
		return int(batch._native_canvas.call(&"item_count"))
	return batch.items.size()


## Builds the first packed layer both ways - the GDScript Item path and
## NativePackedDecorationBuilder - and compares sprite count, summed
## placement and summed tint. Returns false on a mismatch.
func _check_native_packed_parity(level_data: Dictionary) -> bool:
	if not ClassDB.class_exists(&"NativePackedDecorationBuilder"):
		print("LEVEL_PROFILE parity skipped: no native builder")
		return true
	var table: Dictionary = { }
	for layer: Dictionary in level_data.get("layers", []):
		table = layer.get(PackedDecorations.LAYER_KEY, { })
		if PackedDecorations.size_of(table) > 0:
			break
	if PackedDecorations.size_of(table) == 0:
		print("LEVEL_PROFILE parity skipped: no packed table")
		return true
	var scale := GDDecorationLoader.art_scale()
	var started := Time.get_ticks_msec()
	var reference := GDDecorationLoader.new_batches()
	GDDecorationLoader.add_packed(reference, table, scale)
	var ref_sums := _item_sums(reference.values())
	var gd_ms := Time.get_ticks_msec() - started

	started = Time.get_ticks_msec()
	var builder: Object = GDDecorationLoader._native_packed_builder(table, scale)
	var fallback := GDDecorationLoader.new_batches()
	for row: int in builder.call(&"get_fallback_rows"):
		GDDecorationLoader.add_object(fallback, PackedDecorations.row(table, row), scale)
	var native_sums := _item_sums(fallback.values())
	var native_batches: Array = []
	for index: int in int(builder.call(&"batch_count")):
		var batch: DecorationBatch = GDDecorationLoader._native_packed_batch(builder, index)
		if batch == null:
			continue
		native_batches.append(batch)
		var canvas: Object = batch._native_canvas
		for i: int in int(canvas.call(&"item_count")):
			var t: Transform2D = canvas.call(&"get_item_transform", i)
			var c: Color = canvas.call(&"get_item_color", i)
			native_sums[0] += 1.0
			native_sums[1] += t.origin.x + t.origin.y
			native_sums[2] += t.x.x + t.x.y + t.y.x + t.y.y
			native_sums[3] += c.r + c.g + c.b + c.a
	var native_ms := Time.get_ticks_msec() - started
	for batch: Variant in reference.values() + fallback.values() + native_batches:
		(batch as Node).free()

	var ok := is_equal_approx(ref_sums[0], native_sums[0])
	for k: int in range(1, 4):
		ok = ok and absf(ref_sums[k] - native_sums[k]) <= maxf(1.0, absf(ref_sums[k])) * 1e-4
	print("LEVEL_PROFILE parity %s: %d rows, gdscript %s in %d ms, native %s in %d ms" % [
		"ok" if ok else "MISMATCH", PackedDecorations.size_of(table), str(ref_sums), gd_ms, str(native_sums), native_ms])
	return ok


## [count, sum of origin x+y, sum of basis components, sum of rgba].
func _item_sums(batches: Array) -> PackedFloat64Array:
	var sums := PackedFloat64Array([0.0, 0.0, 0.0, 0.0])
	for batch: DecorationBatch in batches:
		for item: DecorationBatch.Item in batch.items:
			var t := item.transform
			sums[0] += 1.0
			sums[1] += t.origin.x + t.origin.y
			sums[2] += t.x.x + t.x.y + t.y.x + t.y.y
			sums[3] += item.modulate.r + item.modulate.g + item.modulate.b + item.modulate.a
	return sums


func _mark(stage: String) -> void:
	var now := Time.get_ticks_msec()
	if _started_ms == 0:
		_started_ms = now
	print("LEVEL_PROFILE %7.1fs  mem=%7.1f MB  peak=%7.1f MB  %s" % [
		(now - _started_ms) / 1000.0,
		OS.get_static_memory_usage() / 1048576.0,
		OS.get_static_memory_peak_usage() / 1048576.0,
		stage,
	])
