extends Node
## Headless integration with the actual native renderer, not a model of it.
## Checks mutable drawing state and rebuild counts. This is NOT pixel/GPU proof.

var _checks: int = 0
var _failed: int = 0
var _canvas: Object
var _owner: Node2D
var _texture: ImageTexture


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failed += 1
		print("RENDERER_CACHE_FAIL %s" % message)


func _ready() -> void:
	if not ClassDB.class_exists(&"NativeDecorationRenderer"):
		print("RENDERER_CACHE_SELFTEST checks=1 failed=1 missing native renderer")
		get_tree().quit(1)
		return
	_canvas = ClassDB.instantiate(&"NativeDecorationRenderer")
	var coordinator: Node = ClassDB.instantiate(&"NativeLevelRuntime") as Node
	add_child(coordinator)
	_owner = Node2D.new()
	add_child(_owner)
	var image: Image = Image.create(8, 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	_texture = ImageTexture.create_from_image(image)
	_configure(Color.WHITE)
	# Initialize synchronously: do not depend on cull-worker scheduling speed.
	_canvas.call(&"update_camera_range")
	await _settle()
	_check(int(_canvas.call(&"last_drawn_count")) == 2, "initial records submitted")
	var commands: int = int(_canvas.call(&"command_rebuild_count"))
	var selections: int = int(_canvas.call(&"selection_rebuild_count"))
	_canvas.call(&"apply_channel_color", PackedInt32Array([0, 1]), Color.WHITE)
	_canvas.call(&"set_item_transform", 0, Transform2D.IDENTITY)
	_canvas.call(&"set_item_color", 0, Color.WHITE)
	await _settle()
	_check(
		int(_canvas.call(&"command_rebuild_count")) == commands, "identical updates do not rebuild"
	)
	_canvas.call(&"apply_channel_color", PackedInt32Array([0, 1]), Color.GREEN)
	await _settle()
	_check(_canvas.call(&"get_item_color", 0) == Color.GREEN, "live color updated")
	_check(
		int(_canvas.call(&"command_rebuild_count")) == commands + 1, "changed color rebuilds once"
	)
	_check(
		int(_canvas.call(&"selection_rebuild_count")) == selections,
		"color redraw reuses ordered IDs"
	)
	_canvas.call(&"set_channel_blending", PackedInt32Array([0]), true)
	await _settle()
	_check(int(_canvas.call(&"get_item_blend", 0)) == 1, "blend override still applied")
	commands = int(_canvas.call(&"command_rebuild_count"))
	_canvas.call(&"set_channel_blending", PackedInt32Array([0]), true)
	await _settle()
	_check(int(_canvas.call(&"command_rebuild_count")) == commands, "repeated blend is a no-op")
	var moved: Transform2D = Transform2D(0.1, Vector2(16, 16))
	_canvas.call(&"set_item_transform", 0, moved)
	await _settle()
	_check(_canvas.call(&"get_item_transform", 0) == moved, "latest transform preserved")
	_check(
		int(_canvas.call(&"selection_rebuild_count")) == selections,
		"transform redraw reads live record"
	)
	commands = int(_canvas.call(&"command_rebuild_count"))
	_canvas.call(&"set_group_pulse", Color.RED, 0.5)
	await _settle()
	_check(int(_canvas.call(&"command_rebuild_count")) == commands + 1, "group pulse redraws")
	_check(
		int(_canvas.call(&"selection_rebuild_count")) == selections, "pulse keeps cached IDs only"
	)
	_canvas.call(&"set_group_pulse", Color.WHITE, 0.0)
	_canvas.call(&"set_item_color", 0, Color.GREEN)
	await _settle()
	_check(
		int(_canvas.call(&"command_rebuild_count")) == commands + 2,
		"no-op keeps earlier pulse dirty"
	)
	# Same record count and viewport, new records: cannot reuse old selection.
	_configure(Color.BLUE)
	_canvas.call(&"update_camera_range")
	await _settle()
	_check(
		int(_canvas.call(&"selection_rebuild_count")) > selections,
		"reconfigure invalidates selection"
	)
	_check(_canvas.call(&"get_item_color", 0) == Color.BLUE, "reconfigure replaces record data")
	# Exit coordinator first: drain worker jobs before releasing the renderer.
	coordinator.free()
	_canvas = null
	_owner.free()
	print("RENDERER_CACHE_SELFTEST checks=%d failed=%d" % [_checks, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


func _configure(color: Color) -> void:
	var hsv: PackedFloat32Array = PackedFloat32Array()
	hsv.resize(10)
	hsv.fill(-1.0)
	_canvas.call(
		&"configure",
		_owner,
		[_texture, _texture],
		[Rect2(0, 0, 8, 8), Rect2(0, 0, 8, 8)],
		[Transform2D.IDENTITY, Transform2D(0.0, Vector2(4, 4))],
		PackedColorArray([color, color]),
		PackedFloat32Array([0, 4]),
		PackedFloat32Array([1, 1]),
		hsv,
		PackedFloat32Array([0, 0]),
		PackedFloat32Array([0, 0, 4, 4]),
		true,
		256.0,
		0.0
	)


func _settle() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
