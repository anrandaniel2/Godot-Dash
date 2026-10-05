extends Node

## Web substitute for the screen-copy frost. Compatibility glow stays off.
##
## Menu frost is a half-resolution copy of the backdrop sprites, blurred with a
## separable Gaussian. Panels sample that texture once. They never ask for
## hint_screen_texture, so the menu does not copy the browser framebuffer.
##
## A previous in-level "soft glow" re-rendered the whole 2D world into a second
## SubViewport every play frame. Sharing world_2d means a second full canvas
## pass; on WebGPU that is what dropped a 14k-object level to ~20 fps. Glow is
## not drawn while playing. Pause still takes one frozen world snapshot so the
## pause panel can frost the level instead of itself.

const _BLUR_SHADER := preload("res://resources/shaders/WebBlurSource.gdshader")

const _MAX_ACTOR_SPRITES := 12

var _plate: SubViewport
var _plate_fill: ColorRect
var _plate_root: Node2D
var _world: SubViewport
var _blur_h: SubViewport
var _blur_h_rect: TextureRect
var _blur: SubViewport
var _blur_rect: TextureRect
var _blur_h_mat: ShaderMaterial
var _blur_v_mat: ShaderMaterial

var _copies: Array[Dictionary] = []
var _scene: Node
var _window_size := Vector2.ZERO
var _strength := -1.0
var _source_is_frame := false
var _capture_world := false
var _have_world_frame := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# After interpolation, immediately before viewports draw, so a pause
	# snapshot frames the same camera position as the frozen frame.
	RenderingServer.frame_pre_draw.connect(_before_draw)
	_plate = _make_viewport()
	_plate_fill = ColorRect.new()
	_plate_fill.name = "Fill"
	_plate_fill.color = Color(0.16, 0.28, 0.72)
	_plate_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plate_fill.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var fill_layer := CanvasLayer.new()
	fill_layer.layer = -100
	fill_layer.add_child(_plate_fill)
	_plate.add_child(fill_layer)
	_plate_root = Node2D.new()
	_plate_root.name = "Backdrop"
	_plate.add_child(_plate_root)

	# One-shot copy of the live 2D world, used only for the pause frost.
	_world = _make_viewport()
	_world.name = "WorldView"
	_world.render_target_update_mode = SubViewport.UPDATE_DISABLED

	_blur_h_mat = ShaderMaterial.new()
	_blur_h_mat.shader = _BLUR_SHADER
	_blur_h_mat.set_shader_parameter("blur_dir", Vector2(1.0, 0.0))
	_blur_v_mat = ShaderMaterial.new()
	_blur_v_mat.shader = _BLUR_SHADER
	_blur_v_mat.set_shader_parameter("blur_dir", Vector2(0.0, 1.0))

	_blur_h = _make_viewport()
	_blur_h_rect = _make_stretch_rect()
	_blur_h_rect.material = _blur_h_mat
	_blur_h.add_child(_blur_h_rect)

	_blur = _make_viewport()
	_blur_rect = _make_stretch_rect()
	_blur_rect.material = _blur_v_mat
	_blur_rect.texture = _blur_h.get_texture()
	_blur.add_child(_blur_rect)

	var panel_mat := load("res://resources/SimpleBlurMaterial.tres") as ShaderMaterial
	if panel_mat:
		# Assign the web shader on the live material, not only the .tres
		# default: shader baker can otherwise keep the screen-copy pipeline.
		panel_mat.shader = preload("res://resources/shaders/BackgroundBlurWeb.gdshader")
		panel_mat.set_shader_parameter("blur_tex", _blur.get_texture())
	_resize(true)


func _process(_delta: float) -> void:
	var in_level := _in_level()
	var paused := get_tree().paused
	_resize(false)
	if in_level:
		_set_update(_plate, false)
		# Playing: do not touch a second world viewport. Pause: one frozen
		# snapshot, then only the cheap blur passes.
		var frost := Config.menu_blur and paused
		if frost:
			if not _have_world_frame:
				_capture_world = true
				_world.render_target_update_mode = SubViewport.UPDATE_ONCE
				_have_world_frame = true
			else:
				_capture_world = false
				_set_update(_world, false)
			_use_source(_world.get_texture(), true)
		else:
			_capture_world = false
			_have_world_frame = false
			_set_update(_world, false)
		_set_frost(frost)
	else:
		_capture_world = false
		_have_world_frame = false
		_set_update(_world, false)
		_set_update(_plate, Config.menu_blur)
		if Config.menu_blur:
			_sync_plate()
			_use_source(_plate.get_texture(), false)
		_set_frost(Config.menu_blur)


func _in_level() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.name == "GameScene"


func _resize(force: bool) -> void:
	var window := get_viewport().get_visible_rect().size
	if window.x < 2.0 or window.y < 2.0:
		return
	if not force and window == _window_size and is_equal_approx(_strength, Config.blur_strength):
		return
	_window_size = window
	_strength = Config.blur_strength
	# Half-res frost. The old 1/8 cap (max 480×270) stretched into a smear
	# once the Gaussian ran on a handful of pixels.
	var size := Vector2i(
		clampi(int(window.x) / 2, 320, 960),
		clampi(int(window.y) / 2, 180, 540)
	)
	for viewport in [_plate, _world, _blur_h, _blur]:
		viewport.size = size
	_plate_fill.size = Vector2(size)
	_plate_fill.position = Vector2.ZERO
	for rect in [_blur_h_rect, _blur_rect]:
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		rect.size = Vector2(size)
	if _blur_h_mat:
		_blur_h_mat.set_shader_parameter("blur_px", Config.blur_strength)
	if _blur_v_mat:
		_blur_v_mat.set_shader_parameter("blur_px", Config.blur_strength)


