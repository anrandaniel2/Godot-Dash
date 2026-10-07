class_name GDLevelArt
extends Node
## Geometry Dash background, ground and middleground art sets for imported
## levels: the level header picks them (kA6 / kA7 / kA25) and the Change
## Background / Ground / Middleground triggers (3029-3031) swap them.
##
## The textures are RobTop's, so they are never bundled: each one is fetched
## once from the Weebifying/gd-textures mirror and cached under
## [constant ART_DIR]. The HD variant ("-hd") is always requested first; the
## normal one only when no HD file exists. Until a texture is cached the
## bundled art stays.
##
## Names: GameManager::getBGTexture / getGTexture / getMGTexture (geode-sdk
## bindings 2.2081 inline GameManager.cpp): game_bg_%02d_001, clamped to 59;
## groundSquare_%02d_001, clamped to 22, plus groundSquare_%02d_2_001 for
## ground 8 and up (GJGroundLayer::init); fg_%02d_001 (+ fg_%02d_2_001),
## clamped to 3, where 0 means no middleground.

const ART_DIR: String = "user://created_levels/art/"
const MIRROR: String = "https://raw.githubusercontent.com/Weebifying/gd-textures/main/Resources/2.207/%s"
const BG_COUNT: int = 59
const GROUND_COUNT: int = 22
const MG_COUNT: int = 3
## Engine pixels per Geometry Dash point (CELL_SIZE px per 30 GD units).
const PX_PER_POINT: float = Constants.CELL_SIZE / 30.0
## Ground textures are 128 points tall in GD (GJGroundLayer m_ground1Offset).
const GROUND_TILE_WIDTH_PX: float = 24000.0
## gd_docs triggers/level/bg_speed.md and mg_speed.md defaults.
const DEFAULT_BG_SPEED: Vector2 = Vector2(0.1, 0.1)
const DEFAULT_MG_SPEED: Vector2 = Vector2(0.3, 0.5)
## Level origin (GD y = 0, the floor) in GameScene coordinates.
const FLOOR_Y: float = 925.0

## Live instance, reached by Level's trigger hooks.
static var current: GDLevelArt = null

var _textures: Dictionary[String, Texture2D] = {}
var _pending: Dictionary[String, bool] = {}
var _bg_id: int = 1
var _ground_id: int = 1
var _mg_id: int = 0
var _mg_speed: Vector2 = DEFAULT_MG_SPEED
var _mg_offset: float = 0.0
var _mg_parallax: Parallax2D
var _mg_sprites: Array[Sprite2D] = []
var _ground2_sprites: Array[Sprite2D] = []


func _enter_tree() -> void:
	current = self


func _exit_tree() -> void:
	if current == self:
		current = null


## Applies the level's own art set and the default speeds (level start and
## every restart). Levels not imported from Geometry Dash (art id -1) keep
## the bundled art.
func apply_level(level: Level) -> void:
	if level.gd_background_id < 0:
		return
	_mg_speed = DEFAULT_MG_SPEED
	_mg_offset = 0.0
	var bg_parallax: Parallax2D = _scene_node(^"BackgroundParallax") as Parallax2D
	if bg_parallax != null:
		bg_parallax.scroll_scale = DEFAULT_BG_SPEED
	set_art(0, level.gd_background_id)
	set_art(1, level.gd_ground_id)
	set_art(2, level.gd_middleground_id)


## [param kind] 0 background, 1 ground, 2 middleground.
func set_art(kind: int, id: int) -> void:
	match kind:
		0:
			_bg_id = clampi(id if id > 0 else 1, 1, BG_COUNT)
			_with_texture("game_bg_%02d_001" % _bg_id, _apply_background)
		1:
			_ground_id = clampi(id if id > 0 else 1, 1, GROUND_COUNT)
			_with_texture("groundSquare_%02d_001" % _ground_id, _apply_ground)
			_clear_ground2()
			if _ground_id >= 8:
				_with_texture("groundSquare_%02d_2_001" % _ground_id, _apply_ground2)
		2:
			_mg_id = clampi(id, 0, MG_COUNT)
			_clear_mg()
			if _mg_id > 0:
				_with_texture("fg_%02d_001" % _mg_id, _apply_mg.bind(0))
				_with_texture("fg_%02d_2_001" % _mg_id, _apply_mg.bind(1))


func set_mg_speed(speed: Vector2) -> void:
	_mg_speed = speed
	if _mg_parallax != null:
		_mg_parallax.scroll_scale.x = speed.x


