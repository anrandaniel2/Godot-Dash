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



## Regression test for the streamed-level batch ordering: every editor layer
## seal runs its own build_batches call while a level streams in, so the
## batches of one z plane arrive across several calls. Ranking each call on
## its own handed every seal the same z offsets and let later seals cover
## earlier ones wherever they overlapped (device report: dark spots swallowing
## the decoration as more of the level loaded).
func _test_batch_order() -> void:
	var front := DecorationBatch.new()
	front.gd_z_layer = 5
	var front_item := DecorationBatch.Item.new()
	front_item.z_order = 100
	front.items.append(front_item)
	var first_seal: Array[DecorationBatch] = [front]
	GDDecorationLoader.finalise_batch_order(first_seal)

	var back := DecorationBatch.new()
	back.gd_z_layer = 5
	var back_item := DecorationBatch.Item.new()
	back_item.z_order = 1
	back.items.append(back_item)
	var second_seal: Array[DecorationBatch] = [back]
	GDDecorationLoader.finalise_batch_order(second_seal)

	assert(
		front.z_index > back.z_index,
		"visual smoke: batches of separate seals on one z layer must share a ranking"
	)
	front.free()
	back.free()



## Regression test for the device-reported black silhouettes covering the
## decoration: Geometry Dash serialises an HSV-enabled object whose sliders
## were never moved as an all-zero string with the saturation/value sliders
## still multiplicative ("0a0a0a0a0"). Multiplying by those zeros painted the
## object solid black; GDRweb's HSVShift.shiftColor treats it as "no shift".
func _test_hsv_neutral() -> void:
	var base := Color(0.2, 0.5, 0.8)
	var untouched: Color = GMDConverter._apply_hsv_shift(
		base, {"41": "1", "43": "0a0a0a0a0"}, "41", "43"
	)
	assert(untouched == base, "visual smoke: all-zero HSV shift changed the import tint")
	var moved: Color = GMDConverter._apply_hsv_shift(
		base, {"41": "1", "43": "90a1a1a0a0"}, "41", "43"
	)
	assert(moved != base, "visual smoke: a moved HSV slider must still shift the tint")

	# The same rule on the batch recolour path: a channel update re-applies
	# the object's HSV shift, and an all-zero shift must leave the channel
	# colour alone (native records on device, GDScript fallback elsewhere).
	var batch := DecorationBatch.new()
	var item := DecorationBatch.Item.new()
	item.texture = load("res://assets/textures/gd_atlas/gd_objects_atlas_0.png")
	item.channel = &"hsv_neutral_smoke"
	item.hsv_shift = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0])
	item.base_alpha = 1.0
	batch.add_item(item)
	batch.build()
	batch.apply_channel_color(&"hsv_neutral_smoke", Color(0.9, 0.6, 0.3, 1.0))
	var applied: Color
	var neutral_native: Object = batch.get("_native_canvas")
	if neutral_native != null:
		applied = neutral_native.call(&"get_item_color", 0)
	else:
		applied = item.modulate
	assert(
		is_equal_approx(applied.r, 0.9) and is_equal_approx(applied.g, 0.6) and is_equal_approx(applied.b, 0.3),
		"visual smoke: all-zero HSV shift must not black out a recoloured item"
	)
	batch.free()



## Imported gameplay objects must wear the Geometry Dash z mapping on every
## instantiation path: generated scenes (GDObject.setup), hand-made scenes
## dressed by the artwork swap, and decoration batches. The named layers are
## odd values (1 = B2, 3 = B1, 5 = T1) and 4 is the gameplay plane, so a
## default block (T1) must land above every B-layer decoration batch while a
## B1 decoration stays behind it.
func _test_gameplay_z() -> void:
	assert(GDObject.z_index_for(5, 2) == 66, "z smoke: T1 block (layer 5, order 2)")
	assert(GDObject.z_index_for(3, -6) == -70, "z smoke: B1 fine order can be negative")
	assert(
		GDObject.z_index_for(1, 0) < GDObject.z_index_for(5, 0),
		"z smoke: a B2 batch index must stay below a T1 object"
	)

	# Generated-scene path: setup() consumes the converter's z keys.
	var generated: GDObject = (load("res://scenes/gd_objects/gd_%d.tscn" % TEST_ID) as PackedScene).instantiate() as GDObject
	assert(generated != null, "z smoke: generated GD scene missing")
	generated.setup({
		"gd_object_id": TEST_ID,
		"z_layer": 5,
		"z_order": 2,
	})
	assert(generated.z_index == 66, "z smoke: generated scene ignored z keys")
	generated.free()

	# Hand-made scene path (artwork swap): must not render at z 0 anymore.
	var swapped: Node2D = Level.instantiate_object_from_data({
		"name": "ZSmokePortal",
		"scene_file_path": "scenes/components/level_components/portals/other_portals/GravityPortalNormal.tscn",
		"gd_object_id": 11,
		"transform": Transform2D(0.0, Vector2.ZERO),
		"groups": [],
		"color_channels": {},
		"z_layer": 5,
		"z_order": 0,
	}, null)
	assert(swapped != null, "z smoke: portal scene missing")
	assert(swapped.z_index == 64, "z smoke: artwork-swapped object ignored z layer")
	swapped.free()


