extends Node
## Real-renderer regression test for both Geometry Dash artwork paths. This is
## launched as a project scene (not with --script) so normal autoloads and
## class-name dependencies are present, matching the exported game.

const TEST_ID := 1
const VIEW_SIZE := Vector2i(640, 256)
# The project uses a 1920-wide canvas stretched into this 640-wide test
# window, so render placements use logical coordinates while samples use
# captured-image coordinates (3:1 here).
const DIRECT_WORLD := Vector2(480, 384)
# Native culling must compose the full CanvasItem hierarchy. Keep the sprite far
# outside the viewport in batch-local coordinates, then move its parent back on
# screen; using get_viewport_transform() instead of the global canvas transform
# incorrectly rejects this visible artwork.
const BATCH_LOCAL := Vector2(1440, -2000)
const BATCH_PARENT_OFFSET := Vector2(0, 2384)
const SAMPLE_RADIUS := 90

var _frames := 0
var _direct: Node2D
var _batch: DecorationBatch
var _native_canvas: Object
var _level_runtime: Node


## Stand-in for Level's colour properties during the native effect-engine
## checks: the C++ runtime reads them through Variant property access.
class FakeLevel extends Node2D:
	var background_color := Color.WHITE
	var ground_color := Color.WHITE
	var line_color := Color.WHITE



func _ready() -> void:
	if OS.get_environment("GDASH_REQUIRE_NATIVE") == "1":
		_test_native_core()
	_test_composite_saw()
	get_window().size = VIEW_SIZE
	get_viewport().transparent_bg = true
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))

	var data := _object_data(DIRECT_WORLD)
	var packed := load("res://scenes/gd_objects/gd_%d.tscn" % TEST_ID) as PackedScene
	assert(packed != null, "visual smoke: generated GD scene is missing")
	var direct := packed.instantiate() as GDObject
	assert(direct != null, "visual smoke: generated GD scene did not instantiate as GDObject")
	direct.setup(data)
	add_child(direct)
	_direct = direct

	data = _object_data(BATCH_LOCAL)
	if OS.get_environment("GDASH_REQUIRE_NATIVE") == "1":
		data.color_channels = {"base": "native_smoke"}
	var batch_objects: Array = [data]
	if OS.get_environment("GDASH_REQUIRE_NATIVE") == "1":
		var offscreen := _object_data(Vector2(100000, BATCH_LOCAL.y))
		offscreen.color_channels = {"base": "native_smoke"}
		batch_objects.append(offscreen)
	var batches := GDDecorationLoader.build_batches(batch_objects, GDDecorationLoader.art_scale())
	assert(not batches.is_empty(), "visual smoke: decoration produced no batch")
	for batch: DecorationBatch in batches:
		if OS.get_environment("GDASH_REQUIRE_NATIVE") == "1":
			batch.position = BATCH_PARENT_OFFSET
		add_child(batch)
		_batch = batch
		batch.draw.connect(func(): print("VISUAL_SMOKE_BATCH_DRAW"))
		if OS.get_environment("GDASH_REQUIRE_NATIVE") == "1":
			var native_canvas: Object = batch.get("_native_canvas")
			_native_canvas = native_canvas
			assert(native_canvas != null, "native smoke: DecorationBatch did not create native renderer")
			assert(batch.get_node_or_null("NativeCanvas") == null, "native smoke: renderer still consumes a child Node")
			assert(int(native_canvas.call(&"item_count")) == batch.items.size(), "native smoke: packed item count")
			# The child is configured before its parent enters the SceneTree, so
			# is_processing() is not meaningful yet. Pixel/count checks below prove
			# that its native visibility callback runs once it is attached.
			batch.apply_channel_color(&"native_smoke", Color(0.8, 0.2, 0.1, 0.75))
			var native_color: Color = native_canvas.call(&"get_item_color", 0)
			assert(is_equal_approx(native_color.r, 0.8) and is_equal_approx(native_color.a, 0.75), "native smoke: channel update")
			# A colour trigger's Blending flip re-routes the channel's records
			# between the batch's own canvas item and the additive override.
			assert(int(native_canvas.call(&"get_item_blend", 0)) == 0, "native smoke: records must start on the inherited blend")
			batch.apply_channel_blending(&"native_smoke", true)
			assert(int(native_canvas.call(&"get_item_blend", 0)) == 1, "native smoke: blending flip did not flag the record additive")
			batch.apply_channel_blending(&"native_smoke", false)
			assert(int(native_canvas.call(&"get_item_blend", 0)) == 2, "native smoke: blending flip did not flag the record normal")
		var item: DecorationBatch.Item = batch.items[0]
		print(
				"VISUAL_SMOKE_BATCH items=%d transform=%s region=%s color=%s texture=%s"
				% [batch.items.size(), item.transform, item.region, item.modulate, item.texture]
		)


