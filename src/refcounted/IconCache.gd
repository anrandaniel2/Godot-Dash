class_name IconCache

var cube: Array[TextureWithPath]
var robot: Array[RobotTexture]
var spider: Array[SpiderTexture]
var ball: Array[TextureWithPath]
var wave: Array[TextureWithPath]
var ufo: Array[TextureWithPath]
var ship: Array[TextureWithPath]
var jetpack: Array[TextureWithPath]
var swing: Array[SwingTexture]
var death_effect: Array[TextureWithPath]
var trail: Array[TextureWithPath]


func get_icon(path: String, icon: PreviewIcon.Icon) -> IsIconTexture:
	const Icon := PreviewIcon.Icon
	match icon:
		Icon.CUBE:
			return get_texture(cube, path)
		Icon.BALL:
			return get_texture(ball, path)
		Icon.WAVE:
			return get_texture(wave, path)
		Icon.UFO:
			return get_texture(ufo, path)
		Icon.SHIP:
			return get_texture(ship, path)
		Icon.JETPACK:
			return get_texture(jetpack, path)
		Icon.ROBOT:
			return get_robot_texture(robot, path)
		Icon.SPIDER:
			return get_spider_texture(spider, path)
		Icon.SWING:
			return get_swing_texture(swing, path)
		Icon.DEATH_EFFECT:
			return get_texture(death_effect, path)
		Icon.TRAIL:
			return get_texture(trail, path)
	return null


static func get_texture(array: Array[TextureWithPath], path: String) -> TextureWithPath:
	for texture_with_path: TextureWithPath in array:
		if texture_with_path.path == path:
			return texture_with_path
	return null


static func get_robot_texture(array: Array[RobotTexture], path: String) -> RobotTexture:
	for robot_texture: RobotTexture in array:
		if robot_texture.directory_path == path:
			return robot_texture
	return null


static func get_spider_texture(array: Array[SpiderTexture], path: String) -> SpiderTexture:
	for spider_texture: SpiderTexture in array:
		if spider_texture.directory_path == path:
			return spider_texture
	return null


static func get_swing_texture(array: Array[SwingTexture], path: String) -> SwingTexture:
	for swing_texture: SwingTexture in array:
		if swing_texture.directory_path == path:
			return swing_texture
	return null


@abstract class IsIconTexture:
	pass


class TextureWithPath:
	extends IsIconTexture
	var texture: Texture2D
	var path: String


	func _init(_texture: Texture2D, _path: String) -> void:
		texture = _texture
		path = _path


class RobotTexture:
	extends IsIconTexture
	var preview: Texture2D
	var head: TextureWithGlow
	var connector: TextureWithGlow
	var leg: TextureWithGlow
	var foot: TextureWithGlow
	var directory_path: String


	func _init(
			_preview: Texture2D,
			_head: TextureWithGlow,
			_connector: TextureWithGlow,
			_leg: TextureWithGlow,
			_foot: TextureWithGlow,
			_directory_path: String,
	) -> void:
		preview = _preview
		head = _head
		connector = _connector
		leg = _leg
		foot = _foot
		directory_path = _directory_path


class SpiderTexture:
	extends IsIconTexture
	var preview: Texture2D
	var head: TextureWithGlow
	var leg: TextureWithGlow
	var directory_path: String


	func _init(_preview: Texture2D, _head: TextureWithGlow, _leg: TextureWithGlow, _directory_path: String) -> void:
		preview = _preview
		head = _head
		leg = _leg
		directory_path = _directory_path


class SwingTexture:
	extends IsIconTexture
	var preview: Texture2D
	var sprite: TextureWithGlow
	var directory_path: String


	func _init(_preview: Texture2D, _sprite: TextureWithGlow, _directory_path: String) -> void:
		preview = _preview
		sprite = _sprite
		directory_path = _directory_path


class TextureWithGlow:
	var color: Texture2D
	var glow: Texture2D


	func _init(_color: Texture2D, _glow: Texture2D) -> void:
		color = _color
		glow = _glow