func set_mg_offset(offset_gd: float) -> void:
	_mg_offset = offset_gd


func _scene_node(path: NodePath) -> Node:
	return LevelManager.game_scene.get_node_or_null(path) if LevelManager.game_scene != null else null


## Calls [param apply] with ([param art_name], texture, scale) once the texture
## is available: from memory, the cache, or a download.
func _with_texture(art_name: String, apply: Callable) -> void:
	if _textures.has(art_name):
		apply.call(art_name, _textures[art_name], _texture_scale(art_name))
		return
	for variant: String in ["%s-hd.png" % art_name, "%s.png" % art_name]:
		var cached := ART_DIR + variant
		if FileAccess.file_exists(cached):
			var image := Image.load_from_file(cached)
			if image != null and not image.is_empty():
				_store(art_name, variant, image)
				apply.call(art_name, _textures[art_name], _texture_scale(art_name))
				return
	_download(art_name, apply)


func _store(art_name: String, variant: String, image: Image) -> void:
	var texture := ImageTexture.create_from_image(image)
	texture.set_meta(&"hd", variant.ends_with("-hd.png"))
	_textures[art_name] = texture


## HD textures have two pixels per GD point, normal ones one.
func _texture_scale(art_name: String) -> float:
	var texture: Texture2D = _textures[art_name]
	return PX_PER_POINT / (2.0 if bool(texture.get_meta(&"hd", false)) else 1.0)


func _download(art_name: String, apply: Callable) -> void:
	if _pending.has(art_name):
		return
	_pending[art_name] = true
	for variant: String in ["%s-hd.png" % art_name, "%s.png" % art_name]:
		var bytes := await _get_bytes(MIRROR % variant)
		if bytes.is_empty():
			continue
		var image := Image.new()
		if image.load_png_from_buffer(bytes) != OK:
			continue
		DirAccess.make_dir_recursive_absolute(ART_DIR)
		image.save_png(ART_DIR + variant)
		_store(art_name, variant, image)
		break
	_pending.erase(art_name)
	if _textures.has(art_name) and _still_wanted(art_name):
		apply.call(art_name, _textures[art_name], _texture_scale(art_name))


## A download that finishes after a later Change trigger must not win.
func _still_wanted(art_name: String) -> bool:
	return art_name in [
		"game_bg_%02d_001" % _bg_id,
		"groundSquare_%02d_001" % _ground_id,
		"groundSquare_%02d_2_001" % _ground_id,
		"fg_%02d_001" % _mg_id,
		"fg_%02d_2_001" % _mg_id,
	]


func _get_bytes(url: String) -> PackedByteArray:
	var request := HTTPRequest.new()
	request.use_threads = not OS.has_feature("web")
	request.timeout = 30.0
	add_child(request)
	if request.request(url) != OK:
		request.queue_free()
		return PackedByteArray()
	var response: Array = await request.request_completed
	request.queue_free()
	if int(response[0]) != HTTPRequest.RESULT_SUCCESS or int(response[1]) != 200:
		return PackedByteArray()
	return response[3]


## Background: tiled horizontally, bottom edge on the floor, the flipped
## copy below it as before.
func _apply_background(_name: String, texture: Texture2D, scale: float) -> void:
	var parallax: Parallax2D = _scene_node(^"BackgroundParallax") as Parallax2D
	if parallax == null:
		return
	var size := texture.get_size()
	var tile := size.x * scale
	parallax.repeat_size.x = tile
	parallax.repeat_times = maxi(3, ceili(GROUND_TILE_WIDTH_PX / tile))
	var height := size.y * scale
	for sprite_name: String in ["Background", "Background2"]:
		var sprite: Sprite2D = parallax.get_node_or_null(NodePath(sprite_name)) as Sprite2D
		if sprite == null:
			continue
		sprite.texture = texture
		sprite.scale = Vector2(scale, scale)
		sprite.region_enabled = true
		sprite.region_rect = Rect2(Vector2.ZERO, size)
		sprite.position.y = FLOOR_Y + (height * 0.5 if sprite.flip_v else -height * 0.5)
	parallax.repeat_size.y = height * 2.0