func _process(_delta: float) -> void:
	_frames += 1
	# The production NativeLevelRuntime performs this centralized update. Call
	# it explicitly here as well because this isolated smoke tree intentionally
	# creates and destroys temporary levels/runtimes during setup.
	if _native_canvas != null:
		_native_canvas.call(&"update_camera_range")
	if _frames < 8:
		return
	var image := get_viewport().get_texture().get_image()
	assert(image != null and not image.is_empty(), "visual smoke: viewport capture failed")
	if _native_canvas != null:
		var drawn := int(_native_canvas.call(&"last_drawn_count"))
		var total := int(_native_canvas.call(&"item_count"))
		assert(drawn > 0 and drawn < total, "native smoke: off-screen grid rejection (%d/%d)" % [drawn, total])
		if _level_runtime == null:
			_level_runtime = ClassDB.instantiate(&"NativeLevelRuntime") as Node
			add_child(_level_runtime)
		var render_stats: Dictionary = _level_runtime.call(&"render_stats")
		print("NATIVE_RENDER_STATS %s" % render_stats)
		if (
				int(render_stats.get("canvases", 0)) <= 0
				or render_stats.get("culled_canvases") != render_stats.get("canvases")
				or int(render_stats.get("submitted_records", 0)) >= int(render_stats.get("records", 0))
		):
			push_error("native smoke: render coordinator/culling invariant failed: %s" % render_stats)
			get_tree().quit(1)
			return
	# Canvas stretch/aspect settings vary with the test window. Ask each
	# CanvasItem for the actual world-to-viewport transform instead of assuming
	# a scale ratio.
	var viewport_to_screen := get_viewport().get_screen_transform()
	var direct_center := viewport_to_screen * _direct.get_global_transform_with_canvas() * Vector2.ZERO
	var batch_center := viewport_to_screen * _batch.get_global_transform_with_canvas() * BATCH_LOCAL
	var direct_pixels := _opaque_pixels(image, direct_center)
	var batch_pixels := _opaque_pixels(image, batch_center)
	var opaque_bounds := _opaque_bounds(image)
	print(
			"VISUAL_SMOKE size=%s bounds=%s centers=%s/%s direct=%d batch=%d"
			% [image.get_size(), opaque_bounds, direct_center, batch_center, direct_pixels, batch_pixels]
	)
	if direct_pixels < 100 or batch_pixels < 100:
		image.save_png("user://runtime_visual_smoke_failure.png")
		push_error(
				"visual smoke failed: generated scene=%d pixels, decoration batch=%d pixels"
				% [direct_pixels, batch_pixels]
		)
		get_tree().quit(1)
		return
	get_tree().quit(0)


func _opaque_pixels(image: Image, center: Vector2) -> int:
	var count := 0
	var left := maxi(0, roundi(center.x) - SAMPLE_RADIUS)
	var right := mini(image.get_width(), roundi(center.x) + SAMPLE_RADIUS)
	var top := maxi(0, roundi(center.y) - SAMPLE_RADIUS)
	var bottom := mini(image.get_height(), roundi(center.y) + SAMPLE_RADIUS)
	for y in range(top, bottom):
		for x in range(left, right):
			if image.get_pixel(x, y).a > 0.05:
				count += 1
	return count


func _opaque_bounds(image: Image) -> Rect2i:
	var bounds := Rect2i()
	var found := false
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a <= 0.05:
				continue
			if not found:
				bounds = Rect2i(x, y, 1, 1)
				found = true
			else:
				bounds = bounds.expand(Vector2i(x, y))
	return bounds