## The invisible block family (146 block / 147 plank) imports collision-only:
## their atlas frames are the GD editor's white ghost outlines, which the real
## game never draws, so neither the generated-scene artwork swap nor the packed
## static art may include them - previously they rendered as full-size ghost
## squares over the level's actual decoration.
func _test_invisible_blocks() -> void:
	assert(not GMDObjects.is_static_gameplay_object(146), "invis smoke: 146 must not take the static-artwork path")
	assert(not GMDObjects.is_static_gameplay_object(147), "invis smoke: 147 must not take the static-artwork path")
	assert(not GMDObjects.is_fallback_block(146), "invis smoke: 146 must not fall back to a visible block")
	assert(GMDObjects.get_object(146).scene.ends_with("GDInvisibleSquare.tscn"), "invis smoke: 146 lost its scene")
	var block: Node2D = Level.instantiate_object_from_data({
		"name": "InvisSmoke",
		"scene_file_path": "scenes/components/level_components/solids/GDInvisibleSquare.tscn",
		"gd_object_id": 146,
		"transform": Transform2D(0.0, Vector2.ZERO),
		"groups": [],
		"color_channels": {},
		"z_layer": 5,
		"z_order": 2,
	}, null)
	assert(block != null, "invis smoke: invisible block scene missing")
	assert(block.get_node_or_null(^"Base") == null, "invis smoke: invisible block must not wear artwork")
	assert(block.get_child_count() == 2, "invis smoke: artwork swap injected nodes into the invisible block")
	assert(block.get_node_or_null(^"Hitbox") != null, "invis smoke: invisible block lost its collision")
	block.free()
	# An invisible spike (hazard) and triangle (solid) import the same way.
	var spike: Node2D = Level.instantiate_object_from_data({
		"name": "InvisSpikeSmoke",
		"scene_file_path": "scenes/components/level_components/hazards/GDInvisibleSpike.tscn",
		"gd_object_id": 144,
		"transform": Transform2D(0.0, Vector2.ZERO),
		"groups": [],
		"color_channels": {},
		"z_layer": 5,
		"z_order": 2,
	}, null)
	assert(spike != null, "invis smoke: invisible spike scene missing")
	assert(spike is Area2D, "invis smoke: invisible spike lost its hazard area")
	assert(spike.get_child_count() == 2, "invis smoke: invisible spike gained artwork nodes")
	spike.free()
	var triangle: Node2D = Level.instantiate_object_from_data({
		"name": "InvisTriangleSmoke",
		"scene_file_path": "scenes/components/level_components/solids/GDInvisibleTriangle.tscn",
		"gd_object_id": 673,
		"transform": Transform2D(0.0, Vector2.ZERO),
		"groups": [],
		"color_channels": {},
		"z_layer": 5,
		"z_order": 2,
	}, null)
	assert(triangle != null, "invis smoke: invisible triangle scene missing")
	assert(triangle.get_node_or_null(^"Hitbox") != null, "invis smoke: invisible triangle lost its collision")
	assert(triangle.get_child_count() == 2, "invis smoke: invisible triangle gained artwork nodes")
	triangle.free()


