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
const BATCH_WORLD := Vector2(1440, 384)
const SAMPLE_RADIUS := 90

var _frames := 0
var _direct: Node2D
var _batch: DecorationBatch
var _native_canvas: Node2D


func _ready() -> void:
	if OS.get_environment("GDASH_REQUIRE_NATIVE") == "1":
		_test_native_core()
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

	data = _object_data(BATCH_WORLD)
	if OS.get_environment("GDASH_REQUIRE_NATIVE") == "1":
		data.color_channels = {"base": "native_smoke"}
	var batch_objects: Array = [data]
	if OS.get_environment("GDASH_REQUIRE_NATIVE") == "1":
		var offscreen := _object_data(Vector2(100000, BATCH_WORLD.y))
		offscreen.color_channels = {"base": "native_smoke"}
		batch_objects.append(offscreen)
	var batches := GDDecorationLoader.build_batches(batch_objects, GDDecorationLoader.art_scale())
	assert(not batches.is_empty(), "visual smoke: decoration produced no batch")
	for batch: DecorationBatch in batches:
		add_child(batch)
		_batch = batch
		batch.draw.connect(func(): print("VISUAL_SMOKE_BATCH_DRAW"))
		if OS.get_environment("GDASH_REQUIRE_NATIVE") == "1":
			var native_canvas := batch.get_node_or_null("NativeCanvas")
			_native_canvas = native_canvas
			assert(native_canvas != null, "native smoke: DecorationBatch did not create native canvas")
			assert(int(native_canvas.call(&"item_count")) == batch.items.size(), "native smoke: packed item count")
			assert(not batch.is_processing() and native_canvas.is_processing(), "native smoke: culling must not poll through GDScript")
			batch.apply_channel_color(&"native_smoke", Color(0.8, 0.2, 0.1, 0.75))
			var native_color: Color = native_canvas.call(&"get_item_color", 0)
			assert(is_equal_approx(native_color.r, 0.8) and is_equal_approx(native_color.a, 0.75), "native smoke: channel update")
		var item: DecorationBatch.Item = batch.items[0]
		print(
				"VISUAL_SMOKE_BATCH items=%d transform=%s region=%s color=%s texture=%s"
				% [batch.items.size(), item.transform, item.region, item.modulate, item.texture]
		)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames < 8:
		return
	var image := get_viewport().get_texture().get_image()
	assert(image != null and not image.is_empty(), "visual smoke: viewport capture failed")
	if _native_canvas != null:
		var drawn := int(_native_canvas.call(&"last_drawn_count"))
		var total := int(_native_canvas.call(&"item_count"))
		assert(drawn > 0 and drawn < total, "native smoke: exact off-screen rejection (%d/%d)" % [drawn, total])
	# Canvas stretch/aspect settings vary with the test window. Ask each
	# CanvasItem for the actual world-to-viewport transform instead of assuming
	# a scale ratio.
	var direct_center := _direct.get_viewport_transform() * DIRECT_WORLD
	var batch_center := _batch.get_viewport_transform() * BATCH_WORLD
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
	assert(int(native.call(&"version")) >= 7, "native smoke: old kernel ABI")
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
	# Exercise the actual typed GDScript/C++ boundary, not only the C++ return
	# value. Native dictionaries do not carry GDScript's typed Dictionary
	# metadata, so the converter must accept them without a typed assignment.
	var conversion_report := GMDConverter.ImportReport.new()
	var converted := GMDConverter.import_online_level_string(
			"kA2,0,kA4,0;1,1,2,30,3,30;1,8,2,60,3,30;",
			"Native conversion smoke",
			conversion_report,
	)
	assert(conversion_report.imported == 2, "native smoke: converter rejected native dictionaries")
	assert(converted.get("layers", [{}])[0].get("objects", []).size() == 2, "native smoke: online conversion produced an empty level")
	assert(ClassDB.class_exists(&"NativeLevelBuildJob"), "native smoke: level builder missing")
	assert(ClassDB.class_exists(&"NativeFrustumIndex"), "native smoke: frustum index missing")
	var near := Node2D.new()
	var far := Node2D.new()
	add_child(near)
	add_child(far)
	var frustum: Object = ClassDB.instantiate(&"NativeFrustumIndex")
	frustum.call(
			&"configure", [near, far], PackedFloat32Array([0.0, 100.0]),
			PackedFloat32Array([5.0, 105.0]), 10.0,
	)
	frustum.call(&"set_range", 0, 1)
	assert(near.visible and not far.visible, "native smoke: frustum rejection")
	frustum.call(&"show_all")
	assert(far.visible, "native smoke: frustum restore")
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