func _test_native_core() -> void:
	var native := NativeCore.backend()
	assert(native != null, "native smoke: GdashNative did not load")
	assert(int(native.call(&"version")) >= 19, "native smoke: old kernel ABI")
	var parsed_online: Dictionary = native.call(
			&"parse_online_level",
			"kA2,0,kA4,0;1,1,2,30,3,30;1,8,2,60,3,30;",
	)
	assert(parsed_online.get("header", {}).get("kA2") == "0", "native smoke: online header parser failed")
	assert(parsed_online.get("objects", []).size() == 2, "native smoke: online object parser failed")
	assert(parsed_online.get("valid_objects", 0) == 2, "native smoke: online parser validity count failed")
	assert(parsed_online.get("malformed_objects", 0) == 0, "native smoke: valid objects marked malformed")
	assert(parsed_online.get("min_x", 0.0) == 30.0 and parsed_online.get("max_x", 0.0) == 60.0, "native smoke: online parser bounds failed")
	assert(parsed_online.get("objects", [])[1].get("1") == "8", "native smoke: online parser lost source order")
	# Empty trigger values must remain attached to their key. Dropping empties
	# shifts the rest of the comma stream and can turn duration/group/activation
	# fields into unrelated values.
	var lossless_pairs: Dictionary = native.call(&"parse_gd_pairs", "1,901,51,,10,2.5,56,1")
	assert(lossless_pairs == {"1": "901", "51": "", "10": "2.5", "56": "1"}, "native smoke: empty GD value shifted trigger properties")
	var malformed: Dictionary = native.call(&"parse_online_level", "kA2,0;1,901,2,nope,3,30;1,35,2,60,3,30,51;")
	assert(int(malformed.get("valid_objects", 0)) == 0, "native smoke: malformed objects accepted")
	assert(int(malformed.get("invalid_numeric_objects", 0)) == 1, "native smoke: invalid numeric diagnostic missing")
	assert(int(malformed.get("odd_pair_chunks", 0)) == 1, "native smoke: odd trigger pair diagnostic missing")
	# Exercise the actual typed GDScript/C++ boundary, not only the C++ return
	# value. Native dictionaries do not carry GDScript's typed Dictionary
	# metadata, so the converter must accept them without a typed assignment.
	var conversion_report := GMDConverter.ImportReport.new()
	var converted := GMDConverter.import_online_level_string(
			"kA2,0,kA4,0,kA13,1.75;1,1,2,30,3,30;1,8,2,60,3,30;",
			"Native conversion smoke",
			conversion_report,
	)
	assert(conversion_report.imported == 2, "native smoke: converter rejected native dictionaries")
	var converted_objects: Array = converted.get("layers", [{}])[0].get("objects", [])
	assert(converted_objects.size() == 2, "native smoke: online conversion produced an empty level")
	for static_data: Dictionary in converted_objects:
		assert(not static_data.get("native_static_art", {}).is_empty(), "native smoke: static gameplay art was not packed")
	var static_job: Object = ClassDB.instantiate(&"NativeLevelBuildJob")
	static_job.call(&"initialize", converted, false)
	static_job.call(&"step", 1000)
	assert(bool(static_job.call(&"is_finished")), "native smoke: packed static build did not finish")
	var static_level := static_job.call(&"get_level") as Level
	var static_layer := static_level.layers[0] as Layer
	var found_static_batch := false
	for built_child: Node in static_layer.get_children():
		if built_child is DecorationBatch:
			found_static_batch = true
		elif built_child is GDObject:
			assert(built_child.get_node_or_null(^"Base") == null, "native smoke: duplicate static Sprite2D tree retained")
	assert(found_static_batch, "native smoke: packed static artwork batch missing")
	LevelPhysics.rebuild(static_level)
	for built_child: Node in static_layer.get_children():
		assert(built_child is not GDObject, "native smoke: collision-only static root retained")
	var physics_container := static_level.get_node_or_null(LevelPhysics.CONTAINER_NAME)
	assert(physics_container != null and physics_container.get_child_count() > 0, "native smoke: shared static collision missing")
	static_level.free()
	assert(is_equal_approx(float(converted.get("song_start_time", 0.0)), 1.75), "native smoke: song offset was dropped")
	# Every 2.2 trigger ID must survive import. Dedicated families retain their
	# component scenes in editor/fallback builds; with the native library
	# available, effect families (and the generic shell) import as packed C++
	# records so a 5000-trigger level builds no trigger nodes at all.
	var trigger_chunks := PackedStringArray(["kA2,0,kA4,0"])
	for trigger_id: int in GMDObjects.TRIGGER_IDS:
		trigger_chunks.append("1,%d,2,%d,3,30,62,1,57,7" % [trigger_id, 30 + trigger_chunks.size() * 30])
	var trigger_report := GMDConverter.ImportReport.new()
	var trigger_level := GMDConverter.import_online_level_string(";".join(trigger_chunks) + ";", "2.2 trigger inventory", trigger_report)
	var trigger_entries: Array = trigger_level.get("layers", [{}])[0].get("objects", [])
	assert(trigger_entries.size() == GMDObjects.TRIGGER_IDS.size(), "native smoke: one or more 2.2 trigger IDs were dropped")
	var native_import := NativeCore.available() and not Editor.in_editor
	for trigger_data: Dictionary in trigger_entries:
		assert(trigger_data.has("gd_trigger_flags") and trigger_data.has("gd_properties"), "native smoke: trigger metadata missing")
		if native_import and (int(trigger_data.get("gd_object_id", 0)) in GMDObjects.NATIVE_EFFECT_TRIGGER_IDS or not GMDObjects.MAP.has(int(trigger_data.get("gd_object_id", 0)))):
			# Effect families and generic families pack as C++ records with no
			# scene and no component data; scene-backed families outside the
			# native set (camera static, edge, end level) keep their components.
			assert(bool(trigger_data.get("native_only_trigger", false)), "native smoke: runtime import must pack effect triggers as records")
			assert(not trigger_data.has("components"), "native smoke: packed records must not carry component data")
	# Colour triggers must keep their colour source: an explicit RGB, a copied
	# channel (key 50, with the copy HSV of key 49 and the opacity copy of key
	# 60), a player colour (keys 15/16), or the channel's own colour when the
	# trigger only fades opacity. Defaulting the missing RGB to white is what
	# bleached whole channels mid-level wherever such a trigger fired. With the
	# native runtime the source survives in the raw properties and the fade is
	# executed by C++ (asserted further below against a live channel).
	var color_report := GMDConverter.ImportReport.new()
	var color_level := GMDConverter.import_online_level_string(
		"kA2,0,kA4,0;1,899,2,30,3,30,23,4,7,10,8,200,9,30;1,899,2,60,3,30,23,4,50,7,49,90a-0.5a0a1a1,60,1;1,899,2,90,3,30,23,4,15,1;1,899,2,120,3,30,23,4,10,0.5,35,0.2;1,899,2,150,3,30,23,4,17,1;",
		"Color trigger sources",
		color_report,
	)
	var color_entries: Array = color_level.get("layers", [{}])[0].get("objects", [])
	assert(color_entries.size() == 5, "native smoke: colour triggers were dropped")
	if native_import:
		for entry: Dictionary in color_entries:
			assert(bool(entry.get("native_only_trigger", false)), "native smoke: colour trigger was not packed at runtime import")
			assert(not entry.has("components"), "native smoke: packed colour trigger must not carry components")
		var rgb_properties: Dictionary = color_entries[0].get("gd_properties", {})
		assert(rgb_properties.get("7", "") == "10" and rgb_properties.get("8", "") == "200" and rgb_properties.get("9", "") == "30", "native smoke: colour trigger lost its explicit RGB")
		var copy_properties: Dictionary = color_entries[1].get("gd_properties", {})
		assert(copy_properties.get("50", "") == "7" and copy_properties.get("60", "") == "1" and copy_properties.get("49", "") == "0a-0.5a0a1a1", "native smoke: copy colour trigger lost its source keys")
		var player_properties: Dictionary = color_entries[2].get("gd_properties", {})
		assert(player_properties.get("15", "") == "1", "native smoke: player colour trigger lost its source")
		var opacity_properties: Dictionary = color_entries[3].get("gd_properties", {})
		assert(not opacity_properties.has("7") and not opacity_properties.has("8") and not opacity_properties.has("9"), "native smoke: opacity-only trigger must not carry a colour")
		var blend_properties: Dictionary = color_entries[4].get("gd_properties", {})
		assert(blend_properties.get("17", "") == "1", "native smoke: blending checkbox (key 17) was dropped from the colour trigger")
	else:
		var color_sources := color_entries.map(
			func(entry: Dictionary): return entry.get("components", {}).get("ColorChannelChangerComponent", {})
		)
		assert(color_sources[0].get("color", Color.BLACK) == Color8(10, 200, 30), "native smoke: colour trigger lost its explicit RGB")
		assert(int(color_sources[0].get("color_space", -1)) == ColorChannelChangerComponent.ColorSpace.SRGB, "native smoke: colour trigger must fade in sRGB")
		assert(int(color_sources[1].get("source", -1)) == ColorChannelChangerComponent.ColorSource.COPY_CHANNEL, "native smoke: copy colour trigger lost its source")
		assert(int(color_sources[1].get("copied_channel_id", 0)) == 7, "native smoke: copy colour trigger lost its channel")
		assert(bool(color_sources[1].get("copy_opacity", false)), "native smoke: copy colour trigger lost its opacity copy")
		assert(is_equal_approx(float(color_sources[1].get("copy_saturation", 0.0)), -0.5), "native smoke: copy colour trigger lost its HSV adjustment")
		assert(int(color_sources[2].get("source", -1)) == ColorChannelChangerComponent.ColorSource.PLAYER_1, "native smoke: player colour trigger lost its source")
		assert(int(color_sources[3].get("source", -1)) == ColorChannelChangerComponent.ColorSource.KEEP, "native smoke: opacity-only trigger must keep the channel colour")
		assert(not color_sources[3].has("color"), "native smoke: opacity-only trigger must not carry a colour")
		assert(bool(color_sources[4].get("blending", false)), "native smoke: blending checkbox was lost in trigger conversion")
	# Imported pads keep their hand-authored Area2D behaviour but replace the
	# full-cell placeholder image with GD's tightly trimmed atlas sprite. Their
	# hitbox must follow that sprite to the object origin.
	var pad_report := GMDConverter.ImportReport.new()
	var pad_level := GMDConverter.import_online_level_string(
			"kA2,0,kA4,0;1,35,2,30,3,30;1,67,2,60,3,30;",
			"Native pad smoke",
			pad_report,
	)
	var pad_entries: Array = pad_level.get("layers", [{}])[0].get("objects", [])
	assert(pad_entries.size() == 2, "native smoke: jump/gravity pads were not converted")
	for pad_data: Dictionary in pad_entries:
		var pad := Level.instantiate_object_from_data(pad_data) as PadInteractable
		assert(pad != null, "native smoke: imported pad lost interactive scene")
		assert(pad.get_node_or_null(^"JumpBoostComponent") != null, "native smoke: imported pad lost jump behavior")
		assert((pad.get_node(^"Hitbox") as CollisionShape2D).position.y == 0.0, "native smoke: imported pad hitbox does not match GD art")
		pad.free()
	assert(ClassDB.class_exists(&"NativeTriggerRuntime"), "native smoke: trigger scheduler missing")
	assert(ClassDB.class_exists(&"NativeDecorationCullWorker"), "native smoke: worker-pool culler missing")
	assert(ClassDB.class_exists(&"NativeLevelRuntime"), "native smoke: level runtime missing")
	_level_runtime = ClassDB.instantiate(&"NativeLevelRuntime") as Node
	assert(_level_runtime != null, "native smoke: NativeLevelRuntime did not instantiate")
	add_child(_level_runtime)
	var scheduler: Object = ClassDB.instantiate(&"NativeTriggerRuntime")
	var scheduler_player := Node.new()
	var trigger_a := Node.new()
	var trigger_b := Node.new()
	trigger_a.add_user_signal(&"interacted", [{"name": "player", "type": TYPE_OBJECT}])
	trigger_b.add_user_signal(&"interacted", [{"name": "player", "type": TYPE_OBJECT}])
	var fired: Array[int] = []
	trigger_a.connect(&"interacted", func(_player: Object): fired.append(1))
	trigger_b.connect(&"interacted", func(_player: Object): fired.append(2))
	# Register out of X order. The native spatial index must activate by X and
	# source order, and a normal trigger may only activate once.
	scheduler.call(&"register_trigger", trigger_b, 20.0, 0.0, 0, 2, PackedStringArray(["g_7"]), 0, {})
	scheduler.call(&"register_trigger", trigger_a, 10.0, 0.0, 0, 1, PackedStringArray(), 0, {})
	scheduler.call(&"finalize")
	scheduler.call(&"advance", scheduler_player, 0.0, 30.0)
	scheduler.call(&"advance", scheduler_player, 0.0, 30.0)
	assert(fired == [1, 2], "native smoke: trigger crossing order/one-shot state")
	scheduler.call(&"reset")
	fired.clear()
	scheduler.call(&"advance", scheduler_player, 30.0, 0.0)
	assert(fired == [2, 1], "native smoke: reverse trigger range order")
	scheduler.call(&"reset")
	fired.clear()
	scheduler.call(&"schedule_group", &"g_7", 0.25, scheduler_player)
	scheduler.call(&"tick", 0.2)
	assert(fired.is_empty(), "native smoke: spawn group fired before delay")
	scheduler.call(&"tick", 0.05)
	assert(fired == [2], "native smoke: delayed spawn group did not fire")
	var trigger_state: Dictionary = scheduler.call(&"snapshot")
	assert(trigger_state.get("active", PackedByteArray()).size() == 2, "native smoke: trigger checkpoint state")
	var packed_scheduler: Object = ClassDB.instantiate(&"NativeTriggerRuntime")
	packed_scheduler.call(&"register_packed_trigger", 12.0, 0.0, 0, 0, PackedStringArray(["g_9"]), 2904, {"1": "2904"})
	packed_scheduler.call(&"finalize")
	packed_scheduler.call(&"advance", scheduler_player, 0.0, 20.0)
	var packed_state: Dictionary = packed_scheduler.call(&"snapshot")
	assert(packed_state.get("active", PackedByteArray()) == PackedByteArray([1]), "native smoke: node-free trigger record")
	trigger_a.free()
	trigger_b.free()
	scheduler_player.free()

	# --- Native trigger effect engine -------------------------------------
	# The packed families execute entirely in C++: moves convert GD units to
	# pixels with a flipped Y axis, colour triggers fade a registered channel,
	# toggles flip visibility, pulses rise and fall, camera zooms ease, and
	# timewarps drive the engine time scale.
	var effect_runtime: Object = ClassDB.instantiate(&"NativeTriggerRuntime")
	var effect_level := FakeLevel.new()
	add_child(effect_level)
	var effect_camera := Camera2D.new()
	add_child(effect_camera)
	effect_runtime.call(&"bind_context", effect_level, effect_camera, null)
	var effect_channel := ColorChannelData.new()
	effect_channel.associated_group = "c_5"
	effect_runtime.call(&"register_channel", "c_5", effect_channel)
	var pulse_channel := ColorChannelData.new()
	pulse_channel.associated_group = "c_6"
	effect_runtime.call(&"register_channel", "c_6", pulse_channel)
	var moved := Node2D.new()
	moved.add_to_group(&"g_3")
	effect_level.add_child(moved)
	effect_runtime.call(&"set_group_members", &"g_3", [moved])
	var toggled := Node2D.new()
	toggled.add_to_group(&"g_8")
	effect_level.add_child(toggled)
	effect_runtime.call(&"set_group_members", &"g_8", [toggled])
	var effect_player := Node2D.new()
	effect_level.add_child(effect_player)
	# 901 Move: 60 units right, 30 units up over 1s. 30 GD units = 128 px,
	# with +Y pointing down in Godot: the full offset is (256, -128).
	effect_runtime.call(&"register_packed_trigger", 50.0, 0.0, 0, 0, PackedStringArray(), 901,
		{"1": "901", "51": "3", "28": "60", "29": "30", "10": "1.0"})
	# 899 Colour: fade channel c_5 to an explicit RGB, plus its opacity.
	effect_runtime.call(&"register_packed_trigger", 60.0, 0.0, 0, 1, PackedStringArray(), 899,
		{"1": "899", "23": "5", "7": "10", "8": "200", "9": "30", "35": "0.5", "10": "1.0"})
	# 899 Colour with the Blending checkbox (key 17): flips channel c_5
	# additive the moment it fires. Effect levels build their glow out of
	# these flips, so dropping the key leaves everything past the intro unlit.
	effect_runtime.call(&"register_packed_trigger", 65.0, 0.0, 0, 7, PackedStringArray(), 899,
		{"1": "899", "23": "5", "17": "1", "10": "0"})
	# 1006 Pulse: 0.5s fade in, 0.5s fade out against its own channel.
	effect_runtime.call(&"register_packed_trigger", 70.0, 0.0, 0, 2, PackedStringArray(), 1006,
		{"1": "1006", "51": "6", "52": "0", "7": "255", "8": "0", "9": "0", "45": "0.5", "46": "0", "47": "0.5"})
	# 1049 Toggle: hide group 8.
	effect_runtime.call(&"register_packed_trigger", 80.0, 0.0, 0, 3, PackedStringArray(), 1049,
		{"1": "1049", "51": "8", "56": "0"})
	# 1913 Zoom Camera: 50% (half of the 0.8 default) over 1s.
	effect_runtime.call(&"register_packed_trigger", 85.0, 0.0, 0, 4, PackedStringArray(), 1913,
		{"1": "1913", "371": "50", "10": "1.0"})
	# 1935 Timewarp: 50% over 1s.
	effect_runtime.call(&"register_packed_trigger", 90.0, 0.0, 0, 5, PackedStringArray(), 1935,
		{"1": "1935", "120": "0.5", "10": "1.0"})
	# 1612 Hide Player has no fade at all.
	effect_runtime.call(&"register_packed_trigger", 100.0, 0.0, 0, 6, PackedStringArray(), 1612, {"1": "1612"})
	effect_runtime.call(&"finalize")
	effect_runtime.call(&"advance", effect_player, 0.0, 120.0)
	assert(toggled.visible == false, "native smoke: toggle trigger did not hide its group")
	assert(effect_player.visible == false, "native smoke: hide player trigger did not run")
	assert(int(effect_runtime.call(&"active_fade_count")) == 5, "native smoke: move/colour/pulse/zoom/timewarp fades missing")
	effect_runtime.call(&"tick", 0.5)
	assert(is_equal_approx(moved.global_position.x, 128.0) and is_equal_approx(moved.global_position.y, -64.0),
		"native smoke: move trigger offset wrong at half weight")
	assert(is_equal_approx(effect_channel.color.r, (1.0 + 10.0 / 255.0) / 2.0),
		"native smoke: colour trigger did not fade halfway")
	assert(effect_channel.blending, "native smoke: blending checkbox trigger did not flip its channel additive")
	assert(pulse_channel.color.is_equal_approx(Color8(255, 0, 0)), "native smoke: pulse did not reach its colour at hold")
	assert(is_equal_approx(effect_camera.zoom.x, 0.7), "native smoke: camera zoom did not ease halfway")
	assert(is_equal_approx(Engine.time_scale, 0.75), "native smoke: timewarp did not ease halfway")
	effect_runtime.call(&"tick", 0.5)
	assert(moved.global_position == Vector2(256.0, -128.0), "native smoke: move trigger did not finish")
	assert(effect_channel.color.is_equal_approx(Color8(10, 200, 30)), "native smoke: colour trigger did not reach its target")
	assert(is_equal_approx(float(effect_channel.alpha), 0.5), "native smoke: colour trigger lost its opacity fade")
	assert(pulse_channel.color == Color.WHITE, "native smoke: pulse did not fade back out")
	assert(is_equal_approx(effect_camera.zoom.x, 0.4), "native smoke: camera zoom did not reach its target")
	assert(is_equal_approx(Engine.time_scale, 0.5), "native smoke: timewarp did not reach its target")
	assert(int(effect_runtime.call(&"active_fade_count")) == 0, "native smoke: finished fades were not retired")
	Engine.time_scale = 1.0
	# Reset clears activation state and running fades.
	effect_runtime.call(&"reset")
	assert(int(effect_runtime.call(&"active_fade_count")) == 0, "native smoke: reset left fades running")
	# Stop cancels a pending spawn, cutting spawn loops: a spawn-only member of
	# g_9 fires from a scheduled event, then the stop trigger eats the second.
	var spawn_target := Node.new()
	spawn_target.add_user_signal(&"interacted", [{"name": "player", "type": TYPE_OBJECT}])
	# Lambdas capture locals by value, so the counter is an array the signal
	# handler appends to - the same pattern the crossing test above uses.
	var spawn_fired: Array[int] = []
	spawn_target.connect(&"interacted", func(_player: Object): spawn_fired.append(1))
	var spawn_runtime: Object = ClassDB.instantiate(&"NativeTriggerRuntime")
	spawn_runtime.call(&"register_trigger", spawn_target, 50.0, 0.0, 1, 0, PackedStringArray(["g_9"]), 0, {})
	spawn_runtime.call(&"register_packed_trigger", 510.0, 0.0, 0, 1, PackedStringArray(), 1616, {"1": "1616", "51": "9"})
	spawn_runtime.call(&"finalize")
	spawn_runtime.call(&"schedule_group", &"g_9", 0.5, effect_player)
	spawn_runtime.call(&"tick", 1.0)
	assert(spawn_fired.size() == 1, "native smoke: scheduled spawn did not fire its group member")
	spawn_runtime.call(&"schedule_group", &"g_9", 0.5, effect_player)
	spawn_runtime.call(&"advance", effect_player, 0.0, 600.0)
	spawn_runtime.call(&"tick", 1.0)
	assert(spawn_fired.size() == 1, "native smoke: stop trigger did not cancel the pending spawn")
	spawn_target.free()
	effect_player.free()
	toggled.free()
	moved.free()
	effect_camera.free()
	effect_level.free()
	assert(ClassDB.class_exists(&"NativeLevelBuildJob"), "native smoke: level builder missing")
	assert(ClassDB.class_exists(&"NativeFrustumIndex"), "native smoke: frustum index missing")
	var near := Node2D.new()
	var far := Node2D.new()
	add_child(near)
	add_child(far)
	var frustum: Object = ClassDB.instantiate(&"NativeFrustumIndex")
	frustum.call(
			&"configure", [near, far], PackedFloat32Array([0.0, 8.0]),
			PackedFloat32Array([5.0, 9.0]), 10.0,
	)
	frustum.call(&"set_view", 0.0, 6.0)
	assert(near.visible and not far.visible, "native smoke: frustum rejection")
	# Both views are inside the same coarse 10-unit section boundaries at their
	# edges; visibility must still follow exact coordinates, not wait for a
	# section transition.
	frustum.call(&"set_view", 8.0, 9.5)
	assert(not near.visible and far.visible, "native smoke: exact in-section visibility update")
	frustum.call(&"show_all")
	assert(near.visible and far.visible, "native smoke: frustum restore")
	near.queue_free()
	far.queue_free()
	var collision_body := Node2D.new()
	var collision_source := Node2D.new()
	collision_source.position = Vector2(25, 30)
	add_child(collision_body)
	add_child(collision_source)
	var shape := RectangleShape2D.new()
	shape.size = Vector2(10, 12)
	var committed: Array = native.call(&"commit_collision_shapes", collision_body, collision_source, [{
		"resource": shape,
		"debug_color": Color.RED,
		"local_xform": Transform2D(0.0, Vector2(3, 4)),
	}])
	assert(committed.size() == 1 and collision_body.get_child_count() == 1, "native smoke: physics shape commit")
	assert((committed[0] as CollisionShape2D).global_position == Vector2(28, 34), "native smoke: physics transform")
	collision_body.queue_free()
	collision_source.queue_free()
	var pairs: Dictionary = native.call(&"parse_gd_pairs", "1,42,2,15.5,57,7")
	assert(pairs == {"1": "42", "2": "15.5", "57": "7"}, "native smoke: GD pair parser")
	var order: PackedInt32Array = native.call(
			&"sort_decoration_indices",
			PackedInt32Array([2, 1, 1]),
			PackedInt32Array([0, 4, 3]),
			PackedInt64Array([1, 1, 1]),
	)
	assert(order == PackedInt32Array([2, 1, 0]), "native smoke: decoration ordering")
	var buckets: Dictionary = native.call(
			&"build_x_buckets", PackedFloat32Array([-1.0, 5.0, 11.0]), 10.0
	)
	assert(buckets.has(-1) and buckets.has(0) and buckets.has(1), "native smoke: spatial buckets")
	var plain := "kS1,1,kS2,2;1,1,2,15,3,15;"
	var encoded: String = native.call(&"encode_level_string", plain)
	assert(not encoded.is_empty(), "native smoke: GMD encode")
	assert(native.call(&"decode_level_string", encoded) == plain, "native smoke: GMD round trip")
	var zlib_encoded := Marshalls.raw_to_base64(plain.to_utf8_buffer().compress(FileAccess.COMPRESSION_DEFLATE)) \
			.replace("+", "-").replace("/", "_")
	assert(native.call(&"decode_level_string", zlib_encoded) == plain, "native smoke: documented zlib level decode")
	print("NATIVE_SMOKE_OK %s" % native.call(&"build_string"))


