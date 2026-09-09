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


func _ready() -> void:
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
	var batches := GDDecorationLoader.build_batches([data], GDDecorationLoader.art_scale())
	assert(not batches.is_empty(), "visual smoke: decoration produced no batch")
	for batch: DecorationBatch in batches:
		add_child(batch)
		_batch = batch
		batch.draw.connect(func(): print("VISUAL_SMOKE_BATCH_DRAW"))
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