## Ground: top edge on the floor line (the ceiling copy mirrored).
func _apply_ground(_name: String, texture: Texture2D, scale: float) -> void:
	for sprite: Sprite2D in _ground_sprites():
		var size := texture.get_size()
		sprite.texture = texture
		sprite.scale = Vector2(scale, scale)
		sprite.region_enabled = true
		sprite.region_rect = Rect2(0.0, 0.0, GROUND_TILE_WIDTH_PX / scale, size.y)
		sprite.position.y = signf(sprite.position.y if sprite.position.y != 0.0 else 1.0) * size.y * scale * 0.5
	for sprite: Sprite2D in _ground2_sprites:
		if is_instance_valid(sprite):
			sprite.region_rect = (sprite.get_parent() as Sprite2D).region_rect


func _ground_sprites() -> Array[Sprite2D]:
	var sprites: Array[Sprite2D] = []
	for path: NodePath in [^"GroundDownParallax/GroundDownOrigin/Ground", ^"GroundUpParallax/GroundUpOrigin/Ground"]:
		var sprite: Sprite2D = _scene_node(path) as Sprite2D
		if sprite != null:
			sprites.append(sprite)
	return sprites


## The ground's second layer, tinted by G2 (1009) and drawn over layer 1.
func _apply_ground2(_name: String, texture: Texture2D, _scale: float) -> void:
	_clear_ground2()
	for ground: Sprite2D in _ground_sprites():
		var sprite := Sprite2D.new()
		sprite.name = "Ground2"
		sprite.texture = texture
		sprite.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
		sprite.region_enabled = true
		sprite.region_rect = ground.region_rect
		sprite.flip_v = ground.flip_v
		sprite.material = ground.material
		sprite.use_parent_material = false
		sprite.z_index = 1
		ground.add_child(sprite)
		_ground2_sprites.append(sprite)


func _clear_ground2() -> void:
	for sprite: Sprite2D in _ground2_sprites:
		if is_instance_valid(sprite):
			sprite.queue_free()
	_ground2_sprites.clear()


## Middleground layers (MG 1013, MG2 1014), between the background and B5.
func _apply_mg(_name: String, texture: Texture2D, scale: float, layer: int) -> void:
	if _mg_parallax == null:
		_mg_parallax = Parallax2D.new()
		_mg_parallax.name = "MiddlegroundParallax"
		_mg_parallax.z_index = -4095
		LevelManager.game_scene.add_child(_mg_parallax)
	var size := texture.get_size()
	var tile := size.x * scale
	_mg_parallax.scroll_scale = Vector2(_mg_speed.x, 1.0)
	_mg_parallax.repeat_size = Vector2(tile, 0.0)
	_mg_parallax.repeat_times = maxi(3, ceili(GROUND_TILE_WIDTH_PX / tile))
	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.centered = false
	sprite.offset = Vector2(0.0, -size.y)
	sprite.scale = Vector2(scale, scale)
	sprite.z_index = layer
	sprite.set_meta(&"channel", 1013 + layer)
	_mg_parallax.add_child(sprite)
	_mg_sprites.append(sprite)


func _clear_mg() -> void:
	for sprite: Sprite2D in _mg_sprites:
		if is_instance_valid(sprite):
			sprite.queue_free()
	_mg_sprites.clear()


func _process(_delta: float) -> void:
	var bridge := NativeTriggerBridge.current
	for sprite: Sprite2D in _ground2_sprites:
		if is_instance_valid(sprite):
			sprite.modulate = bridge.live_channel_color(1009) if bridge != null else Color.WHITE
	if _mg_sprites.is_empty():
		return
	var camera: Camera2D = LevelManager.player_camera
	if camera == null:
		return
	# MGPosY = CPosY * (1 - SpeedY) + OffsetY (mg_speed.md), in GD units with
	# the floor at 0 and CPosY the bottom of the view. HYPOTHESIS: the
	# middleground's bottom edge sits at that height.
	var zoom := camera.get_zoom()
	var bottom_px := camera.get_screen_center_position().y + camera.get_viewport_rect().size.y * 0.5 / maxf(zoom.y, 0.001)
	var camera_gd := (FLOOR_Y - bottom_px) / PX_PER_POINT
	var mg_gd := camera_gd * (1.0 - _mg_speed.y) + _mg_offset
	for sprite: Sprite2D in _mg_sprites:
		if not is_instance_valid(sprite):
			continue
		sprite.position.y = FLOOR_Y - mg_gd * PX_PER_POINT
		sprite.modulate = bridge.live_channel_color(int(sprite.get_meta(&"channel"))) if bridge != null else Color.WHITE
