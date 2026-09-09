extends SceneTree
## Off-screen rendering regression test for the two Geometry Dash artwork paths.
## CI runs this under Xvfb after importing resources. It fails if either the
## generated GDObject scene or DecorationBatch produces no visible pixels.

const TEST_ID := 1
const VIEW_SIZE := Vector2i(640, 256)
const SAMPLE_Y := 128
const DIRECT_X := 160
const BATCH_X := 480
const SAMPLE_RADIUS := 90

var _frames := 0


func _initialize() -> void:
	root.size = VIEW_SIZE
	root.transparent_bg = true
	RenderingServer.set_default_clear_color(Color(0, 0, 0, 0))

	var world := Node2D.new()
	root.add_child(world)

	var data := _object_data(Vector2(DIRECT_X, SAMPLE_Y))
	var packed := load("res://scenes/gd_objects/gd_%d.tscn" % TEST_ID) as PackedScene
	assert(packed != null, "visual smoke: generated GD scene is missing")
	var direct := packed.instantiate()
	assert(direct != null, "visual smoke: generated GD scene did not instantiate")
	print(
			"VISUAL_SMOKE_SCENE class=%s script=%s setup=%s"
			% [direct.get_class(), direct.get_script(), direct.has_method(&"setup")]
	)
	# Packed artwork is already positioned around its scene root. A custom
	# SceneTree test does not load project autoloads, so project scripts whose
	# globals depend on those autoloads may be absent; positioning the root still
	# exercises the generated sprites and textures themselves.
	direct.position = Vector2(DIRECT_X, SAMPLE_Y)
	world.add_child(direct)

	data = _object_data(Vector2(BATCH_X, SAMPLE_Y))
	var batches := GDDecorationLoader.build_batches([data], GDDecorationLoader.art_scale())
	assert(not batches.is_empty(), "visual smoke: decoration produced no batch")
	for batch: DecorationBatch in batches:
		world.add_child(batch)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 8:
		return false
	var image := root.get_texture().get_image()
	assert(image != null and not image.is_empty(), "visual smoke: viewport capture failed")
	var direct_pixels := _opaque_pixels(image, DIRECT_X)
	var batch_pixels := _opaque_pixels(image, BATCH_X)
	print("VISUAL_SMOKE direct=%d batch=%d" % [direct_pixels, batch_pixels])
	if direct_pixels < 100 or batch_pixels < 100:
		image.save_png("user://runtime_visual_smoke_failure.png")
		push_error(
				"visual smoke failed: generated scene=%d pixels, decoration batch=%d pixels"
				% [direct_pixels, batch_pixels]
		)
		quit(1)
		return true
	quit(0)
	return true


func _opaque_pixels(image: Image, center_x: int) -> int:
	var count := 0
	var left := maxi(0, center_x - SAMPLE_RADIUS)
	var right := mini(image.get_width(), center_x + SAMPLE_RADIUS)
	var top := maxi(0, SAMPLE_Y - SAMPLE_RADIUS)
	var bottom := mini(image.get_height(), SAMPLE_Y + SAMPLE_RADIUS)
	for y in range(top, bottom):
		for x in range(left, right):
			if image.get_pixel(x, y).a > 0.05:
				count += 1
	return count


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