func _sync_plate() -> void:
	var scene := get_tree().current_scene
	if scene != _scene:
		_scene = scene
		_rebuild_copies()
	_sync_camera()
	var fill := _plate_fill.color
	for item in _copies:
		var source: Sprite2D = item.source
		var copy: Sprite2D = item.copy
		if not is_instance_valid(source):
			copy.visible = false
			continue
		copy.global_transform = source.global_transform
		copy.visible = source.is_visible_in_tree()
		copy.modulate = source.modulate
		copy.self_modulate = source.self_modulate
		copy.flip_h = source.flip_h
		copy.flip_v = source.flip_v
		copy.texture = source.texture
		copy.region_rect = source.region_rect
		if source.name == "Background":
			fill = source.modulate
	_plate_fill.color = fill


func _before_draw() -> void:
	if _capture_world:
		_sync_world_view()


func _sync_world_view() -> void:
	var root := get_viewport()
	if root == null:
		return
	if _world.world_2d != root.world_2d:
		_world.world_2d = root.world_2d
	var window := _window_size
	if window.x < 2.0 or _world.size.x < 2:
		return
	# Same framing as the window, scaled into the small view. This is a render
	# of the world, not a sample of the root framebuffer, so it cannot trail.
	var fit := Vector2(_world.size) / window
	var scale_xform := Transform2D(Vector2(fit.x, 0.0), Vector2(0.0, fit.y), Vector2.ZERO)
	_world.canvas_transform = scale_xform * root.canvas_transform


func _sync_camera() -> void:
	var window := _window_size
	if window.x < 2.0 or _plate.size.x < 2:
		return
	# Copy the root canvas transform and scale it into the small plate. That
	# frames the same world the window is showing, including a Camera2D that
	# lives under a Control. A second Camera2D would replace this transform.
	var fit := Vector2(_plate.size) / window
	var scale_xform := Transform2D(Vector2(fit.x, 0.0), Vector2(0.0, fit.y), Vector2.ZERO)
	_plate.canvas_transform = scale_xform * get_viewport().canvas_transform


func _rebuild_copies() -> void:
	for child in _plate_root.get_children():
		child.free()
	_copies.clear()
	if _scene == null:
		return
	for source in _backdrop_sprites(_scene):
		var copy := Sprite2D.new()
		copy.texture = source.texture
		copy.centered = source.centered
		copy.offset = source.offset
		copy.region_enabled = source.region_enabled
		copy.region_rect = source.region_rect
		copy.region_filter_clip_enabled = source.region_filter_clip_enabled
		copy.texture_repeat = source.texture_repeat
		copy.texture_filter = source.texture_filter
		copy.flip_h = source.flip_h
		copy.flip_v = source.flip_v
		copy.z_as_relative = false
		if str(source.name).begins_with("Background"):
			copy.z_index = -100
		elif str(source.name).begins_with("Ground"):
			copy.z_index = 0
		else:
			copy.z_index = 10
		if _material_is_safe(source.material):
			copy.material = source.material
		_plate_root.add_child(copy)
		_copies.append({source = source, copy = copy})


func _backdrop_sprites(scene: Node) -> Array[Sprite2D]:
	var found: Array[Sprite2D] = []
	var paths: Array[String] = [
		"Node2D/BackgroundParallax/Background",
		"Node2D/BackgroundParallax/Background2",
		"BackgroundParallax/Background",
		"BackgroundParallax/Background2",
		"Node2D/GroundDownParallax/GroundDownOrigin/Ground",
		"GroundDownParallax/GroundDownOrigin/Ground",
		"Node2D/GroundUpParallax/GroundUpOrigin/Ground",
		"GroundUpParallax/GroundUpOrigin/Ground",
	]
	for path in paths:
		var node := scene.get_node_or_null(path)
		if node is Sprite2D and node not in found:
			found.append(node)
	var player := scene.get_node_or_null("Node2D/TitleScreenPlayer")
	if player:
		_collect_actors(player, found, 0)
	return found


func _collect_actors(node: Node, found: Array[Sprite2D], depth: int) -> void:
	if depth > 8 or found.size() >= _MAX_ACTOR_SPRITES + 8:
		return
	if node is Sprite2D and node.visible and node.texture != null and node not in found:
		if _material_is_safe(node.material):
			found.append(node)
	for child in node.get_children():
		_collect_actors(child, found, depth + 1)


func _material_is_safe(mat: Material) -> bool:
	if mat == null:
		return true
	if mat is ShaderMaterial:
		var shader := (mat as ShaderMaterial).shader
		if shader and shader.code.contains("hint_screen_texture"):
			return false
	return true


func _use_source(texture: Texture2D, is_frame: bool) -> void:
	if texture == null:
		return
	if _source_is_frame == is_frame and _blur_h_rect.texture == texture:
		return
	_blur_h_rect.texture = texture
	_source_is_frame = is_frame


func _make_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.disable_3d = true
	viewport.transparent_bg = false
	viewport.gui_disable_input = true
	viewport.handle_input_locally = false
	viewport.physics_object_picking = false
	viewport.use_hdr_2d = false
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	viewport.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_LINEAR
	viewport.size = Vector2i(320, 180)
	add_child(viewport)
	return viewport


func _make_stretch_rect() -> TextureRect:
	var rect := TextureRect.new()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return rect


func _set_update(viewport: SubViewport, enabled: bool) -> void:
	var mode := SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
	if viewport.render_target_update_mode != mode:
		viewport.render_target_update_mode = mode


func _set_frost(enabled: bool) -> void:
	_set_update(_blur_h, enabled)
	_set_update(_blur, enabled)
