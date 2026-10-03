extends Node

signal fade_enter_loaded
signal fade_enter_canvas_group_loaded
signal icons_loaded

var thread: Thread
var mutex: Mutex

var loaded_songs: Dictionary[String, AudioStream]
var loaded_fonts: Dictionary[String, Font]
var loaded_icons: IconCache
var player_packed: PackedScene
var title_screen_packed: PackedScene
var editor_packed: PackedScene
var game_scene_packed: PackedScene
var menu_loop: AudioStream
var fade_enter_effect: ShaderMaterial
var fade_enter_effect_canvas_group: ShaderMaterial
var generated_editor_object_thumbnails: Dictionary[String, ImageTexture]
var icon_paths: Dictionary[PreviewIcon.Icon, PackedStringArray] = {
	PreviewIcon.Icon.CUBE: [],
	PreviewIcon.Icon.SHIP: [],
	PreviewIcon.Icon.JETPACK: [],
	PreviewIcon.Icon.UFO: [],
	PreviewIcon.Icon.BALL: [],
	PreviewIcon.Icon.WAVE: [],
	PreviewIcon.Icon.ROBOT: [],
	PreviewIcon.Icon.SPIDER: [],
	PreviewIcon.Icon.SWING: [],
	PreviewIcon.Icon.TRAIL: [],
	PreviewIcon.Icon.DEATH_EFFECT: [],
}


func _ready() -> void:
	ResourceLoader.load_threaded_request("res://scenes/TitleScreen.tscn")
	ResourceLoader.load_threaded_request("res://scenes/EditorScene.tscn")
	ResourceLoader.load_threaded_request("res://scenes/GameScene.tscn")
	ResourceLoader.load_threaded_request("res://scenes/components/game_components/Player.tscn")
	ResourceLoader.load_threaded_request("res://resources/FadeEnterEffect.tres")
	ResourceLoader.load_threaded_request("res://resources/FadeEnterEffectCanvasGroup.tres")
	title_screen_packed = ResourceLoader.load_threaded_get("res://scenes/TitleScreen.tscn")
	editor_packed = ResourceLoader.load_threaded_get("res://scenes/EditorScene.tscn")
	game_scene_packed = ResourceLoader.load_threaded_get("res://scenes/GameScene.tscn")
	player_packed = ResourceLoader.load_threaded_get("res://scenes/components/game_components/Player.tscn")
	fade_enter_effect = ResourceLoader.load_threaded_get("res://resources/FadeEnterEffect.tres")
	fade_enter_loaded.emit()
	fade_enter_effect_canvas_group = ResourceLoader.load_threaded_get("res://resources/FadeEnterEffectCanvasGroup.tres")
	fade_enter_canvas_group_loaded.emit()
	loaded_icons = IconCache.new()
	mutex = Mutex.new()
	cache_icon_paths()
	cache_icons()


func load_song(path: String) -> AudioStream:
	if path.is_empty():
		return null
	var audio_stream: AudioStream
	if path.begins_with("uid"):
		audio_stream = load(path)
	else:
		match path.get_extension():
			"mp3":
				audio_stream = AudioStreamMP3.load_from_file(path)
			"wav":
				audio_stream = AudioStreamWAV.load_from_file(path)
			"ogg":
				audio_stream = AudioStreamOggVorbis.load_from_file(path)
			_:
				printerr("Song isn't of valid type")
	loaded_songs[path] = audio_stream
	return audio_stream


func load_song_threaded_request(path: String) -> Error:
	if path in loaded_songs:
		return OK
	if path.is_empty() or path.get_file().is_empty():
		return ERR_FILE_BAD_PATH
	if not thread:
		thread = Thread.new()
	if thread.is_started():
		thread.wait_to_finish()
	return thread.start(load_song.bind(path))


func load_song_threaded_get(path: String) -> AudioStream:
	if path.is_empty() or path.get_file().is_empty():
		return null
	if thread.is_started():
		thread.wait_to_finish()
	return loaded_songs[path]


