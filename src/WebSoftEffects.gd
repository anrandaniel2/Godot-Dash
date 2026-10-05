extends Node

## Web substitute for Compatibility glow.
##
## Level glow is a low-resolution render of the same 2D world, masked down to
## bright pixels and added on top. It does not sample the root framebuffer.
## Sampling that texture from a child viewport is a torn previous frame, and
## adding it back on top is the trail. Compatibility's multi-pass glow stays
## off. Menu blur is not handled here: panels use the same screen-texture blur
## as desktop (BackgroundBlur.gdshader + BlurBackBuffer).

const _EXTRACT_SHADER := preload("res://resources/shaders/WebGlowExtract.gdshader")
const _OVERLAY_SHADER := preload("res://resources/shaders/WebGlowOverlay.gdshader")

const _GLOW_LAYER := 48
## Window size divided by this is the glow render size. 8 matches the old
## default (blur strength 3), so the glow looks the same as before.
const _GLOW_DIVISOR := 8

var _world: SubViewport
var _extract: SubViewport
var _extract_rect: TextureRect
var _glow_layer: CanvasLayer
var _glow_rect: TextureRect

var _window_size := Vector2.ZERO
var _capture_world := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# After interpolation, immediately before viewports draw, so the glow view
	# frames the same camera position as the frame it is added onto.
	RenderingServer.frame_pre_draw.connect(_before_draw)

	# Renders the live 2D world itself. No child samples the root texture.
	_world = _make_viewport()
	_world.name = "WorldView"
	_world.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_world.world_2d = get_viewport().world_2d
	_world.canvas_cull_mask = 1

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
	_resize(true)


func _process(_delta: float) -> void:
	_resize(false)
	var glow := Config.bloom and _in_level() and not get_tree().paused
	_capture_world = glow
	_set_update(_world, glow)
	_set_update(_extract, glow)
	if glow and _extract_rect.texture != _world.get_texture():
		_extract_rect.texture = _world.get_texture()
	_glow_rect.visible = glow


func _in_level() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.name == "GameScene"


func _resize(force: bool) -> void:
	var window := get_viewport().get_visible_rect().size
	if window.x < 2.0 or window.y < 2.0:
		return
	if not force and window == _window_size:
		return
	_window_size = window
	var size := Vector2i(
		clampi(int(window.x) / _GLOW_DIVISOR, 96, 480),
		clampi(int(window.y) / _GLOW_DIVISOR, 54, 270)
	)
	for viewport: SubViewport in [_world, _extract]:
		viewport.size = size
	_extract_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_extract_rect.size = Vector2(size)
	_extract_rect.texture = null


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
