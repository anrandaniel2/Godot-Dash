extends Node

## Web substitute for the screen-copy blur and Compatibility glow.
##
## Menu frost is a low-resolution copy of the backdrop sprites, blurred in a
## small viewport. Panels sample that texture once. They never ask for
## hint_screen_texture, so the menu does not copy the browser framebuffer.
##
## Level glow is a low-resolution render of the same 2D world, masked down to
## bright pixels and added on top. It does not sample the root framebuffer.
## Sampling that texture from a child viewport is a torn previous frame, and
## adding it back on top is the trail. Compatibility's multi-pass glow stays
## off. While the game is paused, the low-resolution view is left frozen so
## the pause panel blurs the level instead of blurring itself.

const _BLUR_SHADER := preload("res://resources/shaders/WebBlurSource.gdshader")
const _EXTRACT_SHADER := preload("res://resources/shaders/WebGlowExtract.gdshader")
const _OVERLAY_SHADER := preload("res://resources/shaders/WebGlowOverlay.gdshader")

const _GLOW_LAYER := 48
const _MAX_ACTOR_SPRITES := 12

var _plate: SubViewport
var _plate_fill: ColorRect
var _plate_root: Node2D
var _world: SubViewport
var _blur: SubViewport
var _blur_rect: TextureRect
var _extract: SubViewport
var _extract_rect: TextureRect
var _glow_layer: CanvasLayer
var _glow_rect: TextureRect

var _copies: Array[Dictionary] = []
var _scene: Node
var _window_size := Vector2.ZERO
var _strength := -1.0
var _source_is_frame := false
var _capture_world := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# After interpolation, immediately before viewports draw, so the glow view
	# frames the same camera position as the frame it is added onto.
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

	# Renders the live 2D world itself. No child samples the root texture.
	_world = _make_viewport()
	_world.name = "WorldView"
	_world.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_world.world_2d = get_viewport().world_2d

	_blur = _make_viewport()
	_blur_rect = _make_stretch_rect()
	var blur_mat := ShaderMaterial.new()
	blur_mat.shader = _BLUR_SHADER
	_blur_rect.material = blur_mat
	_blur.add_child(_blur_rect)

	_extract = _make_viewport()
	_extract_rect = _make_stretch_rect()
	var extract_mat := ShaderMaterial.new()
	extract_mat.shader = _EXTRACT_SHADER
	_extract_rect.material = extract_mat
	_extract.add_child(_extract_rect)
	_extract.render_target_update_mode = SubViewport.UPDATE_DISABLED

	_glow_layer = CanvasLayer.new()
	_glow_layer.name = "WebGlowLayer"
	_glow_layer.layer = _GLOW_LAYER
	_glow_rect = TextureRect.new()
	_glow_rect.name = "WebGlowRect"
	_glow_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_glow_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_glow_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_glow_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# Layer 2 is excluded from the world view, so this rect cannot be drawn
	# back into the texture it displays.
	_glow_rect.visibility_layer = 2
	var glow_mat := ShaderMaterial.new()
	glow_mat.shader = _OVERLAY_SHADER
	_glow_rect.material = glow_mat
	_glow_rect.texture = _extract.get_texture()
	_glow_rect.visible = false
	_glow_layer.add_child(_glow_rect)
	add_child(_glow_layer)
	_glow_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_world.canvas_cull_mask = 1

	var panel_mat := load("res://resources/SimpleBlurMaterial.tres") as ShaderMaterial
	if panel_mat:
		panel_mat.set_shader_parameter("blur_tex", _blur.get_texture())
	_resize(true)


func _process(_delta: float) -> void:
	var in_level := _in_level()
	var paused := get_tree().paused
	_resize(false)
	if in_level:
		_set_update(_plate, false)
		# Freeze on pause so the panel blurs the level, not the pause menu.
		# The pause menu is a CanvasLayer, so it is not in this world view.
		_capture_world = not paused and (Config.bloom or Config.menu_blur)
		_set_update(_world, _capture_world)
		_use_source(_world.get_texture(), true)
		var glow := Config.bloom and not paused
		_set_update(_extract, glow)
		if glow and _extract_rect.texture != _world.get_texture():
			_extract_rect.texture = _world.get_texture()
		_glow_rect.visible = glow
	else:
		_capture_world = false
		_set_update(_world, false)
		_set_update(_extract, false)
		_glow_rect.visible = false
		_set_update(_plate, Config.menu_blur)
		if Config.menu_blur:
			_sync_plate()
			_use_source(_plate.get_texture(), false)
	_set_update(_blur, Config.menu_blur)


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
	var divisor := clampi(int(round(pow(2.0, clampf(Config.blur_strength, 1.0, 4.0)))), 2, 16)
	var size := Vector2i(
		clampi(int(window.x) / divisor, 96, 480),
		clampi(int(window.y) / divisor, 54, 270)
	)
	for viewport in [_plate, _world, _blur, _extract]:
		viewport.size = size
	_plate_fill.size = Vector2(size)
	_plate_fill.position = Vector2.ZERO
	for rect in [_blur_rect, _extract_rect]:
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		rect.size = Vector2(size)
	_extract_rect.texture = null


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
	if _source_is_frame == is_frame and _blur_rect.texture == texture:
		return
	_blur_rect.texture = texture
	_source_is_frame = is_frame


func _make_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.disable_3d = true
	viewport.transparent_bg = false
	viewport.gui_disable_input = true
	viewport.handle_input_locally = false
	viewport.physics_object_picking = false
	viewport.use_hdr_2d = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
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