## Key 135 (Hide) is Geometry Dash 2.2's per-object hide flag: the node keeps
## its collision and group membership but renders nothing - the standard way
## modern effect levels build invisible geometry out of regular blocks.
func _test_hidden_objects() -> void:
	# The converter carries the flag and suppresses the packed static art.
	var object_data: Dictionary = GMDConverter._object_from_properties(
		1, {"1": "1", "2": "0", "3": "0", "135": "1"}, 0, {}, {}
	)
	assert(bool(object_data.get("hidden", false)), "hide smoke: converter dropped key 135")
	assert(not object_data.has("native_static_art"), "hide smoke: hidden block packed static art")

	var hidden_block: Node2D = Level.instantiate_object_from_data({
		"name": "HiddenSmoke",
		"scene_file_path": "scenes/components/level_components/solids/GDInvisibleSquare.tscn",
		"gd_object_id": 146,
		"transform": Transform2D(0.0, Vector2.ZERO),
		"groups": [],
		"color_channels": {},
		"z_layer": 5,
		"z_order": 2,
		"hidden": true,
	}, null)
	assert(hidden_block != null, "hide smoke: hidden object failed to build")
	assert(not hidden_block.visible, "hide smoke: hidden object renders")
	assert(hidden_block.get_node_or_null(^"Hitbox") != null, "hide smoke: hidden object lost its collision")
	hidden_block.free()
	# A hidden hand-made object skips the artwork swap as well.
	var hidden_portal: Node2D = Level.instantiate_object_from_data({
		"name": "HiddenPortalSmoke",
		"scene_file_path": "scenes/components/level_components/portals/other_portals/GravityPortalNormal.tscn",
		"gd_object_id": 11,
		"transform": Transform2D(0.0, Vector2.ZERO),
		"groups": [],
		"color_channels": {},
		"z_layer": 5,
		"z_order": 0,
		"hidden": true,
	}, null)
	assert(hidden_portal != null, "hide smoke: hidden portal failed to build")
	assert(not hidden_portal.visible, "hide smoke: hidden portal renders")
	hidden_portal.free()


