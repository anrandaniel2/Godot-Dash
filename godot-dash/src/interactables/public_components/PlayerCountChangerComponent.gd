class_name PlayerCountChangerComponent
extends Component

@export_range(1, 10, 1, "or_greater") var _player_count: int = 1
@export var same_gravity: bool


func _ready() -> void:
	parent.body_entered.connect(set_player_count)


func _validate_property(property: Dictionary) -> void:
	if property.name == "same_gravity" and _player_count == 1:
		property.usage = PROPERTY_USAGE_NO_EDITOR


func set_player_count(player: Player) -> void:
	var dual_count: int = _player_count - 1
	if dual_count < len(LevelManager.player_duals):
		if dual_count == 0 and player.dual_index > 0:
			# Movement
			LevelManager.player.global_position = player.global_position
			LevelManager.player.velocity = player.velocity
			LevelManager.player.gameplay_rotation = player.gameplay_rotation
			LevelManager.player.horizontal_direction = player.horizontal_direction
			LevelManager.player.gravity_flip = player.gravity_flip
			LevelManager.player.gravity_multiplier = player.gravity_multiplier
			LevelManager.player.speed_multiplier = player.speed_multiplier
			# Gamemode
			LevelManager.player.internal_gamemode = player.internal_gamemode
			LevelManager.player.displayed_gamemode = player.displayed_gamemode
			# Misc
			LevelManager.player.player_scale = player.player_scale
		var duals_to_free := len(LevelManager.player_duals) - dual_count
		while duals_to_free > 0:
			LevelManager.player_duals.pop_back().queue_free()
			duals_to_free -= 1
	else:
		var duals_to_create: int = dual_count - len(LevelManager.player_duals)
		var dual_index: int = 0
		while duals_to_create > 0:
			dual_index += 1
			var player_instance: Player = AssetManager.player_packed.instantiate()
			player_instance.dual_index = dual_index
			LevelManager.game_scene.add_child.call_deferred(player_instance)
			# Movement
			player_instance.global_position = Vector2(
				LevelManager.player.global_position.rotated(-LevelManager.player.gameplay_rotation).x,
				parent.global_position.rotated(-LevelManager.player.gameplay_rotation).y,
			).rotated(LevelManager.player.gameplay_rotation)
			player_instance.velocity = LevelManager.player.velocity
			player_instance.gameplay_rotation = LevelManager.player.gameplay_rotation
			player_instance.horizontal_direction = LevelManager.player.horizontal_direction
			player_instance.gravity_flip = LevelManager.player.gravity_flip
			player_instance.gravity_multiplier = LevelManager.player.gravity_multiplier
			player_instance.speed_multiplier = LevelManager.player.speed_multiplier
			# Gamemode
			player_instance.internal_gamemode = LevelManager.player.internal_gamemode
			player_instance.displayed_gamemode = LevelManager.player.displayed_gamemode
			# Misc
			player_instance.player_scale = LevelManager.player.player_scale
			# Different gravity
			if not same_gravity and dual_index % 2 == 1:
				player_instance.gravity_flip *= -1
				player_instance.velocity = Vector2(
					player_instance.velocity.rotated(-player_instance.gameplay_rotation).x,
					-player_instance.velocity.rotated(-player_instance.gameplay_rotation).y,
				).rotated(player_instance.gameplay_rotation)
			duals_to_create -= 1
