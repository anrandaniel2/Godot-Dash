class_name SpiderTrail
extends Node2D

const TRAIL_HEIGHT: float = 896.0 * 0.75

@export var trail: AnimatedSprite2D


func _ready() -> void:
	trail.animation_finished.connect(queue_free)


func start(player: Player, displacement: Vector2, new_rotation: float = NAN) -> void:
	trail.play()
	global_position = player.get_spider_trail_global_position()
	scale.x = player.horizontal_direction
	scale.y = abs(displacement.length() / TRAIL_HEIGHT) * player.gravity_flip
	rotation = player.gameplay_rotation if is_nan(new_rotation) else new_rotation