func unload_all() -> void:
	loaded_songs.clear()
	loaded_fonts.clear()


func load_font(path: String) -> FontFile:
	var valid_path: String = path
	var default_theme: Theme = ThemeDB.get_project_theme()
	if valid_path.is_empty() or valid_path.get_file().is_empty():
		valid_path = default_theme.default_font.resource_path
	if valid_path in loaded_fonts:
		return loaded_fonts[valid_path]
	var loaded_font: FontFile
	if valid_path == default_theme.default_font.resource_path:
		loaded_font = default_theme.default_font.duplicate()
	elif valid_path.begins_with("res://") or valid_path.begins_with("uid://"):
		loaded_font = load(valid_path).duplicate()
	else:
		loaded_font = FontFile.new()
		var error: Error = loaded_font.load_dynamic_font(valid_path)
		if error != OK:
			push_error("Error while loading font at %s: %s" % [valid_path, error])
			return null
	loaded_font.multichannel_signed_distance_field = true
	loaded_font.msdf_pixel_range = 64
	loaded_font.msdf_size = 128
	loaded_fonts[valid_path] = loaded_font
	return loaded_font


func load_image(path: String, mipmap: bool = true) -> Image:
	if path.begins_with("res://"):
		return load(path).get_image()
	var image := Image.load_from_file(path)
	if image == null:
		if path.is_empty():
			path = "null"
		Toasts.error("texture not found at path: " + path)
		return load("res://assets/textures/guis/title_screen/placeholder.svg").get_image()
	if mipmap:
		image.generate_mipmaps()
	return image


func cache_icon_paths() -> void:
	if not DirAccess.dir_exists_absolute(Constants.CUSTOM_ICON_DIR):
		DirAccess.make_dir_recursive_absolute(Constants.CUSTOM_ICON_DIR)
	for directory: String in ["cube", "ship", "jetpack", "ufo", "ball", "wave", "spider", "trail", "death_effect"]:
		directory = Constants.CUSTOM_ICON_DIR + directory
		if not DirAccess.dir_exists_absolute(directory):
			DirAccess.make_dir_recursive_absolute(directory)
	for icon_type: PreviewIcon.Icon in icon_paths:
		icon_paths[icon_type].clear()
	for icon_dir_path in [Constants.ICON_DIR, Constants.CUSTOM_ICON_DIR]:
		var icon_dir: DirAccess = DirAccess.open(icon_dir_path)
		for icon_type_dir: String in icon_dir.get_directories():
			var icon_type: PreviewIcon.Icon
			match icon_type_dir:
				"cube":
					icon_type = PreviewIcon.Icon.CUBE
				"ship":
					icon_type = PreviewIcon.Icon.SHIP
				"jetpack":
					icon_type = PreviewIcon.Icon.JETPACK
				"ufo":
					icon_type = PreviewIcon.Icon.UFO
				"ball":
					icon_type = PreviewIcon.Icon.BALL
				"wave":
					icon_type = PreviewIcon.Icon.WAVE
				"robot":
					icon_type = PreviewIcon.Icon.ROBOT
				"spider":
					icon_type = PreviewIcon.Icon.SPIDER
				"swing":
					icon_type = PreviewIcon.Icon.SWING
				"trail":
					icon_type = PreviewIcon.Icon.TRAIL
				"death_effect":
					icon_type = PreviewIcon.Icon.DEATH_EFFECT
				_:
					continue

			var textures_dir: PackedStringArray
			match icon_type:
				PreviewIcon.Icon.SPIDER, PreviewIcon.Icon.SWING, PreviewIcon.Icon.ROBOT, PreviewIcon.Icon.DEATH_EFFECT:
					textures_dir = DirAccess.open(icon_dir_path.path_join(icon_type_dir)).get_directories()
				_:
					textures_dir = DirAccess.open(icon_dir_path.path_join(icon_type_dir)).get_files()
			for icon: String in textures_dir:
				if icon.contains(".import"):
					continue
				icon_paths[icon_type].append(icon_dir_path.path_join(icon_type_dir).path_join(icon))


