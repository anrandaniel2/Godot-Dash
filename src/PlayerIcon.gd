class_name PlayerIcon
extends Node2D

enum PlatformerState {
	BOTH,
	SIDESCROLLER_ONLY,
	PLATFORMER_ONLY,
}

@export var gamemode: Player.Gamemode
@export var platformer: PlatformerState
@export var sprite_default_rotation_degrees: Dictionary[Node2D, float]


func refresh_texture() -> void:
	const Icon := PreviewIcon.Icon
	var icon_type: Icon = gamemode as int as Icon
	if icon_type == Icon.SHIP and platformer == PlatformerState.PLATFORMER_ONLY:
		icon_type = Icon.JETPACK
	var icon_path: String = Config.icon_paths[icon_type]
	match icon_type:
		Icon.SWING:
			var swing_texture: IconCache.SwingTexture = AssetManager.get_icon_from_cache(icon_path, icon_type)
			$"SwingColor".texture = swing_texture.sprite.color
			$"SwingGlow".texture = swing_texture.sprite.glow
		Icon.SPIDER:
			var spider_texture: IconCache.SpiderTexture = AssetManager.get_icon_from_cache(icon_path, icon_type)
			for part in get_node(^"SpiderSprites").get_children():
				if not part is Marker2D:
					continue
				if part.name == "Head":
					part.get_node(^"Spider").texture = spider_texture.head.color
					part.get_node(^"SpiderHead-glow").texture = spider_texture.head.glow
					continue
				elif "Leg" in part.name:
					part.get_node(^"SpiderLeg-glow").texture = spider_texture.leg.glow
					part.get_node(^"SpiderLeg").texture = spider_texture.leg.color
		Icon.ROBOT:
			var robot_texture: IconCache.RobotTexture = AssetManager.get_icon_from_cache(icon_path, icon_type)
			var sprites: RobotSprites = get_node(^"RobotSprites")

			for connector_glow: Sprite2D in [sprites.connector_back_glow, sprites.connector_front_glow]:
				connector_glow.texture = robot_texture.connector.glow
			for connector_color: Sprite2D in [sprites.connector_back_color, sprites.connector_front_color]:
				connector_color.texture = robot_texture.connector.color

			for leg_glow: Sprite2D in [sprites.leg_back_glow, sprites.leg_front_glow]:
				leg_glow.texture = robot_texture.leg.glow
			for leg_color: Sprite2D in [sprites.leg_back_color, sprites.leg_front_color]:
				leg_color.texture = robot_texture.leg.color

			for foot_glow: Sprite2D in [sprites.foot_back_glow, sprites.foot_front_glow]:
				foot_glow.texture = robot_texture.foot.glow
			for foot_color: Sprite2D in [sprites.foot_back_color, sprites.foot_front_color]:
				foot_color.texture = robot_texture.foot.color

			sprites.head_glow.texture = robot_texture.head.glow
			sprites.head_color.texture = robot_texture.head.color
		_:
			var icon: IconCache.TextureWithPath = AssetManager.get_icon_from_cache(icon_path, icon_type)
			var sprite: Sprite2D = NodeUtils.get_child_of_type(self, Sprite2D)
			sprite.texture = icon.texture


func reset() -> void:
	for particles: GPUParticles2D in NodeUtils.get_children_of_type(self, GPUParticles2D, true):
		particles.restart()
		particles.emitting = false
	for sprite: Node2D in sprite_default_rotation_degrees:
		sprite.rotation_degrees = sprite_default_rotation_degrees[sprite]