func _ready() -> void:
	_test_batch_order()
	_test_hsv_neutral()
	_test_gameplay_z()
	_test_invisible_blocks()
	_test_hidden_objects()
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
	var batch_objects: Array = []
	if OS.get_environment("GDASH_REQUIRE_NATIVE") == "1":
		# Appended first so the sampled batch below stays the last one: an
		# all-zero HSV string (multiplicative sliders) is Geometry Dash's
		# "HSV enabled but untouched" encoding and must recolour like an
		# unshifted object instead of painting a black silhouette.
		var neutral := _object_data(Vector2(100000, BATCH_LOCAL.y - 300.0))
		neutral.color_channels = {"base": "hsv_neutral_smoke"}
		neutral.hsv_shift = PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0])
		neutral.groups = ["g_hsv_neutral"]
		batch_objects.append(neutral)
	batch_objects.append(data)
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
			if batch.is_in_group("g_hsv_neutral"):
				# All-zero HSV with multiplicative sliders: the channel
				# colour must survive the recolour untouched.
				var neutral_canvas: Object = batch.get("_native_canvas")
				assert(neutral_canvas != null, "native smoke: DecorationBatch did not create native renderer")
				batch.apply_channel_color(&"hsv_neutral_smoke", Color(0.9, 0.6, 0.3, 1.0))
				var neutral_color: Color = neutral_canvas.call(&"get_item_color", 0)
				assert(
					is_equal_approx(neutral_color.r, 0.9)
					and is_equal_approx(neutral_color.g, 0.6)
					and is_equal_approx(neutral_color.b, 0.3),
					"native smoke: all-zero HSV shift blacked out the streamed item"
				)
			else:
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
		# Packed records carry the raw activation metadata; every other
		# family keeps a scene to instantiate (dedicated scenes like the
		# end-level trigger, which needs no component data, and the generic
		# shell in editor/fallback builds). A trigger must be one or the
		# other.
		var packed: bool = trigger_data.has("gd_trigger_flags") and trigger_data.has("gd_properties")
		assert(packed or not str(trigger_data.get("scene_file_path", "")).is_empty(),
			"native smoke: trigger neither packed as a record nor backed by a scene")
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
		assert(copy_properties.get("50", "") == "7" and copy_properties.get("60", "") == "1" and copy_properties.get("49", "") == "90a-0.5a0a1a1",
			"native smoke: copy colour trigger lost its source keys: %s" % [copy_properties])
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
	# kS38 copy entries keep their link instead of being flattened to a
	# literal: the runtime channel carries the source id, the copy HSV of key
	# 10 and the opacity-copy flag of key 17, so it can follow the source live
	# (the asserts further below exercise that fan-out through a real level).
	# The legacy colour-trigger families (29/30/104/... targeted a fixed
	# channel before key 23 existed) import like any colour trigger, and a
	# bare 899 without key 23 falls back to channel 1.
	var link_report := GMDConverter.ImportReport.new()
	var link_level := GMDConverter.import_online_level_string(
		"kA2,0,kA4,0,kS38,1_0_2_0_3_255_6_5_7_1|6_10_7_1_9_5_10_180a1a1a0a0|6_11_7_1_9_10|6_12_7_0.25_9_5_17_1;1,1,2,30,3,30,21,5;1,1,2,60,3,30,21,10;1,1,2,90,3,30,21,11;1,1,2,120,3,30,21,12;1,30,2,30,3,150;1,899,2,30,3,180,7,255,8,255,9,255;",
		"Copy channel import",
		link_report,
	)
	var link_channels: Array = link_level.get("color_channels", [])
	var channel_data_by_group := {}
	for entry: Dictionary in link_channels:
		channel_data_by_group[entry.get("associated_group", "")] = entry
	assert(int(channel_data_by_group.get("c_10", {}).get("copied_channel_id", 0)) == 5,
			"native smoke: kS38 copy link was not kept on the runtime channel")
	assert(is_equal_approx(float(channel_data_by_group.get("c_10", {}).get("copy_hue", 0.0)), 0.5),
			"native smoke: kS38 copy HSV was not kept on the runtime channel")
	assert(int(channel_data_by_group.get("c_11", {}).get("copied_channel_id", 0)) == 10,
			"native smoke: copy chain link was not kept on the runtime channel")
	assert(bool(channel_data_by_group.get("c_12", {}).get("copy_opacity", false)),
			"native smoke: kS38 opacity-copy flag was not kept on the runtime channel")
	var link_entries: Array = link_level.get("layers", [{}])[0].get("objects", [])
	assert(link_entries.size() == 6, "native smoke: copy import dropped objects or triggers")
	var legacy_trigger: Dictionary = {}
	var bare_trigger: Dictionary = {}
	for entry: Dictionary in link_entries:
		if int(entry.get("gd_object_id", 0)) == 30:
			legacy_trigger = entry
		if int(entry.get("gd_object_id", 0)) == 899:
			bare_trigger = entry
	assert(not legacy_trigger.is_empty(), "native smoke: legacy colour trigger was dropped")
	assert(not bare_trigger.is_empty(), "native smoke: bare colour trigger was dropped")
	if native_import:
		assert(bool(legacy_trigger.get("native_only_trigger", false)),
				"native smoke: legacy colour trigger was not packed as a record")
	else:
		var legacy_target: Dictionary = legacy_trigger.get("components", {}).get("TargetColorChannelComponent", {})
		assert(int(legacy_target.get("target_level_channel", -1)) == Constants.SpecialColorChannel.GROUND,
				"native smoke: legacy ground trigger did not target the ground colour")
		var bare_target: Dictionary = bare_trigger.get("components", {}).get("TargetColorChannelComponent", {})
		assert(bare_target.get("target_color_channel", "") == Constants.COLOR_CHANNEL_GROUP_PREFIX + "1",
				"native smoke: bare colour trigger did not fall back to channel 1")
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
	var shader_layer := CanvasLayer.new()
	shader_layer.name = "ShaderLayer"
	add_child(shader_layer)
	var gray_rect := ColorRect.new()
	gray_rect.name = "Grayscale"
	var gray_mat := ShaderMaterial.new()
	gray_mat.shader = load("res://resources/shaders/Grayscale.gdshader")
	gray_mat.set_shader_parameter(&"grayscale_factor", 0.0)
	gray_rect.material = gray_mat
	gray_rect.visible = false
	shader_layer.add_child(gray_rect)

	var sepia_rect := ColorRect.new()
	sepia_rect.name = "Sepia"
	var sepia_mat := ShaderMaterial.new()
	sepia_mat.shader = load("res://resources/shaders/Sepia.gdshader")
	sepia_mat.set_shader_parameter(&"sepia_factor", 0.0)
	sepia_rect.material = sepia_mat
	sepia_rect.visible = false
	shader_layer.add_child(sepia_rect)

	var lens_rect := ColorRect.new()
	lens_rect.name = "LensCircle"
	var lens_mat := ShaderMaterial.new()
	lens_mat.shader = load("res://resources/shaders/LensCircle.gdshader")
	lens_mat.set_shader_parameter(&"alpha", 0.0)
	lens_rect.material = lens_mat
	lens_rect.visible = false
	shader_layer.add_child(lens_rect)

	effect_runtime.call(&"bind_context", effect_level, effect_camera, null, shader_layer)
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
	# 2919 Grayscale: fade to 1.0 over 1s.
	effect_runtime.call(&"register_packed_trigger", 92.0, 0.0, 0, 8, PackedStringArray(), 2919,
		{"1": "2919", "35": "1.0", "10": "1.0"})
	# 2920 Sepia: fade to 0.8 over 1s.
	effect_runtime.call(&"register_packed_trigger", 94.0, 0.0, 0, 9, PackedStringArray(), 2920,
		{"1": "2920", "35": "0.8", "10": "1.0"})
	# 2913 Lens Circle: fade to 1.0 over 1s.
	effect_runtime.call(&"register_packed_trigger", 96.0, 0.0, 0, 10, PackedStringArray(), 2913,
		{"1": "2913", "35": "1.0", "10": "1.0"})
	# 3613 UI Trigger: anchor group 20 to left edge relative to guide group 21
	var ui_node := Node2D.new()
	ui_node.position = Vector2(-1012.5, 0.0)
	ui_node.add_to_group(&"g_20")
	effect_level.add_child(ui_node)
	effect_runtime.call(&"set_group_members", &"g_20", [ui_node])
	var ui_guide := Node2D.new()
	ui_guide.position = Vector2.ZERO
	ui_guide.add_to_group(&"g_21")
	effect_level.add_child(ui_guide)
	effect_runtime.call(&"set_group_members", &"g_21", [ui_guide])
	effect_runtime.call(&"register_packed_trigger", 98.0, 0.0, 0, 11, PackedStringArray(), 3613,
		{"1": "3613", "51": "20", "71": "21", "385": "3", "386": "0", "387": "0", "388": "0"})
	# 1612 Hide Player has no fade at all.
	effect_runtime.call(&"register_packed_trigger", 100.0, 0.0, 0, 6, PackedStringArray(), 1612, {"1": "1612"})
	effect_runtime.call(&"finalize")
	var expected_anchor: Vector2 = effect_runtime.call(
		&"compute_ui_anchor",
		Vector2(-1012.5, 0.0), 3, 0, false, false,
		effect_camera.get_viewport().get_visible_rect().size, 0.8)
	var static_1080p: Vector2 = effect_runtime.call(
		&"compute_ui_anchor",
		Vector2(-1012.5, 0.0), 3, 0, false, false,
		Vector2(1920.0, 1080.0), 0.8)
	assert(is_equal_approx(static_1080p.x, -1200.0), "native smoke: 1080p UI anchor computation")
	assert(ui_node.get_parent() != effect_level, "native smoke: UI trigger reparented node to UI root")
	assert(is_equal_approx(ui_node.position.x, expected_anchor.x), "native smoke: UI left alignment applied on finalize")
	effect_runtime.call(&"advance", effect_player, 0.0, 120.0)
	assert(toggled.visible == false, "native smoke: toggle trigger did not hide its group")
	assert(effect_player.visible == false, "native smoke: hide player trigger did not run")
	assert(int(effect_runtime.call(&"active_fade_count")) == 8, "native smoke: move/colour/pulse/zoom/timewarp/shader fades missing")
	effect_runtime.call(&"tick", 0.5)
	assert(is_equal_approx(moved.global_position.x, 128.0) and is_equal_approx(moved.global_position.y, -64.0),
		"native smoke: move trigger offset wrong at half weight")
	assert(is_equal_approx(effect_channel.color.r, (1.0 + 10.0 / 255.0) / 2.0),
		"native smoke: colour trigger did not fade halfway")
	assert(effect_channel.blending, "native smoke: blending checkbox trigger did not flip its channel additive")
	assert(pulse_channel.color.is_equal_approx(Color8(255, 0, 0)), "native smoke: pulse did not reach its colour at hold")
	assert(is_equal_approx(effect_camera.zoom.x, 0.7), "native smoke: camera zoom did not ease halfway")
	assert(is_equal_approx(Engine.time_scale, 0.75), "native smoke: timewarp did not ease halfway")
	assert(gray_rect.visible, "native smoke: grayscale shader did not become visible")
	assert(is_equal_approx(float(gray_mat.get_shader_parameter(&"grayscale_factor")), 0.5), "native smoke: grayscale factor did not fade halfway")
	assert(sepia_rect.visible, "native smoke: sepia shader did not become visible")
	assert(is_equal_approx(float(sepia_mat.get_shader_parameter(&"sepia_factor")), 0.4), "native smoke: sepia factor did not fade halfway")
	assert(lens_rect.visible, "native smoke: lens circle shader did not become visible")
	assert(is_equal_approx(float(lens_mat.get_shader_parameter(&"alpha")), 0.5), "native smoke: lens circle alpha did not fade halfway")
	effect_runtime.call(&"tick", 0.5)
	assert(moved.global_position == Vector2(256.0, -128.0), "native smoke: move trigger did not finish")
	assert(effect_channel.color.is_equal_approx(Color8(10, 200, 30)), "native smoke: colour trigger did not reach its target")
	assert(is_equal_approx(float(effect_channel.alpha), 0.5), "native smoke: colour trigger lost its opacity fade")
	assert(pulse_channel.color == Color.WHITE, "native smoke: pulse did not fade back out")
	assert(is_equal_approx(effect_camera.zoom.x, 0.4), "native smoke: camera zoom did not reach its target")
	assert(is_equal_approx(Engine.time_scale, 0.5), "native smoke: timewarp did not reach its target")
	assert(is_equal_approx(float(gray_mat.get_shader_parameter(&"grayscale_factor")), 1.0), "native smoke: grayscale did not reach target")
	assert(is_equal_approx(float(sepia_mat.get_shader_parameter(&"sepia_factor")), 0.8), "native smoke: sepia did not reach target")
	assert(is_equal_approx(float(lens_mat.get_shader_parameter(&"alpha")), 1.0), "native smoke: lens circle did not reach target")
	assert(int(effect_runtime.call(&"active_fade_count")) == 0, "native smoke: finished fades were not retired")
	Engine.time_scale = 1.0
	# Reset clears activation state and running fades.
	effect_runtime.call(&"reset")
	assert(int(effect_runtime.call(&"active_fade_count")) == 0, "native smoke: reset left fades running")
	assert(not gray_rect.visible, "native smoke: grayscale not hidden on reset")
	assert(is_zero_approx(float(gray_mat.get_shader_parameter(&"grayscale_factor"))), "native smoke: grayscale not reset")
	assert(not sepia_rect.visible, "native smoke: sepia not hidden on reset")
	assert(is_zero_approx(float(sepia_mat.get_shader_parameter(&"sepia_factor"))), "native smoke: sepia not reset")
	assert(not lens_rect.visible, "native smoke: lens circle not hidden on reset")
	assert(is_zero_approx(float(lens_mat.get_shader_parameter(&"alpha"))), "native smoke: lens circle not reset")
	assert(ui_node.get_parent() == effect_level, "native smoke: UI node restored to effect_level on reset")
	assert(is_equal_approx(ui_node.position.x, -1012.5), "native smoke: UI node position restored on reset")
	effect_runtime.call(&"apply_ui_triggers")
	assert(ui_node.get_parent() != effect_level, "native smoke: apply_ui_triggers reapplied UI parenting")
	assert(is_equal_approx(ui_node.position.x, expected_anchor.x), "native smoke: apply_ui_triggers reapplied alignment")
	effect_runtime.call(&"reset")
	# --- 1007 Fade: GD's multiplicative group-opacity model ----------------
	# A fade eases its GROUP's persistent opacity, and a member renders as
	# its own alpha times the product of all its groups' opacities. Two
	# overlapping groups share a member: fading group 10 to 0 hides it, and
	# a fade of the overlapping group 11 back up to 1 must NOT resurrect it
	# (the regression that made a level's hidden collision blocks reappear).
	var shared_block := Node2D.new()
	shared_block.add_to_group(&"g_10")
	shared_block.add_to_group(&"g_11")
	effect_level.add_child(shared_block)
	var shared_watcher := HSVWatcher.new()
	shared_block.add_child(shared_watcher)
	shared_block.set_meta(Constants.HSV_WATCHER_META, shared_watcher)
	var solo_block := Node2D.new()
	solo_block.add_to_group(&"g_11")
	effect_level.add_child(solo_block)
	var solo_watcher := HSVWatcher.new()
	solo_block.add_child(solo_watcher)
	solo_block.set_meta(Constants.HSV_WATCHER_META, solo_watcher)
	effect_runtime.call(&"set_group_members", &"g_10", [shared_block])
	effect_runtime.call(&"set_group_members", &"g_11", [shared_block, solo_block])
	effect_runtime.call(&"register_packed_trigger", 200.0, 0.0, 0, 20, PackedStringArray(), 1007,
		{"1": "1007", "51": "10", "35": "0", "10": "0"})
	effect_runtime.call(&"register_packed_trigger", 210.0, 0.0, 0, 21, PackedStringArray(), 1007,
		{"1": "1007", "51": "11", "35": "1", "10": "0"})
	effect_runtime.call(&"advance", effect_player, 120.0, 220.0)
	effect_runtime.call(&"tick", 0.016)
	assert(is_zero_approx(shared_watcher.alpha), "native smoke: fade did not hide the shared group member")
	assert(is_equal_approx(solo_watcher.alpha, 1.0), "native smoke: fade to full lost its own group member")
	assert(is_zero_approx(shared_block.modulate.a), "native smoke: hidden block still renders")
	# A restart clears group opacity: members re-render from their own alpha
	# until the same fades fire again.
	effect_runtime.call(&"reset")
	assert(is_equal_approx(shared_watcher.alpha, 1.0), "native smoke: reset did not clear group opacity")
	# --- Live copy channels (GDRweb CopyColor port) -----------------------
	# Copies resolve their source live: B copies A, a trigger recolours A and
	# B's members re-render from A's new colour. Chains, per-copy HSV shifts,
	# opacity copying, level-colour copies and copy cycles are all part of
	# the semantics ported from GDRweb's CopyColor evaluation.
	var watcher_level := Level.new()
	add_child(watcher_level)
	var previous_level: Level = LevelManager.current_level
	LevelManager.current_level = watcher_level
	var source_channel := ColorChannelData.new()
	source_channel.associated_group = "c_5"
	source_channel.color = Color.WHITE
	var copy_channel := ColorChannelData.new()
	copy_channel.associated_group = "c_10"
	copy_channel.color = Color.BLUE # import snapshot; the link decides at runtime
	copy_channel.copied_channel_id = 5
	copy_channel.copy_hue = 0.5 # +180 degrees
	var chain_channel := ColorChannelData.new()
	chain_channel.associated_group = "c_11"
	chain_channel.copied_channel_id = 10
	var opacity_channel := ColorChannelData.new()
	opacity_channel.associated_group = "c_12"
	opacity_channel.copied_channel_id = 5
	opacity_channel.copy_opacity = true
	opacity_channel.alpha = 0.25
	var special_channel := ColorChannelData.new()
	special_channel.associated_group = "c_13"
	special_channel.copy = true
	special_channel.copied_channel = Constants.SpecialColorChannel.BACKGROUND
	var cycle_a := ColorChannelData.new()
	cycle_a.associated_group = "c_14"
	cycle_a.copied_channel_id = 15
	var cycle_b := ColorChannelData.new()
	cycle_b.associated_group = "c_15"
	cycle_b.copied_channel_id = 14
	# c_7 / c_8 pair for the trigger-side link asserts further below; both
	# belong to the level from the start so the watcher wiring covers them.
	var link_source := ColorChannelData.new()
	link_source.associated_group = "c_7"
	var link_target := ColorChannelData.new()
	link_target.associated_group = "c_8"
	watcher_level.color_channels = [
		source_channel, copy_channel, chain_channel, opacity_channel,
		special_channel, cycle_a, cycle_b, link_source, link_target,
	]
	watcher_level.setup_color_channel_watchers()
	var make_member := func(channel_group: StringName) -> HSVWatcher:
		var host := Node2D.new()
		watcher_level.add_child(host)
		var member := HSVWatcher.new()
		host.add_child(member)
		member.add_to_group(channel_group)
		return member
	# Callable.call() returns Variant; `:=` inference from Variant is an
	# error-level GDScript warning, so the members are typed explicitly.
	var copy_member: HSVWatcher = make_member.call(&"c_10")
	var chain_member: HSVWatcher = make_member.call(&"c_11")
	var opacity_member: HSVWatcher = make_member.call(&"c_12")
	var special_member: HSVWatcher = make_member.call(&"c_13")
	# The source's opacity and colour change; every copying channel follows,
	# each with its own HSV adjustment on top (c_10 rotates 180 degrees, the
	# c_11 chain link adds nothing) and the opacity copy (c_12) taking the
	# source's 0.5 instead of its own 0.25.
	source_channel.set_alpha(0.5)
	source_channel.set_color(Color.RED)
	assert(copy_member.modulate.is_equal_approx(Color(0.0, 1.0, 1.0)),
			"native smoke: copy channel did not follow its source's recolour")
	assert(chain_member.modulate.is_equal_approx(Color(0.0, 1.0, 1.0)),
			"native smoke: copy chain did not resolve through its link")
	assert(opacity_member.modulate.is_equal_approx(Color.RED) and is_equal_approx(opacity_member.base_alpha, 0.5),
			"native smoke: opacity copy did not take the source's alpha")
	# A recoloured level colour reaches the channels copying it: nothing else
	# fires when the background itself changes, so the level setter must fan
	# the refresh out itself.
	watcher_level.background_color = Color.GREEN
	assert(special_member.modulate.is_equal_approx(Color.GREEN),
			"native smoke: background copy channel stayed frozen at import")
	# A copy cycle terminates: both channels resolve to white (the iteration
	# budget) instead of recursing, and the refresh fan-out returns.
	assert(ColorChannelWatcher.resolve_channel_color(cycle_a) == Color.WHITE,
			"native smoke: copy cycle did not hit the iteration budget")
	cycle_a.set_color(Color.YELLOW)
	assert(chain_member.modulate.is_equal_approx(Color(0.0, 1.0, 1.0)),
			"native smoke: refresh fan-out disturbed an unrelated channel")
	# --- Copy links as trigger target state -------------------------------
	# A copy-colour trigger (key 50) re-points its channel at the source, so
	# the channel keeps following that source's later recolours; an explicit
	# RGB severs the link again. Fades resolve chains live too.
	var link_member: HSVWatcher = make_member.call(&"c_8")
	effect_runtime.call(&"register_channel", "c_7", link_source)
	effect_runtime.call(&"register_channel", "c_8", link_target)
	# Recolour the source first: the copy trigger's fade resolves it live.
	effect_runtime.call(&"register_packed_trigger", 130.0, 0.0, 0, 8, PackedStringArray(), 899,
			{"1": "899", "23": "7", "7": "0", "8": "255", "9": "0", "10": "0"})
	effect_runtime.call(&"register_packed_trigger", 131.0, 0.0, 0, 9, PackedStringArray(), 899,
			{"1": "899", "23": "8", "50": "7", "49": "120a1a1a0a0", "10": "0"})
	# The later recolour (x=150) and the sever (x=160) must fire on their own
	# advances: the asserts below read the link state between them, so firing
	# them inside the first advance would sever the link before it is checked.
	effect_runtime.call(&"register_packed_trigger", 150.0, 0.0, 0, 10, PackedStringArray(), 899,
			{"1": "899", "23": "7", "7": "255", "8": "0", "9": "255", "10": "0"})
	effect_runtime.call(&"register_packed_trigger", 160.0, 0.0, 0, 11, PackedStringArray(), 899,
			{"1": "899", "23": "8", "7": "0", "8": "0", "9": "255", "10": "0"})
	effect_runtime.call(&"finalize")
	effect_runtime.call(&"advance", effect_player, 0.0, 140.0)
	assert(link_target.copied_channel_id == 7,
			"native smoke: copy trigger did not link its channel to the source")
	assert(is_equal_approx(link_target.copy_hue, 120.0 / 360.0),
			"native smoke: copy trigger lost its HSV adjustment")
	# The linked channel's members now render the source's colour with the
	# link's +120 degree shift, re-resolved through the watcher fan-out.
	assert(link_member.modulate.is_equal_approx(Color.from_hsv((120.0 + 120.0) / 360.0, 1.0, 1.0)),
			"native smoke: linked channel member did not follow the source")
	# A later recolour of the source reaches the linked channel with no
	# trigger of its own - the whole point of the live link.
	effect_runtime.call(&"advance", effect_player, 0.0, 150.0)
	# Magenta (300 degrees) through the link's +120 shift wraps to 60 degrees.
	assert(link_member.modulate.is_equal_approx(Color.from_hsv(60.0 / 360.0, 1.0, 1.0)),
			"native smoke: linked channel did not follow its source's later recolour")
	# An explicit RGB replaces the link: the channel becomes that literal
	# colour and stops following the source.
	effect_runtime.call(&"advance", effect_player, 0.0, 160.0)
	assert(link_target.copied_channel_id == 0,
			"native smoke: explicit RGB trigger did not sever the copy link")
	assert(link_member.modulate.is_equal_approx(Color.BLUE),
			"native smoke: severed link did not render the trigger's literal colour")
	LevelManager.current_level = previous_level
	watcher_level.free()
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
	var col_flags: int = native.call(&"classify_collision_flags", deg_to_rad(5.0), deg_to_rad(45.0))
	assert((col_flags & 1) != 0 and (col_flags & 4) == 0, "native smoke: collision flags floor")
	var p_packed := PackedFloat64Array()
	p_packed.resize(30)
	p_packed[0] = 1.0 / 60.0
	p_packed[3] = 1.0
	p_packed[13] = 1250.0
	p_packed[14] = 2395.0
	p_packed[15] = 1.0
	p_packed[16] = 1.0
	p_packed[17] = 1.0
	var packed_physics_res: PackedFloat64Array = native.call(&"compute_player_velocity_packed", p_packed)
	assert(packed_physics_res.size() == 11, "native smoke: packed physics result size")
	assert(absf(packed_physics_res[3] - (10600.0 / 60.0)) < 0.1, "native smoke: packed physics gravity fall")
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