func generate_colored_icon(
		path: String,
		fix_alpha_edges: bool = true,
) -> Image:
	var data: String = FileAccess.get_file_as_string(path)
	var index: int = 0
	for hex in range(0, data.count("#")):
		# The color is parsed and written without the alpha (RGB channels)
		index = data.find("#", index) + 1
		var color_str: String = data.substr(index, 6)
		if not color_str.is_valid_html_color():
			continue
		var color: Color = Color(color_str)
		if color != Color.WHITE:
			color = (color.r * Config.primary_color) + (color.g * Config.secondary_color) + (color.b * Config.glow_color) if color != Color.BLACK else Config.outline_color
		data = data.erase(index, 6)
		data = data.insert(index, color.to_html(false))
	var image: Image = Image.new()
	image.load_svg_from_string(data)
	if fix_alpha_edges:
		image.fix_alpha_edges()
	image.generate_mipmaps()
	return image


func get_icon_from_cache(
		path: String,
		icon: PreviewIcon.Icon,
) -> IconCache.IsIconTexture:
	return loaded_icons.get_icon(path, icon)


func cache_icons(icons: Array = PreviewIcon.Icon.values(), fix_alpha_edges: bool = true) -> void:
	const Icon := PreviewIcon.Icon

	for icon: Icon in icons:
		for icon_path: String in icon_paths[icon]:
			var set_or_add: Callable = func(array: Array[IconCache.TextureWithPath]) -> void:
				var texture_with_path: IconCache.TextureWithPath = loaded_icons.get_icon(icon_path, icon)
				var texture := ImageTexture.create_from_image(generate_colored_icon(icon_path, fix_alpha_edges))
				if not texture_with_path:
					mutex.lock()
					array.append(IconCache.TextureWithPath.new(texture, icon_path))
					mutex.unlock()
				else:
					texture_with_path.texture = texture
			var create_part_texture: Callable = func(path: String) -> ImageTexture:
				return ImageTexture.create_from_image(generate_colored_icon(icon_path.path_join(path), fix_alpha_edges))

			match icon:
				Icon.CUBE:
					set_or_add.call(loaded_icons.cube)
				Icon.BALL:
					set_or_add.call(loaded_icons.ball)
				Icon.WAVE:
					set_or_add.call(loaded_icons.wave)
				Icon.UFO:
					set_or_add.call(loaded_icons.ufo)
				Icon.SHIP:
					set_or_add.call(loaded_icons.ship)
				Icon.JETPACK:
					set_or_add.call(loaded_icons.jetpack)
				Icon.SPIDER:
					var spider_texture: IconCache.SpiderTexture = loaded_icons.get_icon(icon_path, icon)
					var preview: ImageTexture = create_part_texture.call("SpiderPreview.svg")
					var head_color: ImageTexture = create_part_texture.call("SpiderHeadColor.svg")
					var head_glow: ImageTexture = create_part_texture.call("SpiderHeadGlow.svg")
					var leg_color: ImageTexture = create_part_texture.call("SpiderLegColor.svg")
					var leg_glow: ImageTexture = create_part_texture.call("SpiderLegGlow.svg")

					if not spider_texture:
						mutex.lock()
						loaded_icons.spider.append(
							IconCache.SpiderTexture.new(
								preview,
								IconCache.TextureWithGlow.new(head_color, head_glow),
								IconCache.TextureWithGlow.new(leg_color, leg_glow),
								icon_path,
							),
						)
						mutex.unlock()
					else:
						spider_texture.preview = preview
						spider_texture.head.color = head_color
						spider_texture.head.glow = head_glow
						spider_texture.leg.color = leg_color
						spider_texture.leg.glow = leg_glow
				Icon.SWING:
					var swing_texture: IconCache.SwingTexture = loaded_icons.get_icon(icon_path, icon)
					var preview: ImageTexture = create_part_texture.call("SwingPreview.svg")
					var sprite_color: ImageTexture = create_part_texture.call("SwingColor.svg")
					var sprite_glow: ImageTexture = create_part_texture.call("SwingGlow.svg")

					if not swing_texture:
						mutex.lock()
						loaded_icons.swing.append(
							IconCache.SwingTexture.new(
								preview,
								IconCache.TextureWithGlow.new(sprite_color, sprite_glow),
								icon_path,
							),
						)
						mutex.unlock()
					else:
						swing_texture.preview = preview
						swing_texture.sprite.color = sprite_color
						swing_texture.sprite.glow = sprite_glow
				Icon.ROBOT:
					var robot_texture: IconCache.RobotTexture = loaded_icons.get_icon(icon_path, icon)
					var preview: ImageTexture = create_part_texture.call("RobotPreview.svg")
					var head_color: ImageTexture = create_part_texture.call("RobotHeadColor.svg")
					var head_glow: ImageTexture = create_part_texture.call("RobotHeadGlow.svg")
					var connector_color: ImageTexture = create_part_texture.call("RobotConnectorColor.svg")
					var connector_glow: ImageTexture = create_part_texture.call("RobotConnectorGlow.svg")
					var leg_color: ImageTexture = create_part_texture.call("RobotLegColor.svg")
					var leg_glow: ImageTexture = create_part_texture.call("RobotLegGlow.svg")
					var foot_color: ImageTexture = create_part_texture.call("RobotFootColor.svg")
					var foot_glow: ImageTexture = create_part_texture.call("RobotFootGlow.svg")

					if not robot_texture:
						mutex.lock()
						loaded_icons.robot.append(
							IconCache.RobotTexture.new(
								preview,
								IconCache.TextureWithGlow.new(head_color, head_glow),
								IconCache.TextureWithGlow.new(connector_color, connector_glow),
								IconCache.TextureWithGlow.new(leg_color, leg_glow),
								IconCache.TextureWithGlow.new(foot_color, foot_glow),
								icon_path,
							),
						)
						mutex.unlock()
					else:
						robot_texture.preview = preview
						robot_texture.head.color = head_color
						robot_texture.head.glow = head_glow
						robot_texture.connector.color = connector_color
						robot_texture.connector.glow = connector_glow
						robot_texture.leg.color = leg_color
						robot_texture.leg.glow = leg_glow
						robot_texture.foot.color = foot_color
						robot_texture.foot.glow = foot_glow
				Icon.DEATH_EFFECT:
					# Pick a frame in the animation
					var frame_path: String = icon_path.path_join("DeathEffect07.png")
					var texture_with_path: IconCache.TextureWithPath = loaded_icons.get_icon(frame_path, icon)
					var texture := ImageTexture.create_from_image(load_image(frame_path))
					if not texture_with_path:
						mutex.lock()
						loaded_icons.death_effect.append(IconCache.TextureWithPath.new(texture, icon_path))
						mutex.unlock()
					else:
						texture_with_path.texture = texture
				Icon.TRAIL:
					var texture_with_path: IconCache.TextureWithPath = loaded_icons.get_icon(icon_path, icon)
					var texture := ImageTexture.create_from_image(load_image(icon_path))
					if not texture_with_path:
						mutex.lock()
						loaded_icons.trail.append(IconCache.TextureWithPath.new(texture, icon_path))
						mutex.unlock()
					else:
						texture_with_path.texture = texture
	icons_loaded.emit.call_deferred()


func preload_default_font() -> void:
	# FIXME: Find a cleaner wait to do this
	var default_font_thread: Thread = Thread.new()
	default_font_thread.start(func(): load_font(""))


func _exit_tree() -> void:
	if thread:
		thread.wait_to_finish()