func _test_composite_saw() -> void:
	var data := _object_data(Vector2(321.0, 222.0))
	data.gd_object_id = 88 # intentionally atlas-packed as two half-saw copies
	data.spin = 180.0
	var batches := GDDecorationLoader.build_batches([data], GDDecorationLoader.art_scale())
	var saw_items: Array[DecorationBatch.Item] = []
	var saw_batch: DecorationBatch
	for batch: DecorationBatch in batches:
		for item: DecorationBatch.Item in batch.items:
			if item.gd_id == 88:
				saw_items.append(item)
				saw_batch = batch
	assert(saw_items.size() == 2, "visual smoke: half-saw was not reconstructed from two pieces")
	var pivot: Vector2 = data.transform.origin
	for item: DecorationBatch.Item in saw_items:
		assert(item.spin_pivot.is_equal_approx(pivot), "visual smoke: composite saw has split spin pivots")
	var before_a: Vector2 = saw_items[0].transform.origin - pivot
	var before_b: Vector2 = saw_items[1].transform.origin - pivot
	assert(before_a.dot(before_b) < 0.0, "visual smoke: reconstructed saw halves are not opposite")
	# Half a second at 180 degrees/second must orbit both trimmed sprite origins
	# by 90 degrees around the complete saw's centre, not around each half.
	var saw_native: Object = saw_batch.get("_native_canvas")
	var after_a: Vector2
	var after_b: Vector2
	if saw_native != null:
		saw_native.call(&"advance_animation", 0.5)
		var native_a: Transform2D = saw_native.call(&"get_item_transform", saw_items[0].render_index)
		var native_b: Transform2D = saw_native.call(&"get_item_transform", saw_items[1].render_index)
		after_a = native_a.origin - pivot
		after_b = native_b.origin - pivot
	else:
		saw_batch.call(&"_process", 0.5)
		after_a = saw_items[0].transform.origin - pivot
		after_b = saw_items[1].transform.origin - pivot
	assert(after_a.is_equal_approx(before_a.rotated(PI * 0.5)), "visual smoke: saw does not rotate around full centre")
	assert(after_b.is_equal_approx(before_b.rotated(PI * 0.5)), "visual smoke: second saw half left shared centre")
	for batch: DecorationBatch in batches:
		batch.free()


func _object_data(position: Vector2) -> Dictionary:
	return {
		"name": "VisualSmoke",
		"decoration": true,
		"scene_file_path": "",
		"gd_object_id": TEST_ID,
		"z_order": 0,
		"z_layer": GDObject.Z_LAYER_GAMEPLAY,
		"tint": Color.WHITE,
		"blending": false,
		"glow": false,
		"hsv_shift": PackedFloat32Array(),
		"base_alpha": 1.0,
		"spin": 0.0,
		"high_detail": false,
		"detail_tint": Color.WHITE,
		"detail_hsv_shift": PackedFloat32Array(),
		"transform": Transform2D(0.0, position),
		"groups": [],
		"color_channels": {},
		"hsv": {"hsv_shift": [0.0, 0.0, 0.0], "intensity": 1.0, "alpha": 1.0},
	}
