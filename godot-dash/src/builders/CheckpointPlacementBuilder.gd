class_name CheckpointPlacementBuilder
extends Builder

const CHECKPOINT_PREFAB: PackedScene = preload("res://scenes/components/game_components/Checkpoint.tscn")

var player: Player
var new_checkpoint: Sprite2D


func _init(new_player: Player) -> void:
	player = new_player


func use_normal_sprite() -> CheckpointPlacementBuilder:
	new_checkpoint = CHECKPOINT_PREFAB.instantiate()
	new_checkpoint.set_instance_shader_parameter(&"hue", 1.0 / 3.0)
	return self


func use_auto_sprite() -> CheckpointPlacementBuilder:
	new_checkpoint = CHECKPOINT_PREFAB.instantiate()
	new_checkpoint.set_instance_shader_parameter(&"hue", 0.107)
	return self


func done() -> void:
	if new_checkpoint:
		var checkpoint_parent: Node2D = LevelManager.game_scene.checkpoint_parent
		checkpoint_parent.add_child(new_checkpoint)
		new_checkpoint.name = "Checkpoint%s" % checkpoint_parent.get_child_count()
		new_checkpoint.global_position = player.global_position
		new_checkpoint.global_rotation_degrees = player.gameplay_rotation_degrees
	LevelManager.practice_level_snapshots.append(
		LevelManager.current_level.to_data(Serialize.Reason.PRACTICE),
	)
