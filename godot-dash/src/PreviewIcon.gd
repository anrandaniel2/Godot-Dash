class_name PreviewIcon
extends TextureRect

enum Icon {
	CUBE,
	SHIP,
	UFO,
	BALL,
	WAVE,
	ROBOT,
	SPIDER,
	SWING,
	JETPACK,
	TRAIL,
	DEATH_EFFECT,
}

@export var type: Icon = Icon.CUBE
@export var path: String = "":
	set(value):
		path = value
		if is_node_ready():
			texture = get_icon_texture()


func _ready() -> void:
	texture = get_icon_texture()


func get_icon_texture() -> Texture2D:
	match type:
		Icon.SPIDER:
			var spider_texture: IconCache.SpiderTexture = AssetManager.get_icon_from_cache(path, Icon.SPIDER)
			return spider_texture.preview
		Icon.SWING:
			var swing_texture: IconCache.SwingTexture = AssetManager.get_icon_from_cache(path, Icon.SWING)
			return swing_texture.preview
		Icon.ROBOT:
			var robot_texture: IconCache.RobotTexture = AssetManager.get_icon_from_cache(path, Icon.ROBOT)
			return robot_texture.preview
		_:
			var texture_with_path: IconCache.TextureWithPath = AssetManager.get_icon_from_cache(path, type)
			return texture_with_path.texture
